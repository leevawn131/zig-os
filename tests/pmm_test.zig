// Host-side Unit Tests for Stateful Physical Memory Manager (PMM) Core
// Exercises the exact production `physical_core.PhysicalAllocator` shared with `kernel/src/mm/physical.zig`.

const std = @import("std");
const testing = std.testing;

const physical_core = @import("physical_core");

const PAGE_SIZE = physical_core.PAGE_SIZE;
const MemoryRegion = physical_core.MemoryRegion;
const PhysicalAllocator = physical_core.PhysicalAllocator;

const FakeMemoryBackend = struct {
    allocator: std.mem.Allocator,
    bitmap_buf: []u8,
    ram_base: u64,
    ram: []u8,
    acquired_bitmap_phys: ?u64 = null,
    acquired_bitmap_size: usize = 0,
    zero_calls: usize = 0,
    zeroed_pages_total: usize = 0,
    last_zero_paddr: u64 = 0,
    last_zero_pages: usize = 0,
    out_of_range_zero: bool = false,
    unaligned_zero: bool = false,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, ram_base: u64, sim_pages: usize, bitmap_capacity: usize) !Self {
        const bitmap_buf = try allocator.alloc(u8, bitmap_capacity);
        errdefer allocator.free(bitmap_buf);
        @memset(bitmap_buf, 0xAA);

        const ram = try allocator.alloc(u8, sim_pages * PAGE_SIZE);
        @memset(ram, 0xA5);

        return .{
            .allocator = allocator,
            .bitmap_buf = bitmap_buf,
            .ram_base = ram_base,
            .ram = ram,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.ram);
        self.allocator.free(self.bitmap_buf);
    }

    fn bitmapProvider(self: *Self) physical_core.BitmapProvider {
        return .{
            .ctx = self,
            .acquireFn = acquireBitmap,
        };
    }

    fn pageZeroer(self: *Self) physical_core.PageZeroer {
        return .{
            .ctx = self,
            .zeroFn = zeroPages,
        };
    }

    fn acquireBitmap(ctx: ?*anyopaque, bitmap_phys: u64, size_bytes: usize) physical_core.InitError![]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.acquired_bitmap_phys = bitmap_phys;
        self.acquired_bitmap_size = size_bytes;
        if (size_bytes > self.bitmap_buf.len) {
            return error.BitmapBackingTooSmall;
        }
        return self.bitmap_buf[0..size_bytes];
    }

    fn zeroPages(ctx: ?*anyopaque, paddr: u64, page_count: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.zero_calls += 1;
        self.zeroed_pages_total += page_count;
        self.last_zero_paddr = paddr;
        self.last_zero_pages = page_count;

        if (paddr % PAGE_SIZE != 0 or page_count == 0) {
            self.unaligned_zero = true;
            return;
        }

        const ram_end = self.ram_base + self.ram.len;
        const zero_len = @as(u64, @intCast(page_count)) * PAGE_SIZE;
        if (paddr < self.ram_base or paddr > ram_end or zero_len > ram_end - paddr) {
            self.out_of_range_zero = true;
            return;
        }

        const offset: usize = @intCast(paddr - self.ram_base);
        @memset(self.ram[offset .. offset + @as(usize, @intCast(zero_len))], 0);
    }

    fn pageSlice(self: *Self, paddr: u64, page_count: usize) []u8 {
        const offset: usize = @intCast(paddr - self.ram_base);
        return self.ram[offset .. offset + page_count * PAGE_SIZE];
    }
};

fn expectAllZero(bytes: []const u8) !void {
    for (bytes) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

fn assertInvariants(pmm: *const PhysicalAllocator) !void {
    try testing.expectEqual(pmm.total_pages, pmm.used_pages + pmm.free_pages);

    var bitmap_used: usize = 0;
    var bitmap_free: usize = 0;
    for (0..pmm.total_pages) |frame| {
        const paddr = @as(u64, @intCast(frame)) * PAGE_SIZE;
        if (pmm.isPageAllocated(paddr)) {
            bitmap_used += 1;
        } else {
            bitmap_free += 1;
        }
    }

    try testing.expectEqual(pmm.used_pages, bitmap_used);
    try testing.expectEqual(pmm.free_pages, bitmap_free);
}

test "PMM initialization with synthetic memory map reserves <1MiB, non-usable, and bitmap pages" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 32, 512);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x0, .length = 0x80000, .kind = .usable },
        .{ .base = 0x100000, .length = 16 * PAGE_SIZE, .kind = .non_usable },
        .{ .base = 0x110000, .length = 16 * PAGE_SIZE, .kind = .usable },
        .{ .base = 0x120000, .length = 4 * PAGE_SIZE, .kind = .non_usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(u64, 0x124000), pmm.highest_address);
    try testing.expectEqual(@as(usize, 292), pmm.total_pages);
    try testing.expectEqual(@as(usize, 37), pmm.bitmap.len);
    try testing.expectEqual(@as(?u64, 0x110000), backend.acquired_bitmap_phys);
    try testing.expectEqual(@as(usize, 37), backend.acquired_bitmap_size);
    try testing.expectEqual(@as(u64, 0x110000), pmm.bitmap_phys);

    try testing.expect(pmm.isPageAllocated(0x0));
    try testing.expect(pmm.isPageAllocated(0x1000));
    try testing.expect(pmm.isPageAllocated(0x7F000));
    try testing.expect(pmm.isPageAllocated(0x100000));
    try testing.expect(pmm.isPageAllocated(0x10F000));
    try testing.expect(pmm.isPageAllocated(0x120000));
    try testing.expect(pmm.isPageAllocated(0x123000));

    // Bitmap's own page at 0x110000 is reserved; the remaining 15 usable pages are free.
    try testing.expect(pmm.isPageAllocated(0x110000));
    for (1..16) |idx| {
        const addr = 0x110000 + @as(u64, @intCast(idx)) * PAGE_SIZE;
        try testing.expect(!pmm.isPageAllocated(addr));
    }

    try testing.expectEqual(@as(usize, 16), pmm.usable_pages);
    try testing.expectEqual(@as(usize, 15), pmm.free_pages);
    try testing.expectEqual(@as(usize, 277), pmm.used_pages);
    try assertInvariants(&pmm);

    // Both non-usable frames (288..291) and unused tail bits (292..295) in final byte stay set (1).
    try testing.expectEqual(@as(u8, 0xFF), pmm.bitmap[36]);
}

test "PMM initialization failure paths preserve pre-existing state" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 8);
    defer backend.deinit();

    const valid_regions = [_]MemoryRegion{
        .{ .base = 0x1000, .length = 4 * PAGE_SIZE, .kind = .usable },
    };
    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&valid_regions, backend.bitmapProvider(), backend.pageZeroer());
    const prev_total = pmm.total_pages;
    const prev_highest = pmm.highest_address;

    try testing.expectError(
        error.NoUsableBitmapRegion,
        pmm.initFromSlice(&.{}, backend.bitmapProvider(), backend.pageZeroer()),
    );
    try testing.expectEqual(prev_total, pmm.total_pages);
    try testing.expectEqual(prev_highest, pmm.highest_address);

    const zero_base_regions = [_]MemoryRegion{
        .{ .base = 0x0, .length = 0x20000, .kind = .usable },
        .{ .base = 0x100000, .length = 0x20000, .kind = .non_usable },
    };
    try testing.expectError(
        error.NoUsableBitmapRegion,
        pmm.initFromSlice(&zero_base_regions, backend.bitmapProvider(), backend.pageZeroer()),
    );

    const large_regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 16 * PAGE_SIZE, .kind = .usable },
    };
    try testing.expectError(
        error.BitmapBackingTooSmall,
        pmm.initFromSlice(&large_regions, backend.bitmapProvider(), backend.pageZeroer()),
    );
    try testing.expectEqual(prev_total, pmm.total_pages);
    try assertInvariants(&pmm);
}

test "PMM multi-page bitmap reserves all bitmap physical frames" {
    // Highest address = 160 MiB -> 40,960 pages -> 5,120-byte bitmap (occupies 2 frames).
    const highest_mmio_end: u64 = 160 * 1024 * 1024;
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 8, 8192);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 8 * PAGE_SIZE, .kind = .usable },
        .{ .base = highest_mmio_end - PAGE_SIZE, .length = PAGE_SIZE, .kind = .non_usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(usize, 40960), pmm.total_pages);
    try testing.expectEqual(@as(usize, 5120), pmm.bitmap.len);
    try testing.expect(pmm.isPageAllocated(0x100000));
    try testing.expect(pmm.isPageAllocated(0x101000));
    try testing.expectEqual(@as(usize, 6), pmm.free_pages);
    try assertInvariants(&pmm);
}

test "PMM single-page allocation aligns, updates counters, and zeroes via injected backend" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 8, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 8 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    const initial_free = pmm.free_pages;
    const initial_used = pmm.used_pages;

    const p1 = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0), p1 % PAGE_SIZE);
    try testing.expectEqual(@as(u64, 0x101000), p1);
    try testing.expect(pmm.isPageAllocated(p1));
    try testing.expectEqual(initial_free - 1, pmm.free_pages);
    try testing.expectEqual(initial_used + 1, pmm.used_pages);
    try testing.expectEqual(@as(usize, 1), backend.zero_calls);
    try testing.expectEqual(@as(usize, 1), backend.zeroed_pages_total);
    try testing.expect(!backend.out_of_range_zero);
    try testing.expect(!backend.unaligned_zero);
    try expectAllZero(backend.pageSlice(p1, 1));
    try assertInvariants(&pmm);
}

test "PMM deallocation, invalid free paths, and re-zeroing on reuse" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 8, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 8 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    const p1 = pmm.allocPage() orelse return error.TestUnexpectedResult;
    const free_after_alloc = pmm.free_pages;
    const used_after_alloc = pmm.used_pages;

    const mem1 = backend.pageSlice(p1, 1);
    @memset(mem1, 0xCC);
    mem1[0] = 0xAA;
    mem1[PAGE_SIZE - 1] = 0x55;

    try testing.expectError(error.UnalignedAddress, pmm.freePage(p1 + 1));
    try testing.expectError(error.UnalignedAddress, pmm.freePage(p1 + PAGE_SIZE - 1));
    try testing.expectError(error.OutOfBounds, pmm.freePage(@as(u64, pmm.total_pages) * PAGE_SIZE));
    try testing.expect(pmm.isPageAllocated(p1));
    try testing.expectEqual(free_after_alloc, pmm.free_pages);
    try testing.expectEqual(used_after_alloc, pmm.used_pages);

    try pmm.freePage(p1);
    try testing.expect(!pmm.isPageAllocated(p1));
    try testing.expectEqual(free_after_alloc + 1, pmm.free_pages);
    try testing.expectEqual(used_after_alloc - 1, pmm.used_pages);
    try assertInvariants(&pmm);

    try testing.expectError(error.DoubleFree, pmm.freePage(p1));
    try assertInvariants(&pmm);

    const p2 = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(p1, p2);
    try expectAllZero(backend.pageSlice(p2, 1));
    try assertInvariants(&pmm);
}

test "PMM contiguous multi-page allocation, deallocation, and validation errors" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 12, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 12 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    const a0 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x101000
    const a1 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x102000
    const a2 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x103000
    const a3 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x104000
    try pmm.freePage(a0);
    try pmm.freePage(a2);
    try assertInvariants(&pmm);

    // Dirty simulated frames across future contiguous allocation to verify zeroing.
    @memset(backend.pageSlice(0x105000, 4), 0xDE);

    const free_before = pmm.free_pages;
    const multi = pmm.allocPages(4) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x105000), multi);
    try testing.expectEqual(@as(u64, 0), multi % PAGE_SIZE);
    for (0..4) |i| {
        try testing.expect(pmm.isPageAllocated(multi + @as(u64, @intCast(i)) * PAGE_SIZE));
    }
    try testing.expectEqual(free_before - 4, pmm.free_pages);
    try expectAllZero(backend.pageSlice(multi, 4));
    try assertInvariants(&pmm);

    try pmm.freePages(multi, 0);
    try testing.expectError(error.UnalignedAddress, pmm.freePages(multi + 8, 2));
    try testing.expectError(error.OutOfBounds, pmm.freePages(@as(u64, pmm.total_pages - 1) * PAGE_SIZE, 2));
    // Range spanning allocated `multi + 3*PAGE_SIZE` and unallocated `multi + 4*PAGE_SIZE`.
    try testing.expectError(error.DoubleFree, pmm.freePages(multi + 3 * PAGE_SIZE, 2));
    try testing.expect(pmm.isPageAllocated(multi + 3 * PAGE_SIZE));
    try assertInvariants(&pmm);

    try pmm.freePages(multi, 4);
    for (0..4) |i| {
        try testing.expect(!pmm.isPageAllocated(multi + @as(u64, @intCast(i)) * PAGE_SIZE));
    }
    try pmm.freePage(a1);
    try pmm.freePage(a3);
    try testing.expectEqual(@as(usize, 11), pmm.free_pages);
    try assertInvariants(&pmm);
}

test "PMM out-of-memory preserves state and recovers after free" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 6, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 6 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(usize, 5), pmm.free_pages);
    try testing.expectEqual(@as(?u64, null), pmm.allocPages(6));
    try assertInvariants(&pmm);

    const blk = pmm.allocPages(3) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), pmm.free_pages);
    try testing.expectEqual(@as(?u64, null), pmm.allocPages(3));
    try testing.expectEqual(@as(usize, 2), pmm.free_pages);

    _ = pmm.allocPage() orelse return error.TestUnexpectedResult;
    _ = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), pmm.free_pages);
    try testing.expectEqual(@as(?u64, null), pmm.allocPage());
    try testing.expectEqual(@as(?u64, null), pmm.allocPages(1));
    try assertInvariants(&pmm);

    try pmm.freePages(blk, 2);
    const reused = pmm.allocPages(2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(blk, reused);
    try expectAllZero(backend.pageSlice(reused, 2));
    try assertInvariants(&pmm);
}

test "PMM boundary conditions: zero/one allocPages and partial final bitmap words/bytes" {
    const counts = [_]usize{ 7, 8, 9, 15, 16, 17, 63, 64, 65, 71, 72, 73 };

    // 1. Sub-1MiB total frame counts strictly equal to word/byte/bit boundaries.
    for (counts) |frame_count| {
        var backend = try FakeMemoryBackend.init(testing.allocator, 0x1000, frame_count, 64);
        defer backend.deinit();

        const regions = [_]MemoryRegion{
            .{ .base = 0x1000, .length = @as(u64, @intCast(frame_count - 1)) * PAGE_SIZE, .kind = .usable },
        };

        var pmm: PhysicalAllocator = .{};
        try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());
        try testing.expectEqual(frame_count, pmm.total_pages);
        try testing.expectEqual((frame_count + 7) / 8, pmm.bitmap.len);
        try testing.expectEqual(@as(usize, 0), pmm.free_pages);
        try testing.expectEqual(frame_count, pmm.used_pages);
        try testing.expectEqual(@as(?u64, null), pmm.allocPage());
        try assertInvariants(&pmm);
    }

    // 2. Allocatable spans above 1 MiB hitting partial byte remainders 7, 0, 1, 7, 0, 1.
    for (counts) |usable_count| {
        var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, usable_count, 256);
        defer backend.deinit();

        const regions = [_]MemoryRegion{
            .{ .base = 0x100000, .length = @as(u64, @intCast(usable_count)) * PAGE_SIZE, .kind = .usable },
        };

        var pmm: PhysicalAllocator = .{};
        try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

        try testing.expectEqual(256 + usable_count, pmm.total_pages);
        try testing.expectEqual((256 + usable_count + 7) / 8, pmm.bitmap.len);
        try testing.expectEqual(usable_count - 1, pmm.free_pages);
        if (usable_count == 9) {
            // Frame 264 (byte 33, bit 0) is free while unused tail bits 1..7 remain 1 (0xFE).
            try testing.expectEqual(@as(u8, 0xFE), pmm.bitmap[pmm.bitmap.len - 1]);
        }

        try testing.expectEqual(@as(?u64, null), pmm.allocPages(0));
        try assertInvariants(&pmm);

        const first_via_multi = pmm.allocPages(1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u64, 0x101000), first_via_multi);

        var last_paddr = first_via_multi;
        var allocated: usize = 1;
        while (pmm.allocPage()) |paddr| {
            try expectAllZero(backend.pageSlice(paddr, 1));
            last_paddr = paddr;
            allocated += 1;
            try assertInvariants(&pmm);
        }

        const expected_last = @as(u64, @intCast(pmm.total_pages - 1)) * PAGE_SIZE;
        try testing.expectEqual(usable_count - 1, allocated);
        try testing.expectEqual(expected_last, last_paddr);
        try testing.expectEqual(@as(usize, 0), pmm.free_pages);
        try testing.expect(pmm.isPageAllocated(expected_last));
        try testing.expect(pmm.isPageAllocated(@as(u64, @intCast(pmm.total_pages)) * PAGE_SIZE));

        // Free and reallocate the last valid frame cleanly.
        try pmm.freePage(last_paddr);
        try testing.expectEqual(@as(usize, 1), pmm.free_pages);
        const reacquired = pmm.allocPage() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(last_paddr, reacquired);
        try assertInvariants(&pmm);
    }
}

test "PMM scan cursor handles earlier-frame frees and full wraparound without skipping frames" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 16 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    // Frame 256 (byte 32 bit 0) holds the bitmap.
    // Frames 257..263 (7 frames) reside in byte 32; frames 264..271 (8 frames) reside in byte 33.
    var pages: [9]u64 = undefined;
    for (0..9) |i| {
        pages[i] = pmm.allocPage() orelse return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u64, 0x108000), pages[7]); // Frame 264 -> byte 33
    try testing.expectEqual(@as(u64, 0x109000), pages[8]); // Frame 265 -> byte 33
    try testing.expectEqual(@as(usize, 33), pmm.last_scanned_byte);

    // Freeing frame 257 (byte 32) pulls cursor backward so it is immediately reclaimed next.
    try pmm.freePage(pages[0]);
    try testing.expectEqual(@as(usize, 32), pmm.last_scanned_byte);
    const reclaimed = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(pages[0], reclaimed);

    // Drain remaining 6 frames in byte 33 (266..271); cursor reaches 33 with all 15 frames allocated.
    var tail_pages: [6]u64 = undefined;
    for (0..6) |i| {
        tail_pages[i] = pmm.allocPage() orelse return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), pmm.free_pages);
    try testing.expectEqual(@as(usize, 33), pmm.last_scanned_byte);

    // Now test full scan-cursor wraparound when cursor is past an earlier free frame.
    try pmm.freePage(pages[2]); // Frame 259 (byte 32)
    pmm.last_scanned_byte = 33; // Simulate cursor sitting ahead of freed frame 259
    const wrapped = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(pages[2], wrapped);
    try testing.expectEqual(@as(usize, 32), pmm.last_scanned_byte);
    try testing.expectEqual(@as(usize, 0), pmm.free_pages);
    try assertInvariants(&pmm);
}

test "PMM deterministic stress sequence maintains exact bitmap and counter invariants" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 32, 256);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x1000, .length = 0x10000, .kind = .usable },
        .{ .base = 0x100000, .length = 32 * PAGE_SIZE, .kind = .usable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());
    const initial_free = pmm.free_pages;
    // Region 0 (`0x1000`, `< 1 MiB`, length `0x10000 >= 36`) hosts the bitmap per existing F-16 placement rules,
    // leaving all 32 frames at `0x100000` free while keeping `< 1 MiB` reserved.
    try testing.expectEqual(@as(u64, 0x1000), pmm.bitmap_phys);
    try testing.expectEqual(@as(usize, 32), initial_free);
    try assertInvariants(&pmm);

    var held: [32]?u64 = @splat(null);
    var prng = std.Random.DefaultPrng.init(0x5EED_CAFE_2026_1113);
    const rng = prng.random();

    for (0..120) |step| {
        const op = step % 4;
        if (op == 0 or op == 1) {
            const slot = rng.uintLessThan(usize, held.len);
            if (held[slot] == null) {
                if (pmm.allocPage()) |paddr| {
                    try expectAllZero(backend.pageSlice(paddr, 1));
                    @memset(backend.pageSlice(paddr, 1), @truncate(step + 1));
                    held[slot] = paddr;
                }
            } else {
                try pmm.freePage(held[slot].?);
                held[slot] = null;
            }
        } else if (op == 2) {
            const multi_len = 2 + rng.uintLessThan(usize, 4);
            if (pmm.allocPages(multi_len)) |base_paddr| {
                try expectAllZero(backend.pageSlice(base_paddr, multi_len));
                @memset(backend.pageSlice(base_paddr, multi_len), 0x77);
                try pmm.freePages(base_paddr, multi_len);
            }
        } else {
            // Probe first occupied slot and free it.
            for (&held) |*slot| {
                if (slot.*) |paddr| {
                    try pmm.freePage(paddr);
                    slot.* = null;
                    break;
                }
            }
        }
        try assertInvariants(&pmm);
    }

    for (&held) |*slot| {
        if (slot.*) |paddr| {
            try pmm.freePage(paddr);
            slot.* = null;
            try assertInvariants(&pmm);
        }
    }

    try testing.expectEqual(initial_free, pmm.free_pages);
    try testing.expect(!backend.out_of_range_zero);
    try testing.expect(!backend.unaligned_zero);
}
