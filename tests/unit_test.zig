// Host-side Unit Tests for ZIG-OS Core Algorithms & Mathematics
const std = @import("std");
const testing = std.testing;

// Import shared production modules
const paging_math = @import("paging_math");
const physical_math = @import("physical_math");
const page_fault = @import("page_fault");
const heap_layout = @import("heap_layout");
const sse = @import("sse");

// 1. Virtual memory address bitfield decomposition tests
test "VMM address decomposition for higher-half kernel base" {
    const kernel_base: u64 = 0xffff_ffff_8000_0000;
    try testing.expectEqual(@as(usize, 511), paging_math.pml4Index(kernel_base));
    try testing.expectEqual(@as(usize, 510), paging_math.pdptIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), paging_math.pdIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), paging_math.ptIndex(kernel_base));
    try testing.expectEqual(@as(usize, 0), paging_math.pageOffset(kernel_base));
}

test "VMM address decomposition for arbitrary virtual addresses" {
    const addr: u64 = 0x0000_7fff_ffff_f123;
    try testing.expectEqual(@as(usize, 255), paging_math.pml4Index(addr));
    try testing.expectEqual(@as(usize, 511), paging_math.pdptIndex(addr));
    try testing.expectEqual(@as(usize, 511), paging_math.pdIndex(addr));
    try testing.expectEqual(@as(usize, 511), paging_math.ptIndex(addr));
    try testing.expectEqual(@as(usize, 0x123), paging_math.pageOffset(addr));
}

test "VMM address decomposition boundary and edge cases" {
    // Lower bound: address 0
    try testing.expectEqual(@as(usize, 0), paging_math.pml4Index(0));
    try testing.expectEqual(@as(usize, 0), paging_math.pdptIndex(0));
    try testing.expectEqual(@as(usize, 0), paging_math.pdIndex(0));
    try testing.expectEqual(@as(usize, 0), paging_math.ptIndex(0));
    try testing.expectEqual(@as(usize, 0), paging_math.pageOffset(0));

    // Canonical user ceiling: 0x0000_7fff_ffff_f000
    const user_ceil: u64 = 0x0000_7fff_ffff_f000;
    try testing.expectEqual(@as(usize, 255), paging_math.pml4Index(user_ceil));
    try testing.expectEqual(@as(usize, 511), paging_math.pdptIndex(user_ceil));
    try testing.expectEqual(@as(usize, 511), paging_math.pdIndex(user_ceil));
    try testing.expectEqual(@as(usize, 511), paging_math.ptIndex(user_ceil));
    try testing.expectEqual(@as(usize, 0), paging_math.pageOffset(user_ceil));

    // HHDM canonical base: 0xffff_8000_0000_0000
    const hhdm_base: u64 = 0xffff_8000_0000_0000;
    try testing.expectEqual(@as(usize, 256), paging_math.pml4Index(hhdm_base));
    try testing.expectEqual(@as(usize, 0), paging_math.pdptIndex(hhdm_base));
    try testing.expectEqual(@as(usize, 0), paging_math.pdIndex(hhdm_base));
    try testing.expectEqual(@as(usize, 0), paging_math.ptIndex(hhdm_base));
    try testing.expectEqual(@as(usize, 0), paging_math.pageOffset(hhdm_base));

    // Highest 64-bit address: 0xffff_ffff_ffff_ffff
    const max_addr: u64 = 0xffff_ffff_ffff_ffff;
    try testing.expectEqual(@as(usize, 511), paging_math.pml4Index(max_addr));
    try testing.expectEqual(@as(usize, 511), paging_math.pdptIndex(max_addr));
    try testing.expectEqual(@as(usize, 511), paging_math.pdIndex(max_addr));
    try testing.expectEqual(@as(usize, 511), paging_math.ptIndex(max_addr));
    try testing.expectEqual(@as(usize, 4095), paging_math.pageOffset(max_addr));
}

// 2. Physical Memory Manager frame math tests
test "PMM frame indexing and bitmap size calculations" {
    const test_ram_bytes: u64 = 1024 * 1024 * 1024; // 1 GiB RAM
    const total_pages = physical_math.totalPagesFromBytes(test_ram_bytes);
    try testing.expectEqual(@as(usize, 262144), total_pages);

    const bitmap_size = physical_math.bitmapSizeBytes(total_pages);
    try testing.expectEqual(@as(usize, 32768), bitmap_size);

    // Frame index mapping
    const paddr: u64 = 0x0020_0000; // 2 MiB
    const frame = physical_math.physToFrame(paddr);
    try testing.expectEqual(@as(usize, 512), frame);

    const byte_idx = physical_math.frameToByteIndex(frame);
    const bit_idx = physical_math.frameToBitIndex(frame);
    try testing.expectEqual(@as(usize, 64), byte_idx);
    try testing.expectEqual(@as(u3, 0), bit_idx);
}

test "PMM frame math boundary and edge cases" {
    // 0 bytes
    try testing.expectEqual(@as(usize, 0), physical_math.totalPagesFromBytes(0));
    try testing.expectEqual(@as(usize, 0), physical_math.bitmapSizeBytes(0));

    // 1 byte -> 1 page, 1 bitmap byte
    try testing.expectEqual(@as(usize, 1), physical_math.totalPagesFromBytes(1));
    try testing.expectEqual(@as(usize, 1), physical_math.bitmapSizeBytes(1));

    // 4096 bytes -> 1 page, 1 bitmap byte
    try testing.expectEqual(@as(usize, 1), physical_math.totalPagesFromBytes(4096));
    try testing.expectEqual(@as(usize, 1), physical_math.bitmapSizeBytes(1));

    // 4097 bytes -> 2 pages, 1 bitmap byte
    try testing.expectEqual(@as(usize, 2), physical_math.totalPagesFromBytes(4097));
    try testing.expectEqual(@as(usize, 1), physical_math.bitmapSizeBytes(2));

    // 8 pages -> 8 frames, 1 bitmap byte
    try testing.expectEqual(@as(usize, 8), physical_math.totalPagesFromBytes(8 * physical_math.PAGE_SIZE));
    try testing.expectEqual(@as(usize, 1), physical_math.bitmapSizeBytes(8));

    // 9 pages -> 9 frames, 2 bitmap bytes
    try testing.expectEqual(@as(usize, 9), physical_math.totalPagesFromBytes(9 * physical_math.PAGE_SIZE));
    try testing.expectEqual(@as(usize, 2), physical_math.bitmapSizeBytes(9));

    // Address to frame mapping
    try testing.expectEqual(@as(usize, 0), physical_math.physToFrame(0));
    try testing.expectEqual(@as(usize, 0), physical_math.physToFrame(4095));
    try testing.expectEqual(@as(usize, 1), physical_math.physToFrame(4096));
    try testing.expectEqual(@as(usize, 512), physical_math.physToFrame(0x0020_0000));

    // Bit and byte mapping across byte boundaries
    try testing.expectEqual(@as(usize, 0), physical_math.frameToByteIndex(0));
    try testing.expectEqual(@as(u3, 0), physical_math.frameToBitIndex(0));

    try testing.expectEqual(@as(usize, 0), physical_math.frameToByteIndex(7));
    try testing.expectEqual(@as(u3, 7), physical_math.frameToBitIndex(7));

    try testing.expectEqual(@as(usize, 1), physical_math.frameToByteIndex(8));
    try testing.expectEqual(@as(u3, 0), physical_math.frameToBitIndex(8));

    try testing.expectEqual(@as(usize, 1), physical_math.frameToByteIndex(9));
    try testing.expectEqual(@as(u3, 1), physical_math.frameToBitIndex(9));

    try testing.expectEqual(@as(usize, 64), physical_math.frameToByteIndex(512));
    try testing.expectEqual(@as(u3, 0), physical_math.frameToBitIndex(512));

    try testing.expectEqual(@as(usize, 127), physical_math.frameToByteIndex(1023));
    try testing.expectEqual(@as(u3, 7), physical_math.frameToBitIndex(1023));

    try testing.expectEqual(@as(usize, 128), physical_math.frameToByteIndex(1024));
    try testing.expectEqual(@as(u3, 0), physical_math.frameToBitIndex(1024));
}

// 3. Page fault error code bit decoding tests
test "Page Fault error code bit decoding" {
    // Read of non-present page in kernel mode: error code 0
    const cause0 = page_fault.PageFaultCause.decode(0);
    try testing.expect(!cause0.protection_violation);
    try testing.expect(!cause0.write);
    try testing.expect(!cause0.user_mode);
    try testing.expect(!cause0.reserved_bit);
    try testing.expect(!cause0.instruction_fetch);

    // Read of protected page in kernel mode: error code 1
    const cause1 = page_fault.PageFaultCause.decode(1);
    try testing.expect(cause1.protection_violation);
    try testing.expect(!cause1.write);
    try testing.expect(!cause1.user_mode);
    try testing.expect(!cause1.reserved_bit);
    try testing.expect(!cause1.instruction_fetch);

    // Write to non-present page in kernel mode: error code 2
    const cause2 = page_fault.PageFaultCause.decode(2);
    try testing.expect(!cause2.protection_violation);
    try testing.expect(cause2.write);
    try testing.expect(!cause2.user_mode);
    try testing.expect(!cause2.reserved_bit);
    try testing.expect(!cause2.instruction_fetch);

    // Write to protected page in kernel mode: error code 3
    const cause3 = page_fault.PageFaultCause.decode(3);
    try testing.expect(cause3.protection_violation);
    try testing.expect(cause3.write);
    try testing.expect(!cause3.user_mode);
    try testing.expect(!cause3.reserved_bit);
    try testing.expect(!cause3.instruction_fetch);

    // User read of non-present page: error code 4
    const cause4 = page_fault.PageFaultCause.decode(4);
    try testing.expect(!cause4.protection_violation);
    try testing.expect(!cause4.write);
    try testing.expect(cause4.user_mode);
    try testing.expect(!cause4.reserved_bit);
    try testing.expect(!cause4.instruction_fetch);

    // Protection violation on write in user mode: error code 7 (1 | 2 | 4)
    const cause7 = page_fault.PageFaultCause.decode(7);
    try testing.expect(cause7.protection_violation);
    try testing.expect(cause7.write);
    try testing.expect(cause7.user_mode);
    try testing.expect(!cause7.reserved_bit);
    try testing.expect(!cause7.instruction_fetch);

    // Reserved bit violation: error code 8
    const cause8 = page_fault.PageFaultCause.decode(8);
    try testing.expect(!cause8.protection_violation);
    try testing.expect(!cause8.write);
    try testing.expect(!cause8.user_mode);
    try testing.expect(cause8.reserved_bit);
    try testing.expect(!cause8.instruction_fetch);

    // Instruction fetch on NX page: error code 16
    const cause16 = page_fault.PageFaultCause.decode(16);
    try testing.expect(!cause16.protection_violation);
    try testing.expect(!cause16.write);
    try testing.expect(!cause16.user_mode);
    try testing.expect(!cause16.reserved_bit);
    try testing.expect(cause16.instruction_fetch);

    // Combined flags (1 | 2 | 4 | 16 = 23)
    const cause_comb = page_fault.PageFaultCause.decode(1 | 2 | 4 | 16);
    try testing.expect(cause_comb.protection_violation);
    try testing.expect(cause_comb.write);
    try testing.expect(cause_comb.user_mode);
    try testing.expect(!cause_comb.reserved_bit);
    try testing.expect(cause_comb.instruction_fetch);
}

// 4. Heap header size, alignment and layout tests
test "Heap block header layout and alignment" {
    // Assert exact memory layout properties of shared production BlockHeader
    try testing.expectEqual(@as(usize, 40), @sizeOf(heap_layout.BlockHeader));
    try testing.expectEqual(@as(usize, 8), @alignOf(heap_layout.BlockHeader));
    try testing.expectEqual(@as(usize, 40), heap_layout.HEADER_SIZE);

    // Header size rounded up to 16 bytes for 16-byte payload alignment
    const aligned_hdr = (heap_layout.HEADER_SIZE + 15) & ~@as(usize, 15);
    try testing.expectEqual(@as(usize, 48), aligned_hdr);
}

// 5. SSE control register (CR0 / CR4) initialization helper tests (F-15)
test "CR0 SSE initialization clears EM and TS, sets MP, and preserves unrelated bits" {
    const cr0_pe: u64 = 1 << 0;
    const cr0_ne: u64 = 1 << 5;
    const cr0_wp: u64 = 1 << 16;
    const cr0_pg: u64 = 1 << 31;
    const base_arch_bits: u64 = cr0_pe | cr0_ne | cr0_wp | cr0_pg;
    const unrelated_mask: u64 = ~(sse.CR0_MP_BIT | sse.CR0_EM_BIT | sse.CR0_TS_BIT);

    // Case 1: Both EM and TS initially set (MP initially clear)
    const initial_both = base_arch_bits | sse.CR0_EM_BIT | sse.CR0_TS_BIT;
    const out_both = sse.computeSseCr0(initial_both);
    try testing.expectEqual(base_arch_bits | sse.CR0_MP_BIT, out_both);
    try testing.expect(sse.isSseCr0Valid(out_both));

    // Case 2: EM set, TS clear
    const initial_em = base_arch_bits | sse.CR0_EM_BIT;
    const out_em = sse.computeSseCr0(initial_em);
    try testing.expectEqual(base_arch_bits | sse.CR0_MP_BIT, out_em);
    try testing.expect(sse.isSseCr0Valid(out_em));

    // Case 3: EM clear, TS set (typical Limine / task-switch residual state)
    const initial_ts = base_arch_bits | sse.CR0_TS_BIT;
    const out_ts = sse.computeSseCr0(initial_ts);
    try testing.expectEqual(base_arch_bits | sse.CR0_MP_BIT, out_ts);
    try testing.expect(sse.isSseCr0Valid(out_ts));

    // Case 4: Both EM and TS clear (with MP=0 and with MP=1)
    const out_clear_no_mp = sse.computeSseCr0(base_arch_bits);
    try testing.expectEqual(base_arch_bits | sse.CR0_MP_BIT, out_clear_no_mp);
    try testing.expect(sse.isSseCr0Valid(out_clear_no_mp));

    const out_clear_with_mp = sse.computeSseCr0(base_arch_bits | sse.CR0_MP_BIT);
    try testing.expectEqual(base_arch_bits | sse.CR0_MP_BIT, out_clear_with_mp);
    try testing.expect(sse.isSseCr0Valid(out_clear_with_mp));

    // Case 5: Preservation of unrelated bits across extreme bit patterns
    try testing.expectEqual(sse.CR0_MP_BIT, sse.computeSseCr0(0));
    const all_bits = std.math.maxInt(u64);
    const expected_max = (all_bits & ~(sse.CR0_EM_BIT | sse.CR0_TS_BIT));
    const out_max = sse.computeSseCr0(all_bits);
    try testing.expectEqual(expected_max, out_max);
    try testing.expectEqual(all_bits & unrelated_mask, out_max & unrelated_mask);
    try testing.expect(sse.isSseCr0Valid(out_max));

    // Case 6: MP is always set and validator rejects any invalid CR0 combination
    try testing.expect((sse.computeSseCr0(0) & sse.CR0_MP_BIT) != 0);
    try testing.expect(!sse.isSseCr0Valid(base_arch_bits)); // MP=0
    try testing.expect(!sse.isSseCr0Valid(base_arch_bits | sse.CR0_MP_BIT | sse.CR0_EM_BIT)); // EM=1
    try testing.expect(!sse.isSseCr0Valid(base_arch_bits | sse.CR0_MP_BIT | sse.CR0_TS_BIT)); // TS=1
    try testing.expect(!sse.isSseCr0Valid(base_arch_bits | sse.CR0_MP_BIT | sse.CR0_EM_BIT | sse.CR0_TS_BIT));
}

test "CR4 SSE initialization sets OSFXSR and OSXMMEXCPT and preserves unrelated bits" {
    const cr4_pae: u64 = 1 << 5;
    const cr4_pge: u64 = 1 << 7;
    const base_cr4 = cr4_pae | cr4_pge;

    const out_cr4 = sse.computeSseCr4(base_cr4);
    try testing.expectEqual(base_cr4 | sse.CR4_OSFXSR_BIT | sse.CR4_OSXMMEXCPT_BIT, out_cr4);
    try testing.expect(sse.isSseCr4Valid(out_cr4));
    try testing.expect(!sse.isSseCr4Valid(base_cr4));
    try testing.expect(!sse.isSseCr4Valid(base_cr4 | sse.CR4_OSFXSR_BIT));
    try testing.expect(!sse.isSseCr4Valid(base_cr4 | sse.CR4_OSXMMEXCPT_BIT));
}
