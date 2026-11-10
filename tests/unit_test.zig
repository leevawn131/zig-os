// Host-side Unit Tests for ZIG-OS Core Algorithms & Mathematics
const std = @import("std");
const testing = std.testing;

// 1. Virtual memory address bitfield decomposition tests
inline fn pml4Index(virt: u64) usize {
    return @intCast((virt >> 39) & 0x1FF);
}
inline fn pdptIndex(virt: u64) usize {
    return @intCast((virt >> 30) & 0x1FF);
}
inline fn pdIndex(virt: u64) usize {
    return @intCast((virt >> 21) & 0x1FF);
}
inline fn ptIndex(virt: u64) usize {
    return @intCast((virt >> 12) & 0x1FF);
}
inline fn pageOffset(virt: u64) usize {
    return @intCast(virt & 0xFFF);
}

test "VMM address decomposition for higher-half kernel base" {
    // 0xffffffff80000000 (-2 GiB kernel base)
    const kernel_base: u64 = 0xffffffff80000000;
    try testing.expectEqual(@as(usize, 511), pml4Index(kernel_base));
    try testing.expectEqual(@as(usize, 510), pdptIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), pdIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), ptIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), pageOffset(kernel_base));
}

test "VMM address decomposition for arbitrary virtual addresses" {
    const addr: u64 = 0x0000_7fff_ffff_f123;
    try testing.expectEqual(@as(usize, 255), pml4Index(addr));
    try testing.expectEqual(@as(usize, 511), pdptIndex(addr));
    try testing.expectEqual(@as(usize, 511), pdIndex(addr));
    try testing.expectEqual(@as(usize, 511), ptIndex(addr));
    try testing.expectEqual(@as(usize, 0x123), pageOffset(addr));
}

// 2. Physical Memory Manager frame math tests
test "PMM frame indexing and bitmap size calculations" {
    const PAGE_SIZE: u64 = 4096;
    const test_ram_bytes: u64 = 1024 * 1024 * 1024; // 1 GiB RAM
    const total_pages = (test_ram_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    try testing.expectEqual(@as(u64, 262144), total_pages);
    const bitmap_size_bytes = (total_pages + 7) / 8;
    try testing.expectEqual(@as(u64, 32768), bitmap_size_bytes);

    // Frame index mapping
    const paddr: u64 = 0x0020_0000; // 2 MiB
    const frame: usize = @intCast(paddr / PAGE_SIZE);
    try testing.expectEqual(@as(usize, 512), frame);

    const byte_idx = frame / 8;
    const bit_idx: u3 = @truncate(frame % 8);
    try testing.expectEqual(@as(usize, 64), byte_idx);
    try testing.expectEqual(@as(u3, 0), bit_idx);
}

// 3. Page fault error code bit decoding tests
const PageFaultCause = struct {
    protection_violation: bool,
    write: bool,
    user_mode: bool,
    reserved_bit: bool,
    instruction_fetch: bool,

    fn decode(error_code: u64) PageFaultCause {
        return .{
            .protection_violation = (error_code & (1 << 0)) != 0,
            .write = (error_code & (1 << 1)) != 0,
            .user_mode = (error_code & (1 << 2)) != 0,
            .reserved_bit = (error_code & (1 << 3)) != 0,
            .instruction_fetch = (error_code & (1 << 4)) != 0,
        };
    }
};

test "Page Fault error code bit decoding" {
    // Read of non-present page in kernel mode: error code 0
    const cause0 = PageFaultCause.decode(0);
    try testing.expect(!cause0.protection_violation);
    try testing.expect(!cause0.write);
    try testing.expect(!cause0.user_mode);

    // Write to non-present page in kernel mode: error code 2
    const cause2 = PageFaultCause.decode(2);
    try testing.expect(!cause2.protection_violation);
    try testing.expect(cause2.write);
    try testing.expect(!cause2.user_mode);

    // Protection violation on write in user mode: error code 7 (1 | 2 | 4)
    const cause7 = PageFaultCause.decode(7);
    try testing.expect(cause7.protection_violation);
    try testing.expect(cause7.write);
    try testing.expect(cause7.user_mode);

    // Instruction fetch on NX page: error code 16
    const cause16 = PageFaultCause.decode(16);
    try testing.expect(cause16.instruction_fetch);
}

// 4. Heap header size and 16-byte alignment math
test "Heap block header alignment" {
    const BlockHeader = extern struct {
        magic: u32,
        canary: u32,
        size: usize,
        is_free: bool,
        padding: [7]u8,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    };
    try testing.expectEqual(@as(usize, 40), @sizeOf(BlockHeader));
    // Header size rounded to 16 bytes
    const aligned_hdr = (@sizeOf(BlockHeader) + 15) & ~@as(usize, 15);
    try testing.expectEqual(@as(usize, 48), aligned_hdr);
}
