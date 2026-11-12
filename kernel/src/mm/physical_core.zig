// Stateful Physical Memory Manager (PMM) Core
// Hardware-independent bitmap physical frame allocator shared between the freestanding kernel and host unit tests.

const physical_math = @import("physical_math.zig");

pub const math = physical_math;
pub const PAGE_SIZE: u64 = physical_math.PAGE_SIZE;

pub const RegionKind = enum {
    usable,
    non_usable,
};

pub const MemoryRegion = struct {
    base: u64,
    length: u64,
    kind: RegionKind,
};

/// Read-only memory-map provider allowing Limine boot entries and synthetic host slices
/// to be scanned without dynamic allocation inside the PMM.
pub const RegionProvider = struct {
    ctx: *const anyopaque,
    countFn: *const fn (ctx: *const anyopaque) usize,
    getFn: *const fn (ctx: *const anyopaque, index: usize) MemoryRegion,

    pub inline fn count(self: RegionProvider) usize {
        return self.countFn(self.ctx);
    }

    pub inline fn get(self: RegionProvider, index: usize) MemoryRegion {
        return self.getFn(self.ctx, index);
    }

    const SliceContext = struct {
        regions: []const MemoryRegion,
    };

    pub fn fromSlice(slice_ctx: *const SliceContext) RegionProvider {
        return .{
            .ctx = slice_ctx,
            .countFn = sliceCount,
            .getFn = sliceGet,
        };
    }

    fn sliceCount(ctx: *const anyopaque) usize {
        const view: *const SliceContext = @ptrCast(@alignCast(ctx));
        return view.regions.len;
    }

    fn sliceGet(ctx: *const anyopaque, index: usize) MemoryRegion {
        const view: *const SliceContext = @ptrCast(@alignCast(ctx));
        return view.regions[index];
    }
};

pub const InitError = error{
    NoUsableBitmapRegion,
    BitmapBackingTooSmall,
};

pub const FreeError = error{
    UnalignedAddress,
    OutOfBounds,
    DoubleFree,
};

/// Resolves the allocator-chosen physical bitmap address to writable byte storage.
/// Kernel binds this to HHDM-mapped physical memory; host tests supply a local buffer.
pub const BitmapProvider = struct {
    ctx: ?*anyopaque = null,
    acquireFn: *const fn (ctx: ?*anyopaque, bitmap_phys: u64, size_bytes: usize) InitError![]u8,

    pub inline fn acquire(self: BitmapProvider, bitmap_phys: u64, size_bytes: usize) InitError![]u8 {
        return self.acquireFn(self.ctx, bitmap_phys, size_bytes);
    }
};

/// Zeroes `page_count` contiguous frames starting at `paddr`.
/// Kernel zeroes via HHDM; host tests validate bounds and zero simulated memory buffers.
pub const PageZeroer = struct {
    ctx: ?*anyopaque = null,
    zeroFn: *const fn (ctx: ?*anyopaque, paddr: u64, page_count: usize) void,

    pub inline fn zeroPages(self: PageZeroer, paddr: u64, page_count: usize) void {
        self.zeroFn(self.ctx, paddr, page_count);
    }
};

fn noOpZero(_: ?*anyopaque, _: u64, _: usize) void {}

pub const PhysicalAllocator = struct {
    bitmap: []u8 = &.{},
    total_pages: usize = 0,
    usable_pages: usize = 0,
    used_pages: usize = 0,
    free_pages: usize = 0,
    highest_address: u64 = 0,
    bitmap_phys: u64 = 0,
    last_scanned_byte: usize = 0,
    zeroer: PageZeroer = .{ .ctx = null, .zeroFn = noOpZero },

    const Self = @This();

    inline fn isBitSet(self: *const Self, frame: usize) bool {
        const byte_idx = physical_math.frameToByteIndex(frame);
        const bit_idx = physical_math.frameToBitIndex(frame);
        return (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    inline fn setBit(self: *Self, frame: usize) void {
        const byte_idx = physical_math.frameToByteIndex(frame);
        const bit_idx = physical_math.frameToBitIndex(frame);
        self.bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
    }

    inline fn clearBit(self: *Self, frame: usize) void {
        const byte_idx = physical_math.frameToByteIndex(frame);
        const bit_idx = physical_math.frameToBitIndex(frame);
        self.bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    pub fn initFromSlice(
        self: *Self,
        regions: []const MemoryRegion,
        bitmap_provider: BitmapProvider,
        zeroer: PageZeroer,
    ) InitError!void {
        const slice_ctx: RegionProvider.SliceContext = .{ .regions = regions };
        return self.init(RegionProvider.fromSlice(&slice_ctx), bitmap_provider, zeroer);
    }

    pub fn init(
        self: *Self,
        regions: RegionProvider,
        bitmap_provider: BitmapProvider,
        zeroer: PageZeroer,
    ) InitError!void {
        const region_count = regions.count();

        // Preserve full-map scan across all region types to determine total tracked frame count.
        var computed_highest: u64 = 0;
        for (0..region_count) |i| {
            const region = regions.get(i);
            const region_top = region.base + region.length;
            if (region_top > computed_highest) {
                computed_highest = region_top;
            }
        }

        const computed_total_pages = physical_math.totalPagesFromBytes(computed_highest);
        const computed_bitmap_size = physical_math.bitmapSizeBytes(computed_total_pages);
        if (computed_bitmap_size == 0) {
            return error.NoUsableBitmapRegion;
        }

        // Preserve existing bitmap placement rule: first non-zero-based usable entry holding bitmap_size_bytes.
        var chosen_bitmap_phys: ?u64 = null;
        for (0..region_count) |i| {
            const region = regions.get(i);
            if (region.kind == .usable and region.length >= computed_bitmap_size and region.base != 0) {
                chosen_bitmap_phys = region.base;
                break;
            }
        }

        const resolved_bitmap_phys = chosen_bitmap_phys orelse return error.NoUsableBitmapRegion;
        const acquired_bitmap = try bitmap_provider.acquire(resolved_bitmap_phys, computed_bitmap_size);
        if (acquired_bitmap.len < computed_bitmap_size) {
            return error.BitmapBackingTooSmall;
        }

        self.* = .{
            .bitmap = acquired_bitmap[0..computed_bitmap_size],
            .total_pages = computed_total_pages,
            .usable_pages = 0,
            .used_pages = 0,
            .free_pages = 0,
            .highest_address = computed_highest,
            .bitmap_phys = resolved_bitmap_phys,
            .last_scanned_byte = 0,
            .zeroer = zeroer,
        };

        // Default all bits (including unused tail bits in a partial final bitmap byte) to USED.
        @memset(self.bitmap, 0xFF);

        // Clear exclusively USABLE ranges >= 1 MiB.
        for (0..region_count) |i| {
            const region = regions.get(i);
            if (region.kind == .usable) {
                const start_frame: usize = physical_math.totalPagesFromBytes(region.base);
                const end_frame: usize = physical_math.physToFrame(region.base + region.length);

                var frame = start_frame;
                while (frame < end_frame and frame < self.total_pages) : (frame += 1) {
                    // Keep the first 1 MiB / page 0 reserved for legacy BIOS/hardware stability.
                    if (@as(u64, @intCast(frame)) * PAGE_SIZE < 0x100000) {
                        continue;
                    }
                    self.clearBit(frame);
                    self.usable_pages += 1;
                }
            }
        }

        // Reserve the physical pages occupied by the bitmap itself.
        const bitmap_start_frame: usize = physical_math.physToFrame(resolved_bitmap_phys);
        const bitmap_end_frame: usize = physical_math.totalPagesFromBytes(
            resolved_bitmap_phys + @as(u64, @intCast(computed_bitmap_size)),
        );

        var b_frame = bitmap_start_frame;
        while (b_frame < bitmap_end_frame and b_frame < self.total_pages) : (b_frame += 1) {
            self.setBit(b_frame);
        }

        // Recount authoritative used and free frame totals across tracked frames [0..total_pages).
        const full_bytes = self.total_pages / 8;
        var byte_idx: usize = 0;

        while (byte_idx + 8 <= full_bytes) : (byte_idx += 8) {
            const word = @as(*align(1) const u64, @ptrCast(self.bitmap.ptr + byte_idx)).*;
            if (word == 0xFFFF_FFFF_FFFF_FFFF) {
                self.used_pages += 64;
            } else {
                const used_in_word: usize = @popCount(word);
                self.used_pages += used_in_word;
                self.free_pages += 64 - used_in_word;
            }
        }

        while (byte_idx < full_bytes) : (byte_idx += 1) {
            const used_in_byte: usize = @popCount(self.bitmap[byte_idx]);
            self.used_pages += used_in_byte;
            self.free_pages += 8 - used_in_byte;
        }

        const tail_start_frame = full_bytes * 8;
        for (tail_start_frame..self.total_pages) |f| {
            if (self.isBitSet(f)) {
                self.used_pages += 1;
            } else {
                self.free_pages += 1;
            }
        }
    }

    pub fn allocPage(self: *Self) ?u64 {
        var byte_idx = self.last_scanned_byte;
        var scanned_bytes: usize = 0;

        while (scanned_bytes < self.bitmap.len) : (scanned_bytes += 1) {
            if (self.bitmap[byte_idx] != 0xFF) {
                const byte = self.bitmap[byte_idx];
                const bit_idx: u3 = @truncate(@ctz(~byte));
                const frame = byte_idx * 8 + bit_idx;

                if (frame < self.total_pages) {
                    self.setBit(frame);
                    self.used_pages += 1;
                    self.free_pages -= 1;
                    self.last_scanned_byte = byte_idx;

                    const paddr: u64 = @as(u64, @intCast(frame)) * PAGE_SIZE;
                    self.zeroer.zeroPages(paddr, 1);
                    return paddr;
                }
            }

            byte_idx += 1;
            if (byte_idx >= self.bitmap.len) {
                byte_idx = 0;
            }
        }

        return null;
    }

    pub fn allocPages(self: *Self, count: usize) ?u64 {
        if (count == 0) return null;
        if (count == 1) return self.allocPage();
        if (count > self.free_pages) return null;

        var consecutive: usize = 0;
        var start_frame: usize = 0;

        for (0..self.total_pages) |frame| {
            if (!self.isBitSet(frame)) {
                if (consecutive == 0) {
                    start_frame = frame;
                }
                consecutive += 1;
                if (consecutive == count) {
                    for (start_frame..(start_frame + count)) |f| {
                        self.setBit(f);
                    }
                    self.used_pages += count;
                    self.free_pages -= count;

                    const base_paddr: u64 = @as(u64, @intCast(start_frame)) * PAGE_SIZE;
                    self.zeroer.zeroPages(base_paddr, count);
                    return base_paddr;
                }
            } else {
                consecutive = 0;
            }
        }

        return null;
    }

    pub fn freePage(self: *Self, paddr: u64) FreeError!void {
        if (paddr % PAGE_SIZE != 0) {
            return error.UnalignedAddress;
        }

        const frame: usize = physical_math.physToFrame(paddr);
        if (frame >= self.total_pages) {
            return error.OutOfBounds;
        }

        if (!self.isBitSet(frame)) {
            return error.DoubleFree;
        }

        self.clearBit(frame);
        self.used_pages -= 1;
        self.free_pages += 1;

        const byte_idx = physical_math.frameToByteIndex(frame);
        if (byte_idx < self.last_scanned_byte) {
            self.last_scanned_byte = byte_idx;
        }
    }

    pub fn freePages(self: *Self, paddr: u64, count: usize) FreeError!void {
        if (count == 0) return;
        if (paddr % PAGE_SIZE != 0) {
            return error.UnalignedAddress;
        }

        const start_frame: usize = physical_math.physToFrame(paddr);
        if (start_frame >= self.total_pages or count > self.total_pages - start_frame) {
            return error.OutOfBounds;
        }

        for (start_frame..(start_frame + count)) |frame| {
            if (!self.isBitSet(frame)) {
                return error.DoubleFree;
            }
        }

        for (0..count) |i| {
            try self.freePage(paddr + @as(u64, @intCast(i)) * PAGE_SIZE);
        }
    }

    pub fn isPageAllocated(self: *const Self, paddr: u64) bool {
        const frame: usize = physical_math.physToFrame(paddr);
        if (frame >= self.total_pages) return true;
        return self.isBitSet(frame);
    }
};
