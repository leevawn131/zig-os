// Kernel Heap Allocator Adapter
// Binds the shared hardware-independent heap core to PMM physical frame allocation,
// VMM higher-half mappings, and the kernel `std.mem.Allocator` interface.
const std = @import("std");
const pmm = @import("physical.zig");
const vmm = @import("virtual.zig");
const heap_core = @import("heap_core.zig");

pub const HEAP_START: u64 = 0xffff_9000_0000_0000;
pub const HEAP_MAX_SIZE: u64 = 64 * 1024 * 1024; // 64 MiB maximum virtual heap

pub const BlockHeader = heap_core.BlockHeader;
pub const HEADER_SIZE: usize = heap_core.HEADER_SIZE;
pub const InitError = heap_core.InitError;
pub const FreeError = heap_core.FreeError;

pub var current_heap_end: u64 = HEAP_START;
pub var head_block: ?*BlockHeader = null;
pub var initialized: bool = false;

pub var total_allocated_bytes: usize = 0;
pub var total_freed_bytes: usize = 0;

fn kernelMapHeapPage(_: ?*anyopaque, page_vaddr: u64) bool {
    const pml4 = vmm.getActivePml4();
    const phys = pmm.allocPage() orelse return false;
    vmm.mapPage(pml4, page_vaddr, phys, vmm.Flags.WRITABLE) catch {
        pmm.freePage(phys);
        return false;
    };
    return true;
}

var core = heap_core.HeapAllocator.create(HEAP_START, HEAP_MAX_SIZE, .{
    .ctx = null,
    .mapPageFn = kernelMapHeapPage,
});

inline fn syncGlobals() void {
    current_heap_end = core.current_heap_end;
    head_block = core.head_block;
    initialized = core.initialized;
    total_allocated_bytes = core.total_allocated_bytes;
    total_freed_bytes = core.total_freed_bytes;
}

pub fn tryInit(initial_pages: usize) InitError!void {
    core.init(initial_pages) catch |err| {
        syncGlobals();
        return err;
    };
    syncGlobals();
}

pub fn init(initial_pages: usize) void {
    tryInit(initial_pages) catch |err| switch (err) {
        error.InvalidInitialPageCount => @panic("HEAP: Initial heap page count must be > 0"),
        error.CapacityExceeded => @panic("HEAP: Initial heap size exceeds maximum heap capacity"),
        error.ExpansionFailed => @panic("HEAP: Failed to map initial heap backing pages"),
    };
}

pub fn allocate(size: usize, alignment: usize) ?[*]u8 {
    const ptr = core.allocate(size, alignment);
    syncGlobals();
    return ptr;
}

pub fn deallocate(ptr: [*]u8) void {
    core.deallocate(ptr) catch |err| switch (err) {
        error.PointerOutOfBounds => @panic("HEAP: Attempted to free pointer outside heap address space"),
        error.BlockHeaderNotFound => @panic("HEAP: Corrupt free - matching block header not found"),
        error.CorruptBlockHeader => @panic("HEAP: Corrupt block header - memory overwrite detected"),
        error.DoubleFree => @panic("HEAP: Double-free detected on heap memory block"),
    };
    syncGlobals();
}

// Zig std.mem.Allocator interface adapter
fn heapAlloc(
    ctx: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    return allocate(len, alignment.toByteUnits());
}

fn heapResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn heapRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn heapFree(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    deallocate(memory.ptr);
}

pub const vtable = std.mem.Allocator.VTable{
    .alloc = heapAlloc,
    .resize = heapResize,
    .remap = heapRemap,
    .free = heapFree,
};

pub fn allocator() std.mem.Allocator {
    return std.mem.Allocator{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

pub fn testHeap() bool {
    init(4);

    // Test 1: Small allocation
    const b1 = allocate(64, 16) orelse return false;
    @memset(b1[0..64], 0x42);

    // Test 2: Aligned allocation
    const b2 = allocate(128, 64) orelse return false;
    if (@intFromPtr(b2) % 64 != 0) return false;
    @memset(b2[0..128], 0x77);

    // Test 3: Standard Zig allocator interface
    const alloc = allocator();
    const slice = alloc.alloc(u32, 256) catch return false;
    for (slice, 0..) |*val, i| {
        val.* = @intCast(i * 10);
    }
    for (slice, 0..) |val, i| {
        if (val != i * 10) return false;
    }

    // Verify integrity of earlier allocations
    for (b1[0..64]) |byte| {
        if (byte != 0x42) return false;
    }
    for (b2[0..128]) |byte| {
        if (byte != 0x77) return false;
    }

    // F-06 Ring 0 regression checks: non-base pointers must fail with BlockHeaderNotFound
    const b2_addr = @intFromPtr(b2);
    const minus_8: [*]u8 = @ptrFromInt(b2_addr - 8);
    const plus_1: [*]u8 = @ptrFromInt(b2_addr + 1);
    const plus_128: [*]u8 = @ptrFromInt(b2_addr + 128);
    if (core.deallocate(minus_8)) |_| return false else |err| {
        if (err != error.BlockHeaderNotFound) return false;
    }
    if (core.deallocate(plus_1)) |_| return false else |err| {
        if (err != error.BlockHeaderNotFound) return false;
    }
    if (core.deallocate(plus_128)) |_| return false else |err| {
        if (err != error.BlockHeaderNotFound) return false;
    }

    // F-12 Ring 0 regression checks: overflow and invalid alignment must fail without mutation
    const allocated_before_invalid = total_allocated_bytes;
    const end_before_invalid = current_heap_end;
    if (allocate(std.math.maxInt(usize), 16) != null) return false;
    if (allocate(64, 0) != null) return false;
    if (allocate(64, 24) != null) return false;
    if (allocate(64, HEAP_MAX_SIZE * 2) != null) return false;
    if (total_allocated_bytes != allocated_before_invalid) return false;
    if (current_heap_end != end_before_invalid) return false;

    // Free all allocations
    alloc.free(slice);
    deallocate(b2);
    deallocate(b1);

    // Test 4: Re-allocation after free
    const b3 = allocate(100, 16) orelse return false;
    @memset(b3[0..100], 0x99);
    deallocate(b3);

    return true;
}
