// Kernel Heap Allocator
// Production-grade segregated/coalescing dynamic heap allocator backed by PMM & VMM
const std = @import("std");
const pmm = @import("physical.zig");
const vmm = @import("virtual.zig");
const serial = @import("../drivers/serial/serial.zig");

pub const HEAP_START: u64 = 0xffff_9000_0000_0000;
pub const HEAP_MAX_SIZE: u64 = 64 * 1024 * 1024; // 64 MiB maximum virtual heap

const MAGIC_FREE: u32 = 0x46524545; // 'FREE'
const MAGIC_USED: u32 = 0x55534544; // 'USED'
const CANARY: u32 = 0xCAFEBABE;

pub const BlockHeader = extern struct {
    magic: u32,
    canary: u32,
    size: usize,      // Usable payload size in bytes
    is_free: bool,
    padding: [7]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0 },
    next: ?*BlockHeader,
    prev: ?*BlockHeader,
};

const HEADER_SIZE: usize = @sizeOf(BlockHeader);

pub var current_heap_end: u64 = HEAP_START;
pub var head_block: ?*BlockHeader = null;
pub var initialized: bool = false;

pub var total_allocated_bytes: usize = 0;
pub var total_freed_bytes: usize = 0;

pub fn init(initial_pages: usize) void {
    if (initialized) return;

    current_heap_end = HEAP_START;
    head_block = null;

    // Expand heap by initial_pages
    _ = expandHeap(initial_pages);

    initialized = true;
}

fn expandHeap(page_count: usize) bool {
    const pml4 = vmm.getActivePml4();

    for (0..page_count) |_| {
        if (current_heap_end - HEAP_START >= HEAP_MAX_SIZE) {
            return false;
        }

        const phys = pmm.allocPage() orelse return false;
        vmm.mapPage(pml4, current_heap_end, phys, vmm.Flags.WRITABLE) catch {
            pmm.freePage(phys);
            return false;
        };

        const new_block: *BlockHeader = @ptrFromInt(current_heap_end);
        new_block.* = BlockHeader{
            .magic = MAGIC_FREE,
            .canary = CANARY,
            .size = pmm.PAGE_SIZE - HEADER_SIZE,
            .is_free = true,
            .next = null,
            .prev = null,
        };

        // Insert new_block into linked list
        if (head_block == null) {
            head_block = new_block;
        } else {
            var curr = head_block.?;
            while (curr.next) |next| {
                curr = next;
            }
            curr.next = new_block;
            new_block.prev = curr;

            // Attempt coalescing if adjacent
            const curr_addr = @intFromPtr(curr);
            const new_addr = @intFromPtr(new_block);
            if (curr.is_free and curr_addr + HEADER_SIZE + curr.size == new_addr) {
                curr.size += HEADER_SIZE + new_block.size;
                curr.next = new_block.next;
                if (new_block.next) |n| {
                    n.prev = curr;
                }
            }
        }

        current_heap_end += pmm.PAGE_SIZE;
    }

    return true;
}

pub fn allocate(size: usize, alignment: usize) ?[*]u8 {
    if (size == 0) return null;

    const align_val = @max(alignment, 16);
    // Align request size to 16 bytes for System V alignment
    const aligned_size = (size + 15) & ~@as(usize, 15);

    var curr = head_block;
    while (curr) |block| {
        if (block.is_free and block.magic == MAGIC_FREE and block.canary == CANARY) {
            const payload_addr = @intFromPtr(block) + HEADER_SIZE;
            const aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1);
            const align_offset = aligned_payload - payload_addr;
            const total_needed = aligned_size + align_offset;

            if (block.size >= total_needed) {
                // Split block if excess space is sufficient for another header + min chunk
                const excess = block.size - total_needed;
                if (excess > HEADER_SIZE + 32) {
                    const split_addr = aligned_payload + aligned_size;
                    const next_block: *BlockHeader = @ptrFromInt(split_addr);
                    next_block.* = BlockHeader{
                        .magic = MAGIC_FREE,
                        .canary = CANARY,
                        .size = excess - HEADER_SIZE,
                        .is_free = true,
                        .next = block.next,
                        .prev = block,
                    };

                    if (block.next) |n| {
                        n.prev = next_block;
                    }
                    block.next = next_block;
                    block.size = total_needed;
                }

                block.magic = MAGIC_USED;
                block.is_free = false;
                total_allocated_bytes += block.size;

                return @ptrFromInt(aligned_payload);
            }
        }
        curr = block.next;
    }

    // Need more memory: expand heap by required pages
    const pages_needed = (aligned_size + HEADER_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    if (expandHeap(@max(pages_needed, 4))) {
        return allocate(size, alignment);
    }

    return null; // Out of memory
}

pub fn deallocate(ptr: [*]u8) void {
    const raw_addr = @intFromPtr(ptr);
    if (raw_addr < HEAP_START or raw_addr >= current_heap_end) {
        @panic("HEAP: Attempted to free pointer outside heap address space");
    }

    // Locate matching block header
    var curr = head_block;
    var found_block: ?*BlockHeader = null;

    while (curr) |block| {
        const payload_start = @intFromPtr(block) + HEADER_SIZE;
        const payload_end = payload_start + block.size;
        if (raw_addr >= payload_start and raw_addr < payload_end) {
            found_block = block;
            break;
        }
        curr = block.next;
    }

    const block = found_block orelse {
        @panic("HEAP: Corrupt free - matching block header not found");
    };

    if (block.magic != MAGIC_USED or block.canary != CANARY) {
        @panic("HEAP: Corrupt block header - memory overwrite detected");
    }

    if (block.is_free) {
        @panic("HEAP: Double-free detected on heap memory block");
    }

    block.magic = MAGIC_FREE;
    block.is_free = true;
    total_freed_bytes += block.size;

    // Coalesce with next block if free
    if (block.next) |next_b| {
        if (next_b.is_free and next_b.magic == MAGIC_FREE) {
            const block_addr = @intFromPtr(block);
            const next_addr = @intFromPtr(next_b);
            if (block_addr + HEADER_SIZE + block.size == next_addr) {
                block.size += HEADER_SIZE + next_b.size;
                block.next = next_b.next;
                if (next_b.next) |nn| {
                    nn.prev = block;
                }
            }
        }
    }

    // Coalesce with prev block if free
    if (block.prev) |prev_b| {
        if (prev_b.is_free and prev_b.magic == MAGIC_FREE) {
            const prev_addr = @intFromPtr(prev_b);
            const block_addr = @intFromPtr(block);
            if (prev_addr + HEADER_SIZE + prev_b.size == block_addr) {
                prev_b.size += HEADER_SIZE + block.size;
                prev_b.next = block.next;
                if (block.next) |bn| {
                    bn.prev = prev_b;
                }
            }
        }
    }
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
