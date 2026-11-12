// Physical Memory Manager (PMM) Kernel Adapter
// Binds Limine memory map, HHDM translation, and panic contracts to the shared PMM core.
const limine = @import("../limine.zig");
const physical_math = @import("physical_math.zig");
const physical_core = @import("physical_core.zig");

pub const PAGE_SIZE: u64 = physical_math.PAGE_SIZE;
pub const totalPagesFromBytes = physical_math.totalPagesFromBytes;
pub const bitmapSizeBytes = physical_math.bitmapSizeBytes;
pub const physToFrame = physical_math.physToFrame;
pub const frameToByteIndex = physical_math.frameToByteIndex;
pub const frameToBitIndex = physical_math.frameToBitIndex;

pub var hhdm_offset: u64 = 0;
pub var bitmap: [*]u8 = undefined;
pub var bitmap_size_bytes: usize = 0;

pub var total_pages: usize = 0;
pub var usable_pages: usize = 0;
pub var used_pages: usize = 0;
pub var free_pages: usize = 0;
pub var highest_address: u64 = 0;

var core: physical_core.PhysicalAllocator = .{};

pub inline fn physToVirt(paddr: u64) [*]u8 {
    return @ptrFromInt(paddr + hhdm_offset);
}

pub inline fn virtToPhys(vaddr: usize) u64 {
    return vaddr - hhdm_offset;
}

const LimineRegionContext = struct {
    entry_count: usize,
    entries: [*]const *const limine.MemmapEntry,
};

fn limineRegionCount(ctx: *const anyopaque) usize {
    const view: *const LimineRegionContext = @ptrCast(@alignCast(ctx));
    return view.entry_count;
}

fn limineRegionGet(ctx: *const anyopaque, index: usize) physical_core.MemoryRegion {
    const view: *const LimineRegionContext = @ptrCast(@alignCast(ctx));
    const entry = view.entries[index];
    return .{
        .base = entry.base,
        .length = entry.length,
        .kind = if (entry.type == .usable) .usable else .non_usable,
    };
}

fn acquireKernelBitmap(_: ?*anyopaque, bitmap_phys: u64, size_bytes: usize) physical_core.InitError![]u8 {
    return physToVirt(bitmap_phys)[0..size_bytes];
}

fn zeroKernelPages(_: ?*anyopaque, paddr: u64, page_count: usize) void {
    @memset(physToVirt(paddr)[0..(page_count * PAGE_SIZE)], 0);
}

inline fn syncGlobals() void {
    bitmap = core.bitmap.ptr;
    bitmap_size_bytes = core.bitmap.len;
    total_pages = core.total_pages;
    usable_pages = core.usable_pages;
    used_pages = core.used_pages;
    free_pages = core.free_pages;
    highest_address = core.highest_address;
}

fn panicOnFreeError(err: physical_core.FreeError, comptime unaligned_msg: []const u8) noreturn {
    switch (err) {
        error.UnalignedAddress => @panic(unaligned_msg),
        error.OutOfBounds => @panic("PMM: Physical address out of tracked bounds"),
        error.DoubleFree => @panic("PMM: Double-free detected on physical page"),
    }
}

pub fn init() void {
    const hhdm = limine.hhdm_request.response orelse @panic("PMM: Limine HHDM response missing");
    hhdm_offset = hhdm.offset;

    const memmap = limine.memmap_request.response orelse @panic("PMM: Limine memory map response missing");
    const region_ctx: LimineRegionContext = .{
        .entry_count = @intCast(memmap.entry_count),
        .entries = memmap.entries,
    };

    core.init(
        .{
            .ctx = &region_ctx,
            .countFn = limineRegionCount,
            .getFn = limineRegionGet,
        },
        .{
            .ctx = null,
            .acquireFn = acquireKernelBitmap,
        },
        .{
            .ctx = null,
            .zeroFn = zeroKernelPages,
        },
    ) catch |err| switch (err) {
        error.NoUsableBitmapRegion => @panic("PMM: Failed to locate usable physical memory for allocation bitmap"),
        error.BitmapBackingTooSmall => @panic("PMM: Allocation bitmap backing smaller than required"),
    };

    syncGlobals();
}

pub fn allocPage() ?u64 {
    const paddr = core.allocPage();
    syncGlobals();
    return paddr;
}

pub fn allocPages(count: usize) ?u64 {
    const paddr = core.allocPages(count);
    syncGlobals();
    return paddr;
}

pub fn freePage(paddr: u64) void {
    core.freePage(paddr) catch |err| {
        panicOnFreeError(err, "PMM: Attempted to free unaligned physical address");
    };
    syncGlobals();
}

pub fn freePages(paddr: u64, count: usize) void {
    core.freePages(paddr, count) catch |err| {
        panicOnFreeError(err, "PMM: Attempted to free unaligned physical range");
    };
    syncGlobals();
}

pub fn isPageAllocated(paddr: u64) bool {
    return core.isPageAllocated(paddr);
}

pub fn testPmm() bool {
    const initial_free = free_pages;
    if (used_pages + free_pages != total_pages) return false;

    // Test 1: Single page allocation
    const p1 = allocPage() orelse return false;
    if (p1 % PAGE_SIZE != 0 or p1 == 0) return false;
    if (!isPageAllocated(p1)) return false;

    // Test 2: Writing and reading from physical page via HHDM
    const v1 = physToVirt(p1);
    v1[0] = 0xAA;
    v1[4095] = 0x55;
    if (v1[0] != 0xAA or v1[4095] != 0x55) return false;

    // Test 3: Free page
    freePage(p1);
    if (isPageAllocated(p1)) return false;

    // Test 4: Re-allocation
    const p2 = allocPage() orelse return false;
    // Page must be freshly zeroed
    const v2 = physToVirt(p2);
    if (v2[0] != 0 or v2[4095] != 0) return false;
    freePage(p2);

    // Test 5: Multi-page contiguous allocation
    const multi = allocPages(4) orelse return false;
    if (multi % PAGE_SIZE != 0) return false;
    for (0..4) |i| {
        if (!isPageAllocated(multi + @as(u64, @intCast(i)) * PAGE_SIZE)) return false;
    }
    freePages(multi, 4);

    if (used_pages + free_pages != total_pages) return false;
    if (free_pages != initial_free) return false;

    return true;
}
