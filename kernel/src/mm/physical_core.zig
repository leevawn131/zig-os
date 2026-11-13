// Stateful Physical Memory Manager (PMM) Core
// Hardware-independent bitmap physical frame allocator shared between the freestanding kernel and host unit tests.

const std = @import("std");
const physical_math = @import("physical_math.zig");

pub const math = physical_math;
pub const PAGE_SIZE: u64 = physical_math.PAGE_SIZE;
/// Physical addresses strictly below 1 MiB remain permanently reserved for legacy hardware/trampolines.
pub const LOW_MEMORY_LIMIT: u64 = 0x100000;

/// Hardware-independent physical memory-map classification mirroring Limine `MemmapType`.
pub const RegionKind = enum {
    usable,
    bootloader_reclaimable,
    acpi_reclaimable,
    executable_and_modules,
    reserved,
    acpi_nvs,
    bad_memory,
    framebuffer,
    reserved_mapped,
    unknown,

    /// Returns true when the region represents RAM-backed storage that defines the tracked physical ceiling.
    /// Non-RAM apertures (MMIO `.reserved`, `.framebuffer`, `.acpi_nvs`, etc.) are excluded so high PCIe BARs
    /// do not bloat the physical allocation bitmap.
    pub fn contributesToHighestAddress(self: RegionKind) bool {
        return switch (self) {
            .usable,
            .bootloader_reclaimable,
            .acpi_reclaimable,
            .executable_and_modules,
            => true,
            .reserved,
            .acpi_nvs,
            .bad_memory,
            .framebuffer,
            .reserved_mapped,
            .unknown,
            => false,
        };
    }

    /// Returns true only for memory eligible for general allocation, bitmap placement, and `freePage`.
    pub fn isUsable(self: RegionKind) bool {
        return self == .usable;
    }
};

pub const MemoryRegion = struct {
    base: u64,
    length: u64,
    kind: RegionKind,
};

/// Read-only memory-map provider allowing Limine boot entries and synthetic host views
/// to be scanned without dynamic allocation inside the PMM.
/// Callers must keep `ctx` and its underlying region records valid and immutable for the
/// lifetime of the `PhysicalAllocator` (never a stack-local variable inside an `init` wrapper).
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

    pub const SliceContext = struct {
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

/// Retained memory-map source stored directly inside `PhysicalAllocator` by value so
/// `initFromSlice` never introduces self-referential stack pointers across allocator copies.
const RegionSource = union(enum) {
    none,
    slice: []const MemoryRegion,
    provider: RegionProvider,

    inline fn count(self: RegionSource) usize {
        return switch (self) {
            .none => 0,
            .slice => |regions| regions.len,
            .provider => |p| p.count(),
        };
    }

    inline fn get(self: RegionSource, index: usize) MemoryRegion {
        return switch (self) {
            .none => unreachable,
            .slice => |regions| regions[index],
            .provider => |p| p.get(index),
        };
    }
};

pub const InitError = error{
    NoUsableBitmapRegion,
    BitmapBackingTooSmall,
};

pub const FreeError = error{
    UnalignedAddress,
    OutOfBounds,
    ReservedAddress,
    BitmapOverlap,
    NotUsableRegion,
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

fn bytesToPageCountCeil(bytes: u64) u64 {
    return (bytes / PAGE_SIZE) + @intFromBool((bytes % PAGE_SIZE) != 0);
}

fn alignUpPage(addr: u64) ?u64 {
    const rem = addr % PAGE_SIZE;
    if (rem == 0) return addr;
    return std.math.add(u64, addr, PAGE_SIZE - rem) catch null;
}

inline fn alignDownPage(addr: u64) u64 {
    return addr - (addr % PAGE_SIZE);
}

fn overlapsNonUsableRegion(source: RegionSource, start: u64, end: u64) bool {
    const region_count = source.count();
    for (0..region_count) |i| {
        const region = source.get(i);
        if (region.kind.isUsable() or region.length == 0) continue;
        const region_end = std.math.add(u64, region.base, region.length) catch std.math.maxInt(u64);
        if (start < region_end and end > region.base) {
            return true;
        }
    }
    return false;
}

pub const PhysicalAllocator = struct {
    bitmap: []u8 = &.{},
    total_pages: usize = 0,
    usable_pages: usize = 0,
    used_pages: usize = 0,
    free_pages: usize = 0,
    highest_address: u64 = 0,
    bitmap_phys: u64 = 0,
    bitmap_end_phys: u64 = 0,
    last_scanned_byte: usize = 0,
    region_source: RegionSource = .none,
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

    /// Initializes (or reinitializes) the allocator from a caller-owned slice of memory regions.
    /// Lifetime contract: `regions` must remain valid and immutable for the lifetime of this
    /// `PhysicalAllocator` (or until reinitialized). Fails atomically without mutating prior state.
    pub fn initFromSlice(
        self: *Self,
        regions: []const MemoryRegion,
        bitmap_provider: BitmapProvider,
        zeroer: PageZeroer,
    ) InitError!void {
        return self.initWithSource(.{ .slice = regions }, bitmap_provider, zeroer);
    }

    /// Initializes (or reinitializes) the allocator from an external `RegionProvider`.
    /// Lifetime contract: `regions.ctx` and the region entries it reads must remain valid and
    /// immutable for the lifetime of this `PhysicalAllocator` (or until reinitialized).
    pub fn init(
        self: *Self,
        regions: RegionProvider,
        bitmap_provider: BitmapProvider,
        zeroer: PageZeroer,
    ) InitError!void {
        return self.initWithSource(.{ .provider = regions }, bitmap_provider, zeroer);
    }

    fn initWithSource(
        self: *Self,
        source: RegionSource,
        bitmap_provider: BitmapProvider,
        zeroer: PageZeroer,
    ) InitError!void {
        const region_count = source.count();

        // Track only RAM-backed regions so high non-RAM apertures (MMIO, framebuffer, etc.)
        // do not inflate the allocation bitmap ceiling.
        var computed_highest: u64 = 0;
        for (0..region_count) |i| {
            const region = source.get(i);
            if (!region.kind.contributesToHighestAddress() or region.length == 0) {
                continue;
            }
            const region_top = std.math.add(u64, region.base, region.length) catch return error.NoUsableBitmapRegion;
            if (region_top > computed_highest) {
                computed_highest = region_top;
            }
        }

        const total_pages_u64 = bytesToPageCountCeil(computed_highest);
        const computed_total_pages = std.math.cast(usize, total_pages_u64) orelse return error.NoUsableBitmapRegion;
        if (computed_total_pages == 0) {
            return error.NoUsableBitmapRegion;
        }
        const computed_bitmap_size = physical_math.bitmapSizeBytes(computed_total_pages);
        if (computed_bitmap_size == 0) {
            return error.NoUsableBitmapRegion;
        }

        const bitmap_pages_u64 = bytesToPageCountCeil(@as(u64, @intCast(computed_bitmap_size)));
        const bitmap_backing_bytes = std.math.mul(u64, bitmap_pages_u64, PAGE_SIZE) catch return error.NoUsableBitmapRegion;

        // Place the bitmap exclusively in `.usable` RAM >= 1 MiB, page-aligned, with room for its
        // full page-rounded physical backing `[bitmap_phys, bitmap_end_phys)`.
        var chosen_bitmap_phys: ?u64 = null;
        var chosen_bitmap_end: u64 = 0;
        for (0..region_count) |i| {
            const region = source.get(i);
            if (!region.kind.isUsable() or region.length == 0) {
                continue;
            }

            const region_end = std.math.add(u64, region.base, region.length) catch continue;
            const candidate_start = alignUpPage(@max(region.base, LOW_MEMORY_LIMIT)) orelse continue;
            if (candidate_start >= region_end) {
                continue;
            }

            if ((region_end - candidate_start) < bitmap_backing_bytes) {
                continue;
            }

            const candidate_end = std.math.add(u64, candidate_start, bitmap_backing_bytes) catch continue;
            if (overlapsNonUsableRegion(source, candidate_start, candidate_end)) {
                continue;
            }

            chosen_bitmap_phys = candidate_start;
            chosen_bitmap_end = candidate_end;
            break;
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
            .bitmap_end_phys = chosen_bitmap_end,
            .last_scanned_byte = 0,
            .region_source = source,
            .zeroer = zeroer,
        };

        // Default all bits (including unused tail bits in a partial final bitmap byte) to USED.
        @memset(self.bitmap, 0xFF);

        // Clear exclusively whole `.usable` frames >= 1 MiB.
        for (0..region_count) |i| {
            const region = source.get(i);
            if (!region.kind.isUsable() or region.length == 0) {
                continue;
            }

            const region_end = std.math.add(u64, region.base, region.length) catch continue;
            const clipped_start = @max(region.base, LOW_MEMORY_LIMIT);
            if (clipped_start >= region_end) {
                continue;
            }

            const aligned_start = alignUpPage(clipped_start) orelse continue;
            const aligned_end = alignDownPage(region_end);
            if (aligned_end <= aligned_start) {
                continue;
            }

            const start_frame: usize = physical_math.physToFrame(aligned_start);
            const end_frame: usize = physical_math.physToFrame(aligned_end);

            var frame = start_frame;
            while (frame < end_frame and frame < self.total_pages) : (frame += 1) {
                self.clearBit(frame);
                self.usable_pages += 1;
            }
        }

        // Defensively keep frames overlapping any non-usable entry marked USED if firmware reported overlaps.
        for (0..region_count) |i| {
            const region = source.get(i);
            if (region.kind.isUsable() or region.length == 0) {
                continue;
            }

            const start_frame_u64 = region.base / PAGE_SIZE;
            if (start_frame_u64 >= self.total_pages) {
                continue;
            }

            const region_end = std.math.add(u64, region.base, region.length) catch std.math.maxInt(u64);
            const end_frame_u64 = bytesToPageCountCeil(region_end);
            const start_frame: usize = @intCast(start_frame_u64);
            const end_frame: usize = @intCast(@min(end_frame_u64, @as(u64, @intCast(self.total_pages))));

            var frame = start_frame;
            while (frame < end_frame) : (frame += 1) {
                if (!self.isBitSet(frame)) {
                    self.setBit(frame);
                    if (self.usable_pages > 0) {
                        self.usable_pages -= 1;
                    }
                }
            }
        }

        // Reserve all complete physical pages occupied by the bitmap backing `[bitmap_phys, bitmap_end_phys)`.
        const bitmap_start_frame: usize = physical_math.physToFrame(resolved_bitmap_phys);
        const bitmap_end_frame: usize = physical_math.physToFrame(chosen_bitmap_end);

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

    fn overlapsBitmapPage(self: *const Self, paddr: u64) bool {
        if (self.bitmap_end_phys <= self.bitmap_phys) return false;
        const page_end = std.math.add(u64, paddr, PAGE_SIZE) catch return false;
        return paddr < self.bitmap_end_phys and page_end > self.bitmap_phys;
    }

    fn isPageInUsableRegion(self: *const Self, paddr: u64) bool {
        const page_end = std.math.add(u64, paddr, PAGE_SIZE) catch return false;
        const region_count = self.region_source.count();

        var in_usable = false;
        for (0..region_count) |i| {
            const region = self.region_source.get(i);
            if (region.length == 0) continue;

            if (region.kind.isUsable()) {
                const region_end = std.math.add(u64, region.base, region.length) catch continue;
                if (paddr >= region.base and page_end <= region_end) {
                    in_usable = true;
                }
            } else {
                const region_end = std.math.add(u64, region.base, region.length) catch std.math.maxInt(u64);
                if (paddr < region_end and page_end > region.base) {
                    return false;
                }
            }
        }
        return in_usable;
    }

    fn validateFreePage(self: *const Self, paddr: u64) FreeError!usize {
        if (paddr % PAGE_SIZE != 0) {
            return error.UnalignedAddress;
        }

        const frame = std.math.cast(usize, paddr / PAGE_SIZE) orelse return error.OutOfBounds;
        if (frame >= self.total_pages) {
            return error.OutOfBounds;
        }

        if (paddr < LOW_MEMORY_LIMIT) {
            return error.ReservedAddress;
        }

        if (self.overlapsBitmapPage(paddr)) {
            return error.BitmapOverlap;
        }

        if (!self.isPageInUsableRegion(paddr)) {
            return error.NotUsableRegion;
        }

        if (!self.isBitSet(frame)) {
            return error.DoubleFree;
        }

        return frame;
    }

    inline fn releaseValidatedFrame(self: *Self, frame: usize) void {
        self.clearBit(frame);
        self.used_pages -= 1;
        self.free_pages += 1;

        const byte_idx = physical_math.frameToByteIndex(frame);
        if (byte_idx < self.last_scanned_byte) {
            self.last_scanned_byte = byte_idx;
        }
    }

    pub fn freePage(self: *Self, paddr: u64) FreeError!void {
        const frame = try self.validateFreePage(paddr);
        self.releaseValidatedFrame(frame);
    }

    pub fn freePages(self: *Self, paddr: u64, count: usize) FreeError!void {
        if (count == 0) return;
        if (paddr % PAGE_SIZE != 0) {
            return error.UnalignedAddress;
        }

        const start_frame = std.math.cast(usize, paddr / PAGE_SIZE) orelse return error.OutOfBounds;
        if (start_frame >= self.total_pages or count > self.total_pages - start_frame) {
            return error.OutOfBounds;
        }

        // Validate every page in the range before clearing any bit or updating counters
        // so failures remain strictly atomic with zero partial frees.
        for (0..count) |i| {
            const offset = std.math.mul(u64, @as(u64, @intCast(i)), PAGE_SIZE) catch return error.OutOfBounds;
            const page_paddr = std.math.add(u64, paddr, offset) catch return error.OutOfBounds;
            _ = try self.validateFreePage(page_paddr);
        }

        for (0..count) |i| {
            self.releaseValidatedFrame(start_frame + i);
        }
    }

    pub fn isPageAllocated(self: *const Self, paddr: u64) bool {
        const frame: usize = physical_math.physToFrame(paddr);
        if (frame >= self.total_pages) return true;
        return self.isBitSet(frame);
    }
};
