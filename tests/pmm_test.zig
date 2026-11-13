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

fn expectFreeUnchanged(
    pmm: *PhysicalAllocator,
    expected_err: physical_core.FreeError,
    call_res: physical_core.FreeError!void,
    prev_bitmap: []const u8,
    prev_used: usize,
    prev_free: usize,
    prev_cursor: usize,
) !void {
    try testing.expectError(expected_err, call_res);
    try testing.expectEqual(prev_used, pmm.used_pages);
    try testing.expectEqual(prev_free, pmm.free_pages);
    try testing.expectEqual(prev_cursor, pmm.last_scanned_byte);
    try testing.expectEqualSlices(u8, prev_bitmap, pmm.bitmap);
    try assertInvariants(pmm);
}

test "PMM initialization with synthetic memory map reserves <1MiB, non-usable, and bitmap pages" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 32, 512);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x0, .length = 0x80000, .kind = .usable },
        .{ .base = 0x100000, .length = 16 * PAGE_SIZE, .kind = .bootloader_reclaimable },
        .{ .base = 0x110000, .length = 16 * PAGE_SIZE, .kind = .usable },
        .{ .base = 0x120000, .length = 4 * PAGE_SIZE, .kind = .executable_and_modules },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(u64, 0x124000), pmm.highest_address);
    try testing.expectEqual(@as(usize, 292), pmm.total_pages);
    try testing.expectEqual(@as(usize, 37), pmm.bitmap.len);
    try testing.expectEqual(@as(?u64, 0x110000), backend.acquired_bitmap_phys);
    try testing.expectEqual(@as(usize, 37), backend.acquired_bitmap_size);
    try testing.expectEqual(@as(u64, 0x110000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x111000), pmm.bitmap_end_phys);

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
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 64);
    defer backend.deinit();

    const valid_regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 4 * PAGE_SIZE, .kind = .usable },
    };
    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&valid_regions, backend.bitmapProvider(), backend.pageZeroer());
    const prev_total = pmm.total_pages;
    const prev_highest = pmm.highest_address;
    const prev_bitmap_phys = pmm.bitmap_phys;

    // Allocate one page so we can verify failure paths do not clobber retained regions or state.
    const held = pmm.allocPage() orelse return error.TestUnexpectedResult;

    try testing.expectError(
        error.NoUsableBitmapRegion,
        pmm.initFromSlice(&.{}, backend.bitmapProvider(), backend.pageZeroer()),
    );
    try testing.expectEqual(prev_total, pmm.total_pages);
    try testing.expectEqual(prev_highest, pmm.highest_address);
    try testing.expectEqual(prev_bitmap_phys, pmm.bitmap_phys);

    const sub_1mib_regions = [_]MemoryRegion{
        .{ .base = 0x1000, .length = 0x20000, .kind = .usable },
        .{ .base = 0x100000, .length = 0x20000, .kind = .reserved },
    };
    try testing.expectError(
        error.NoUsableBitmapRegion,
        pmm.initFromSlice(&sub_1mib_regions, backend.bitmapProvider(), backend.pageZeroer()),
    );
    try testing.expectEqual(prev_total, pmm.total_pages);
    try testing.expectEqual(prev_highest, pmm.highest_address);

    // Trigger BitmapBackingTooSmall cleanly by using a 8-byte-capable provider on a 16-MiB map.
    var tiny_backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 4, 8);
    defer tiny_backend.deinit();
    const large_regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 16 * PAGE_SIZE, .kind = .usable },
    };
    try testing.expectError(
        error.BitmapBackingTooSmall,
        pmm.initFromSlice(&large_regions, tiny_backend.bitmapProvider(), tiny_backend.pageZeroer()),
    );
    try testing.expectEqual(prev_total, pmm.total_pages);
    try testing.expectEqual(prev_bitmap_phys, pmm.bitmap_phys);
    try assertInvariants(&pmm);

    // Confirm retained slice still points to valid_regions after failed re-inits.
    try pmm.freePage(held);
    try assertInvariants(&pmm);
}

test "PMM multi-page bitmap reserves all bitmap physical frames" {
    // Highest RAM-backed address = 160 MiB -> 40,960 pages -> 5,120-byte bitmap (occupies 2 frames).
    const highest_ram_end: u64 = 160 * 1024 * 1024;
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 8, 8192);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 8 * PAGE_SIZE, .kind = .usable },
        .{ .base = highest_ram_end - PAGE_SIZE, .length = PAGE_SIZE, .kind = .executable_and_modules },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(usize, 40960), pmm.total_pages);
    try testing.expectEqual(@as(usize, 5120), pmm.bitmap.len);
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x102000), pmm.bitmap_end_phys);
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

    // 1. All-used partial final bitmap words/bytes strictly above 1 MiB (bitmap takes the single usable page).
    for (counts) |tail_frames| {
        const expected_total = 256 + tail_frames;
        var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 1, 64);
        defer backend.deinit();

        const regions = [_]MemoryRegion{
            .{ .base = 0x100000, .length = PAGE_SIZE, .kind = .usable },
            .{
                .base = 0x101000,
                .length = @as(u64, @intCast(tail_frames - 1)) * PAGE_SIZE,
                .kind = .bootloader_reclaimable,
            },
        };

        var pmm: PhysicalAllocator = .{};
        try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());
        try testing.expectEqual(expected_total, pmm.total_pages);
        try testing.expectEqual((expected_total + 7) / 8, pmm.bitmap.len);
        try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
        try testing.expectEqual(@as(usize, 0), pmm.free_pages);
        try testing.expectEqual(expected_total, pmm.used_pages);
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
    // Region 0 (`0x1000`, `< 1 MiB`) is skipped per F-16; the bitmap is placed at `0x100000`,
    // leaving 31 frames at `0x101000..0x120000` free while keeping `< 1 MiB` reserved.
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(usize, 31), initial_free);
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

test "F-07: high reserved, framebuffer, acpi_nvs, bad_memory, reserved_mapped, and unknown apertures do not inflate ceiling" {
    // RAM: [0x100000, 0x10100000) (256 MiB usable) -> ceiling = 0x10100000 -> 65,792 pages -> 8,224-byte bitmap (3 pages).
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 16384);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x0, .length = 0x100000, .kind = .reserved },
        .{ .base = 0x100000, .length = 256 * 1024 * 1024, .kind = .usable },
        .{ .base = 0x1_0000_0000, .length = 0x10000, .kind = .unknown },
        .{ .base = 0x2_0000_0000, .length = 0x10000, .kind = .reserved_mapped },
        .{ .base = 0x4_0000_0000, .length = 0x10000, .kind = .bad_memory },
        .{ .base = 0x8_0000_0000, .length = 0x20000, .kind = .acpi_nvs },
        .{ .base = 0x10_0000_0000, .length = 0x400000, .kind = .framebuffer },
        .{ .base = 0x4000_0000_0000, .length = 0x100000, .kind = .reserved }, // 64 TiB PCIe MMIO aperture
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    try testing.expectEqual(@as(u64, 0x10100000), pmm.highest_address);
    try testing.expectEqual(@as(usize, 65792), pmm.total_pages);
    try testing.expectEqual(@as(usize, 8224), pmm.bitmap.len);
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x103000), pmm.bitmap_end_phys);
    try testing.expectEqual(@as(usize, 65536), pmm.usable_pages);
    try testing.expectEqual(@as(usize, 65533), pmm.free_pages);
    try testing.expectEqual(@as(usize, 259), pmm.used_pages);
    try assertInvariants(&pmm);

    // First allocatable frame immediately follows the 3-page bitmap backing [0x100000, 0x103000).
    const first = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x103000), first);
    try expectAllZero(backend.pageSlice(first, 1));
    try pmm.freePage(first);
    try testing.expectError(error.OutOfBounds, pmm.freePage(0x4000_0000_0000));
    try testing.expectError(error.OutOfBounds, pmm.freePage(0x10_0000_0000));
    try assertInvariants(&pmm);

    // Also verify high excluded regions cannot inflate ceiling when RAM ceiling is exact 256 MiB (0x10000000).
    const exact_256_regions = [_]MemoryRegion{
        .{ .base = 0x0, .length = 0x100000, .kind = .reserved },
        .{ .base = 0x100000, .length = 255 * 1024 * 1024, .kind = .usable },
        .{ .base = 0x80_0000_0000, .length = 0x200000, .kind = .framebuffer },
        .{ .base = 0x4000_0000_0000, .length = 0x100000, .kind = .reserved },
    };
    try pmm.initFromSlice(&exact_256_regions, backend.bitmapProvider(), backend.pageZeroer());
    try testing.expectEqual(@as(u64, 0x10000000), pmm.highest_address);
    try testing.expectEqual(@as(usize, 65536), pmm.total_pages);
    try testing.expectEqual(@as(usize, 8192), pmm.bitmap.len);
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x102000), pmm.bitmap_end_phys);
    try assertInvariants(&pmm);
}

test "F-07: RAM-backed reclaimable/kernel types raise ceiling while all non-usable entries remain unallocatable" {
    // Usable spans [0x100000..0x104000) and [0x108000..0x10A000) (6 pages total);
    // interleaved non-usable types stay reserved and never returned by allocPage().
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 32, 512);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 4 * PAGE_SIZE, .kind = .usable }, // 0x100000..0x104000
        .{ .base = 0x104000, .length = PAGE_SIZE, .kind = .reserved },
        .{ .base = 0x105000, .length = PAGE_SIZE, .kind = .framebuffer },
        .{ .base = 0x106000, .length = PAGE_SIZE, .kind = .acpi_nvs },
        .{ .base = 0x107000, .length = PAGE_SIZE, .kind = .bad_memory },
        .{ .base = 0x108000, .length = 2 * PAGE_SIZE, .kind = .usable }, // 0x108000..0x10A000
        .{ .base = 0x10A000, .length = PAGE_SIZE, .kind = .reserved_mapped },
        .{ .base = 0x10B000, .length = PAGE_SIZE, .kind = .unknown },
        .{ .base = 0x10C000, .length = 2 * PAGE_SIZE, .kind = .bootloader_reclaimable },
        .{ .base = 0x10E000, .length = 2 * PAGE_SIZE, .kind = .acpi_reclaimable },
        .{ .base = 0x110000, .length = 4 * PAGE_SIZE, .kind = .executable_and_modules },
        .{ .base = 0x2000_0000, .length = 0x100000, .kind = .reserved },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());

    // Ceiling is top of `.executable_and_modules` (0x114000 -> 276 pages -> 35-byte bitmap), ignoring 0x2000_0000 `.reserved`.
    try testing.expectEqual(@as(u64, 0x114000), pmm.highest_address);
    try testing.expectEqual(@as(usize, 276), pmm.total_pages);
    try testing.expectEqual(@as(usize, 35), pmm.bitmap.len);
    try testing.expectEqual(@as(usize, 6), pmm.usable_pages);
    try testing.expectEqual(@as(usize, 5), pmm.free_pages);

    const expected_reserved = [_]u64{
        0x100000, // bitmap
        0x104000, // .reserved
        0x105000, // .framebuffer
        0x106000, // .acpi_nvs
        0x107000, // .bad_memory
        0x10A000, // .reserved_mapped
        0x10B000, // .unknown
        0x10C000, // .bootloader_reclaimable
        0x10D000,
        0x10E000, // .acpi_reclaimable
        0x10F000,
        0x110000, // .executable_and_modules
        0x111000,
        0x112000,
        0x113000,
    };
    for (expected_reserved) |addr| {
        try testing.expect(pmm.isPageAllocated(addr));
    }

    // Drain every single free page and confirm exact usable pages only (never reclaimable or kernel frames).
    const expected_allocs = [_]u64{ 0x101000, 0x102000, 0x103000, 0x108000, 0x109000 };
    for (expected_allocs) |expected_paddr| {
        const allocated = pmm.allocPage() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(expected_paddr, allocated);
        try expectAllZero(backend.pageSlice(allocated, 1));
    }
    try testing.expectEqual(@as(?u64, null), pmm.allocPage());
    try testing.expect(!backend.out_of_range_zero);
    try assertInvariants(&pmm);
}

test "F-08: freePage enforces low-memory (<1MiB), page-rounded bitmap overlap, and usable-region boundaries" {
    // 256 MiB ceiling starting at 0x100000 creates a 3-page bitmap [0x100000, 0x103000) where page 3 holds 32 bytes.
    // Interleave RAM regions plus an unmapped gap and unaligned `.usable` region near 0x103000..0x110000.
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 16384);
    defer backend.deinit();

    const regions = [_]MemoryRegion{
        // Usable region covering <1MiB as well as the 3-page bitmap and usable frame 0x103000.
        .{ .base = 0x0, .length = 0x104000, .kind = .usable },
        .{ .base = 0x104000, .length = PAGE_SIZE, .kind = .reserved },
        .{ .base = 0x105000, .length = PAGE_SIZE, .kind = .bootloader_reclaimable },
        .{ .base = 0x106000, .length = PAGE_SIZE, .kind = .executable_and_modules },
        .{ .base = 0x107000, .length = PAGE_SIZE, .kind = .acpi_reclaimable },
        .{ .base = 0x108000, .length = PAGE_SIZE, .kind = .acpi_nvs },
        .{ .base = 0x109000, .length = PAGE_SIZE, .kind = .bad_memory },
        .{ .base = 0x10A000, .length = PAGE_SIZE, .kind = .framebuffer },
        .{ .base = 0x10B000, .length = PAGE_SIZE, .kind = .reserved_mapped },
        .{ .base = 0x10C000, .length = PAGE_SIZE, .kind = .unknown },
        // Gap at 0x10D000..0x10E000 (not listed in memory map).
        // Unaligned `.usable` [0x10E800, 0x111800) => only 0x10F000 and 0x110000 are wholly contained frames.
        .{ .base = 0x10E800, .length = 0x3000, .kind = .usable },
        // Push RAM ceiling up to 0x10100000 so bitmap is 8,224 bytes (2 full pages + 32-byte partial 3rd page).
        .{ .base = 0x10000000, .length = 1024 * 1024, .kind = .bootloader_reclaimable },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());
    try testing.expectEqual(@as(usize, 8224), pmm.bitmap.len);
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x103000), pmm.bitmap_end_phys);
    try testing.expectEqual(@as(usize, 3), pmm.free_pages); // 0x103000, 0x10F000, 0x110000

    // Allocate the 3 valid usable frames so we can test freeing both valid and invalid paths.
    const page0 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x103000
    const page1 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x10F000
    const page2 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x110000
    try testing.expectEqual(@as(u64, 0x103000), page0);
    try testing.expectEqual(@as(u64, 0x10F000), page1);
    try testing.expectEqual(@as(u64, 0x110000), page2);

    const snapshot = try testing.allocator.dupe(u8, pmm.bitmap);
    defer testing.allocator.free(snapshot);
    const prev_used = pmm.used_pages;
    const prev_free = pmm.free_pages;
    const prev_cursor = pmm.last_scanned_byte;

    // 1. Low-memory addresses (< 1 MiB) must fail with ReservedAddress even when inside `.usable`.
    const low_addrs = [_]u64{ 0x0, 0x1000, 0x80000, 0xFF000 };
    for (low_addrs) |addr| {
        try expectFreeUnchanged(&pmm, error.ReservedAddress, pmm.freePage(addr), snapshot, prev_used, prev_free, prev_cursor);
    }

    // 2. Every physical frame occupied by page-rounded bitmap [0x100000, 0x103000) fails with BitmapOverlap.
    const bitmap_frames = [_]u64{ 0x100000, 0x101000, 0x102000 }; // 0x102000 holds only 32 bytes (partial page!)
    for (bitmap_frames) |addr| {
        try expectFreeUnchanged(&pmm, error.BitmapOverlap, pmm.freePage(addr), snapshot, prev_used, prev_free, prev_cursor);
    }

    // 3. Non-usable region types, unmapped gap, and partially-usable boundary frames fail with NotUsableRegion.
    const non_usable_addrs = [_]u64{
        0x104000, // .reserved
        0x105000, // .bootloader_reclaimable
        0x106000, // .executable_and_modules
        0x107000, // .acpi_reclaimable
        0x108000, // .acpi_nvs
        0x109000, // .bad_memory
        0x10A000, // .framebuffer
        0x10B000, // .reserved_mapped
        0x10C000, // .unknown
        0x10D000, // unmapped gap
        0x10E000, // partial start boundary [0x10E800..0x10F000)
        0x111000, // partial end boundary [0x111000..0x111800)
    };
    for (non_usable_addrs) |addr| {
        try expectFreeUnchanged(&pmm, error.NotUsableRegion, pmm.freePage(addr), snapshot, prev_used, prev_free, prev_cursor);
    }

    // 4. Valid usable frames can be freed, re-tested for DoubleFree, and reallocated.
    try pmm.freePage(page0);
    try pmm.freePage(page1);
    try pmm.freePage(page2);
    try testing.expectEqual(@as(usize, 3), pmm.free_pages);
    try testing.expectError(error.DoubleFree, pmm.freePage(page0));
    try testing.expectError(error.DoubleFree, pmm.freePage(page1));
    try assertInvariants(&pmm);

    const reallocated = pmm.allocPage() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(page0, reallocated);
    try expectAllZero(backend.pageSlice(reallocated, 1));
    try assertInvariants(&pmm);
}

test "F-08: freePages fails atomically with zero bitmap or counter mutations" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0xFE000, 12, 8192);
    defer backend.deinit();

    // Regions create contiguous pages around <1MiB boundary, bitmap, usable block, reserved, and kernel frames:
    // - 0xFF000..0x100000: <1 MiB usable (reserved)
    // - 0x100000..0x101000: usable page 0 (allocated -> freed later -> double-free target? No, make page at 0x100000 usable?)
    // Place bitmap at 0x103000 by putting usable [0x100000, 0x101000) too small (< 2 pages needed) or test before/after bitmap!
    // Force a 2-page bitmap by putting bootloader_reclaimable high at 160 MiB:
    // Region 0: usable [0xFE000, 0x101000) => after 1 MiB clamp has ONLY 1 page [0x100000, 0x101000) -> too small for 2-page bitmap!
    // Region 1: bootloader_reclaimable [0x101000, 0x102000)
    // Region 2: usable [0x102000, 0x106000) => 4 pages, hosts 2-page bitmap [0x102000, 0x104000), leaving 0x104000 and 0x105000 free!
    // Region 3: reserved [0x106000, 0x107000)
    const highest_ram_end: u64 = 160 * 1024 * 1024;
    const regions = [_]MemoryRegion{
        .{ .base = 0xFE000, .length = 3 * PAGE_SIZE, .kind = .usable },
        .{ .base = 0x101000, .length = PAGE_SIZE, .kind = .bootloader_reclaimable },
        .{ .base = 0x102000, .length = 4 * PAGE_SIZE, .kind = .usable },
        .{ .base = 0x106000, .length = PAGE_SIZE, .kind = .reserved },
        .{ .base = highest_ram_end - PAGE_SIZE, .length = PAGE_SIZE, .kind = .executable_and_modules },
    };

    var pmm: PhysicalAllocator = .{};
    try pmm.initFromSlice(&regions, backend.bitmapProvider(), backend.pageZeroer());
    try testing.expectEqual(@as(u64, 0x102000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x104000), pmm.bitmap_end_phys);
    try testing.expectEqual(@as(usize, 3), pmm.free_pages); // 0x100000, 0x104000, 0x105000

    // Allocate all 3 usable pages: 0x100000 and 0x104000..0x106000.
    try testing.expectEqual(@as(?u64, 0x100000), pmm.allocPage());
    const span = pmm.allocPages(2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x104000), span);
    try testing.expectEqual(@as(usize, 0), pmm.free_pages);

    const snapshot = try testing.allocator.dupe(u8, pmm.bitmap);
    defer testing.allocator.free(snapshot);
    const prev_used = pmm.used_pages;
    const prev_free = pmm.free_pages;
    const prev_cursor = pmm.last_scanned_byte;

    // Case 1: Usable allocated frames [0x104000, 0x105000] crossing into `.reserved` 0x106000.
    try expectFreeUnchanged(&pmm, error.NotUsableRegion, pmm.freePages(0x104000, 3), snapshot, prev_used, prev_free, prev_cursor);
    try testing.expect(pmm.isPageAllocated(0x104000));
    try testing.expect(pmm.isPageAllocated(0x105000));

    // Case 2: Valid usable 0x100000 crossing `.bootloader_reclaimable` 0x101000 and into bitmap 0x102000.
    try expectFreeUnchanged(&pmm, error.NotUsableRegion, pmm.freePages(0x100000, 2), snapshot, prev_used, prev_free, prev_cursor);
    try testing.expect(pmm.isPageAllocated(0x100000));

    // Case 3: Bitmap range [0x102000, 0x104000) crossing into valid usable allocated [0x104000, 0x106000).
    try expectFreeUnchanged(&pmm, error.BitmapOverlap, pmm.freePages(0x103000, 2), snapshot, prev_used, prev_free, prev_cursor);
    try expectFreeUnchanged(&pmm, error.BitmapOverlap, pmm.freePages(0x102000, 4), snapshot, prev_used, prev_free, prev_cursor);

    // Case 4: `< 1 MiB` crossing into valid usable 0x100000.
    try expectFreeUnchanged(&pmm, error.ReservedAddress, pmm.freePages(0xFE000, 3), snapshot, prev_used, prev_free, prev_cursor);
    try testing.expect(pmm.isPageAllocated(0x100000));

    // Case 5: Overflow count guard & out-of-bounds span from valid allocated top page.
    try expectFreeUnchanged(&pmm, error.OutOfBounds, pmm.freePages(0x104000, std.math.maxInt(usize)), snapshot, prev_used, prev_free, prev_cursor);

    // Case 6: Free valid span atomically, then confirm crossing allocated->free fails atomically on DoubleFree.
    try pmm.freePage(0x105000);
    const snap_one_free = try testing.allocator.dupe(u8, pmm.bitmap);
    defer testing.allocator.free(snap_one_free);
    try expectFreeUnchanged(&pmm, error.DoubleFree, pmm.freePages(0x104000, 2), snap_one_free, pmm.used_pages, pmm.free_pages, pmm.last_scanned_byte);
    try testing.expect(pmm.isPageAllocated(0x104000));

    try pmm.freePage(0x104000);
    try pmm.freePage(0x100000);
    try testing.expectEqual(@as(usize, 3), pmm.free_pages);
    try assertInvariants(&pmm);
}

test "F-16: bitmap placement strictly enforces >= 1 MiB, alignment, complete multi-page fit, and later fallback" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 32, 16384);
    defer backend.deinit();

    // 1. Region entirely below 1 MiB (even touching 0x100000 at its exclusive top) is rejected.
    const strictly_below = [_]MemoryRegion{
        .{ .base = 0x1000, .length = 0xFF000, .kind = .usable },
    };
    var pmm: PhysicalAllocator = .{};
    try testing.expectError(
        error.NoUsableBitmapRegion,
        pmm.initFromSlice(&strictly_below, backend.bitmapProvider(), backend.pageZeroer()),
    );

    // 2. Region crossing 1 MiB clamps candidate up to 0x100000 if sufficient complete pages fit above 1 MiB.
    const crossing = [_]MemoryRegion{
        .{ .base = 0x80000, .length = 0x84000, .kind = .usable }, // 0x80000..0x104000 (4 pages >= 1 MiB)
    };
    try pmm.initFromSlice(&crossing, backend.bitmapProvider(), backend.pageZeroer());
    try testing.expectEqual(@as(u64, 0x100000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x101000), pmm.bitmap_end_phys);
    try testing.expectEqual(@as(u64, 0), pmm.bitmap_phys % PAGE_SIZE);
    try testing.expectEqual(@as(usize, 4), pmm.usable_pages);
    try testing.expectEqual(@as(usize, 3), pmm.free_pages);
    try testing.expect(pmm.isPageAllocated(0x80000));
    try testing.expect(pmm.isPageAllocated(0x100000));
    try assertInvariants(&pmm);

    // 3. Multi-page bitmap backing (5,120 bytes => 2 complete pages = 8,192 bytes) skips:
    //    - region below 1 MiB
    //    - region crossing 1 MiB with < 1 page above 1 MiB (0x80000..0x100800)
    //    - region at 0x101000 with 6,144 bytes (fits logical 5,120 B, but NOT 2 full physical pages = 8,192 B!)
    //    - unaligned region [0x104400, 0x106000) where page-aligned candidate 0x105000 leaves only 4,096 B < 8,192 B
    //    and selects the later qualifying region [0x108400, 0x10C000) at aligned 0x109000!
    const highest_ram_end: u64 = 160 * 1024 * 1024;
    const skipped_then_selected = [_]MemoryRegion{
        .{ .base = 0x1000, .length = 0x40000, .kind = .usable },
        .{ .base = 0x80000, .length = 0x80800, .kind = .usable },
        .{ .base = 0x101000, .length = 6144, .kind = .usable },
        .{ .base = 0x104400, .length = 0x1C00, .kind = .usable },
        .{ .base = 0x108400, .length = 0x3C00, .kind = .usable }, // 0x109000..0x10C000 (3 complete pages!)
        .{ .base = highest_ram_end - PAGE_SIZE, .length = PAGE_SIZE, .kind = .bootloader_reclaimable },
    };
    try pmm.initFromSlice(&skipped_then_selected, backend.bitmapProvider(), backend.pageZeroer());
    try testing.expectEqual(@as(usize, 5120), pmm.bitmap.len);
    try testing.expectEqual(@as(u64, 0x109000), pmm.bitmap_phys);
    try testing.expectEqual(@as(u64, 0x10B000), pmm.bitmap_end_phys);
    try testing.expect(pmm.bitmap_phys >= physical_core.LOW_MEMORY_LIMIT);
    try testing.expectEqual(@as(u64, 0), pmm.bitmap_phys % PAGE_SIZE);
    try testing.expect(pmm.isPageAllocated(0x109000));
    try testing.expect(pmm.isPageAllocated(0x10A000));
    // Usable frames in skipped candidates (`0x101000`, `0x105000`) and tail of selected (`0x10B000`) remain free!
    try testing.expect(!pmm.isPageAllocated(0x101000));
    try testing.expect(!pmm.isPageAllocated(0x105000));
    try testing.expect(!pmm.isPageAllocated(0x10B000));
    try testing.expectEqual(@as(usize, 3), pmm.free_pages);
    try assertInvariants(&pmm);
}

fn createAllocatorViaSliceReturn(
    regions: []const MemoryRegion,
    bitmap_provider: physical_core.BitmapProvider,
    zeroer: physical_core.PageZeroer,
) !PhysicalAllocator {
    var local_pmm: PhysicalAllocator = .{};
    try local_pmm.initFromSlice(regions, bitmap_provider, zeroer);
    return local_pmm;
}

const ProviderLifetimeCtx = struct {
    regions: []const MemoryRegion,
    reads: usize = 0,

    fn provider(self: *ProviderLifetimeCtx) physical_core.RegionProvider {
        return .{
            .ctx = self,
            .countFn = countFn,
            .getFn = getFn,
        };
    }

    fn countFn(ctx: *const anyopaque) usize {
        const self: *const ProviderLifetimeCtx = @ptrCast(@alignCast(ctx));
        return self.regions.len;
    }

    fn getFn(ctx: *const anyopaque, index: usize) MemoryRegion {
        const self: *ProviderLifetimeCtx = @ptrCast(@alignCast(@constCast(ctx)));
        self.reads += 1;
        return self.regions[index];
    }
};

fn initViaProviderHelper(
    pmm: *PhysicalAllocator,
    ctx: *ProviderLifetimeCtx,
    bitmap_provider: physical_core.BitmapProvider,
    zeroer: physical_core.PageZeroer,
) !void {
    try pmm.init(ctx.provider(), bitmap_provider, zeroer);
}

noinline fn clobberStackFrame() u64 {
    var scratch: [256]u64 = undefined;
    for (&scratch, 0..) |*slot, i| {
        slot.* = @as(u64, i) ^ 0xDEAD_BEEF_CAFE_BABE;
    }
    var sum: u64 = 0;
    for (scratch) |v| sum +%= v;
    return sum;
}

test "PMM retains region source safely across helper returns, stack reuse, and reinitialization" {
    var backend = try FakeMemoryBackend.init(testing.allocator, 0x100000, 16, 512);
    defer backend.deinit();

    const regions_a = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 4 * PAGE_SIZE, .kind = .usable },
        .{ .base = 0x104000, .length = 2 * PAGE_SIZE, .kind = .reserved },
        .{ .base = 0x106000, .length = PAGE_SIZE, .kind = .bootloader_reclaimable },
    };

    // 1. Copy-by-value return out of helper + stack clobber must leave slice source valid.
    var pmm = try createAllocatorViaSliceReturn(&regions_a, backend.bitmapProvider(), backend.pageZeroer());
    std.mem.doNotOptimizeAway(clobberStackFrame());

    const p0 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x101000
    try testing.expectError(error.NotUsableRegion, pmm.freePage(0x104000));
    try testing.expectError(error.BitmapOverlap, pmm.freePage(0x100000));
    try pmm.freePage(p0);
    try assertInvariants(&pmm);

    // 2. Reinitialize via external long-lived RegionProvider inside a helper whose stack frame disappears.
    const regions_b = [_]MemoryRegion{
        .{ .base = 0x100000, .length = 2 * PAGE_SIZE, .kind = .usable }, // 0x101000 now smaller
        .{ .base = 0x102000, .length = 2 * PAGE_SIZE, .kind = .bootloader_reclaimable }, // was usable in A!
    };
    var provider_ctx: ProviderLifetimeCtx = .{ .regions = &regions_b };
    try initViaProviderHelper(&pmm, &provider_ctx, backend.bitmapProvider(), backend.pageZeroer());
    std.mem.doNotOptimizeAway(clobberStackFrame());

    const reads_after_init = provider_ctx.reads;
    const b0 = pmm.allocPage() orelse return error.TestUnexpectedResult; // 0x101000
    try testing.expectEqual(@as(u64, 0x101000), b0);
    // 0x102000 was `.usable` in regions_a, but reinitialization switched cleanly to regions_b (`.bootloader_reclaimable`).
    try testing.expectError(error.NotUsableRegion, pmm.freePage(0x102000));
    try testing.expect(provider_ctx.reads > reads_after_init);
    try pmm.freePage(b0);
    try assertInvariants(&pmm);
}
