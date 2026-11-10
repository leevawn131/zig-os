// Physical Memory Manager (PMM)
// Production-quality bitmap physical frame allocator
const std = @import("std");
const limine = @import("../limine.zig");
const serial = @import("../drivers/serial/serial.zig");

pub const PAGE_SIZE: u64 = 4096;

pub var hhdm_offset: u64 = 0;
pub var bitmap: [*]u8 = undefined;
pub var bitmap_size_bytes: usize = 0;

pub var total_pages: usize = 0;
pub var usable_pages: usize = 0;
pub var used_pages: usize = 0;
pub var free_pages: usize = 0;
pub var highest_address: u64 = 0;

var last_scanned_byte: usize = 0;

pub inline fn physToVirt(paddr: u64) [*]u8 {
    return @ptrFromInt(paddr + hhdm_offset);
}

pub inline fn virtToPhys(vaddr: usize) u64 {
    return vaddr - hhdm_offset;
}

inline fn isBitSet(frame: usize) bool {
    const byte_idx = frame / 8;
    const bit_idx: u3 = @truncate(frame % 8);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

inline fn setBit(frame: usize) void {
    const byte_idx = frame / 8;
    const bit_idx: u3 = @truncate(frame % 8);
    bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
}

inline fn clearBit(frame: usize) void {
    const byte_idx = frame / 8;
    const bit_idx: u3 = @truncate(frame % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
}

pub fn init() void {
    const hhdm = limine.hhdm_request.response orelse @panic("PMM: Limine HHDM response missing");
    hhdm_offset = hhdm.offset;

    const memmap = limine.memmap_request.response orelse @panic("PMM: Limine memory map response missing");

    // Scan memory map to find highest physical address
    highest_address = 0;
    var total_usable_bytes: u64 = 0;

    for (0..memmap.entry_count) |i| {
        const entry = memmap.entries[i];
        const entry_top = entry.base + entry.length;
        if (entry_top > highest_address) {
            highest_address = entry_top;
        }
        if (entry.type == .usable) {
            total_usable_bytes += entry.length;
        }
    }

    total_pages = @intCast((highest_address + PAGE_SIZE - 1) / PAGE_SIZE);
    bitmap_size_bytes = (total_pages + 7) / 8;

    // Find a usable region with enough space to hold the allocation bitmap
    var bitmap_phys: ?u64 = null;
    for (0..memmap.entry_count) |i| {
        const entry = memmap.entries[i];
        if (entry.type == .usable and entry.length >= bitmap_size_bytes and entry.base != 0) {
            bitmap_phys = entry.base;
            break;
        }
    }

    if (bitmap_phys == null) {
        @panic("PMM: Failed to locate usable physical memory for allocation bitmap");
    }

    bitmap = physToVirt(bitmap_phys.?);

    // Default: Mark all physical frames as 1 (USED / RESERVED)
    @memset(bitmap[0..bitmap_size_bytes], 0xFF);

    // Mark exclusively USABLE ranges as 0 (FREE)
    usable_pages = 0;
    for (0..memmap.entry_count) |i| {
        const entry = memmap.entries[i];
        if (entry.type == .usable) {
            const start_frame: usize = @intCast((entry.base + PAGE_SIZE - 1) / PAGE_SIZE);
            const end_frame: usize = @intCast((entry.base + entry.length) / PAGE_SIZE);

            var frame = start_frame;
            while (frame < end_frame and frame < total_pages) : (frame += 1) {
                // Keep the first 1 MiB / page 0 reserved for legacy BIOS/hardware stability
                if (frame * PAGE_SIZE < 0x100000) {
                    continue;
                }
                clearBit(frame);
                usable_pages += 1;
            }
        }
    }

    // Reserve the memory pages occupied by the bitmap itself
    const bitmap_start_frame: usize = @intCast(bitmap_phys.? / PAGE_SIZE);
    const bitmap_end_frame: usize = @intCast((bitmap_phys.? + bitmap_size_bytes + PAGE_SIZE - 1) / PAGE_SIZE);

    var b_frame = bitmap_start_frame;
    while (b_frame < bitmap_end_frame and b_frame < total_pages) : (b_frame += 1) {
        setBit(b_frame);
    }

    // Recalculate accurate free and used counts
    used_pages = 0;
    free_pages = 0;
    for (0..total_pages) |f| {
        if (isBitSet(f)) {
            used_pages += 1;
        } else {
            free_pages += 1;
        }
    }
}

pub fn allocPage() ?u64 {
    var byte_idx = last_scanned_byte;
    var scanned_bytes: usize = 0;

    while (scanned_bytes < bitmap_size_bytes) : (scanned_bytes += 1) {
        if (bitmap[byte_idx] != 0xFF) {
            const byte = bitmap[byte_idx];
            const bit_idx: u3 = @truncate(@ctz(~byte));
            const frame = byte_idx * 8 + bit_idx;

            if (frame < total_pages) {
                setBit(frame);
                used_pages += 1;
                free_pages -= 1;
                last_scanned_byte = byte_idx;

                const paddr: u64 = @as(u64, @intCast(frame)) * PAGE_SIZE;

                // Zero out the newly allocated page for security and deterministic behavior
                @memset(physToVirt(paddr)[0..PAGE_SIZE], 0);
                return paddr;
            }
        }

        byte_idx += 1;
        if (byte_idx >= bitmap_size_bytes) {
            byte_idx = 0;
        }
    }

    return null; // Out of memory
}

pub fn allocPages(count: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocPage();

    var consecutive: usize = 0;
    var start_frame: usize = 0;

    for (0..total_pages) |frame| {
        if (!isBitSet(frame)) {
            if (consecutive == 0) {
                start_frame = frame;
            }
            consecutive += 1;
            if (consecutive == count) {
                // Mark all `count` frames as used
                for (start_frame..(start_frame + count)) |f| {
                    setBit(f);
                }
                used_pages += count;
                free_pages -= count;

                const base_paddr: u64 = @as(u64, @intCast(start_frame)) * PAGE_SIZE;
                @memset(physToVirt(base_paddr)[0..(count * PAGE_SIZE)], 0);
                return base_paddr;
            }
        } else {
            consecutive = 0;
        }
    }

    return null; // Insufficient contiguous frames
}

pub fn freePage(paddr: u64) void {
    if (paddr % PAGE_SIZE != 0) {
        @panic("PMM: Attempted to free unaligned physical address");
    }

    const frame: usize = @intCast(paddr / PAGE_SIZE);
    if (frame >= total_pages) {
        @panic("PMM: Physical address out of tracked bounds");
    }

    // Double-free prevention check
    if (!isBitSet(frame)) {
        @panic("PMM: Double-free detected on physical page");
    }

    clearBit(frame);
    used_pages -= 1;
    free_pages += 1;

    const byte_idx = frame / 8;
    if (byte_idx < last_scanned_byte) {
        last_scanned_byte = byte_idx;
    }
}

pub fn freePages(paddr: u64, count: usize) void {
    if (count == 0) return;
    if (paddr % PAGE_SIZE != 0) {
        @panic("PMM: Attempted to free unaligned physical range");
    }

    for (0..count) |i| {
        freePage(paddr + @as(u64, @intCast(i)) * PAGE_SIZE);
    }
}

pub fn isPageAllocated(paddr: u64) bool {
    const frame: usize = @intCast(paddr / PAGE_SIZE);
    if (frame >= total_pages) return true;
    return isBitSet(frame);
}

pub fn testPmm() bool {
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

    return true;
}
