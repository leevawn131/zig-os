// Hardware-Independent x86_64 GDT, 64-bit TSS, and Descriptor Encoding Model
// Shared between freestanding BSP initialization (`gdt.zig`) and host unit tests (`zig build test`).
// Must contain zero privileged inline assembly instructions (`lgdt`, `sgdt`, `ltr`, `str`).

/// Architectural 10-byte (80-bit) GDTR pseudo-descriptor operand for `lgdt` and `sgdt`.
/// Distinct from the 16-byte 64-bit TSS System Descriptor inside the GDT.
pub const GdtDescriptor = extern struct {
    limit: u16,
    base: u64 align(1),
};

/// Architectural 104-byte 64-bit Task State Segment (Intel SDM Vol. 3A Fig. 8-11).
pub const Tss64 = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss64),
};

/// Architectural 16-byte (128-bit) 64-bit TSS System Descriptor occupying GDT indices 9 and 10 (0x48..0x57).
/// Distinct from the 10-byte GDTR memory operand (`GdtDescriptor`).
pub const TssDescriptor16 = extern struct {
    low: u64,
    high: u64,
};

comptime {
    if (@sizeOf(GdtDescriptor) != 10) @compileError("GDTR operand must be exactly 10 bytes");
    if (@offsetOf(GdtDescriptor, "limit") != 0) @compileError("GDTR.limit must be at offset 0");
    if (@offsetOf(GdtDescriptor, "base") != 2) @compileError("GDTR.base must be at offset 2");

    if (@sizeOf(Tss64) != 104) @compileError("Tss64 must be exactly 104 bytes");
    if (@offsetOf(Tss64, "rsp0") != 0x04) @compileError("Tss64.rsp0 must be at offset 0x04");
    if (@offsetOf(Tss64, "ist1") != 0x24) @compileError("Tss64.ist1 must be at offset 0x24");
    if (@offsetOf(Tss64, "ist2") != 0x2C) @compileError("Tss64.ist2 must be at offset 0x2C");
    if (@offsetOf(Tss64, "ist3") != 0x34) @compileError("Tss64.ist3 must be at offset 0x34");
    if (@offsetOf(Tss64, "iomap_base") != 0x66) @compileError("Tss64.iomap_base must be at offset 0x66");

    if (@sizeOf(TssDescriptor16) != 16) @compileError("TssDescriptor16 must be exactly 16 bytes");
}

pub const GDT_ENTRY_COUNT: usize = 11;
pub const GDT_LIMIT: u16 = (GDT_ENTRY_COUNT * @sizeOf(u64)) - 1; // 87 (0x57)

/// Fixed 16 KiB size for each dedicated BSP IST emergency stack.
pub const IST_STACK_SIZE: usize = 16384;

pub const KERNEL_CODE_SELECTOR: u16 = 0x28;
pub const KERNEL_DATA_SELECTOR: u16 = 0x30;
pub const TSS_SELECTOR: u16 = 0x48;

pub const KERNEL_CODE_INDEX: usize = KERNEL_CODE_SELECTOR >> 3; // 5
pub const KERNEL_DATA_INDEX: usize = KERNEL_DATA_SELECTOR >> 3; // 6
pub const TSS_DESCRIPTOR_INDEX: usize = TSS_SELECTOR >> 3; // 9 (occupies indices 9 and 10)

/// 64-bit Kernel Code Segment descriptor: P=1, DPL=0, S=1, Type=0xA (Exec/Read), L=1, D=0 -> Access 0x9A, Flags 0x2.
pub const KERNEL_CODE_DESCRIPTOR: u64 = 0x0020_9A00_0000_0000;

/// 64-bit Kernel Data Segment descriptor: P=1, DPL=0, S=1, Type=0x2 (Read/Write) -> Access 0x92, Flags 0x0.
pub const KERNEL_DATA_DESCRIPTOR: u64 = 0x0000_9200_0000_0000;

/// Hardware sets bit 40 (Accessed) in code/data descriptors when selectors are loaded (0x9A->0x9B, 0x92->0x93).
pub const DESCRIPTOR_ACCESSED_BIT: u64 = @as(u64, 1) << 40;

/// Hardware sets bit 41 (Busy) in the 64-bit TSS descriptor upon `ltr` (0x89->0x8B).
pub const TSS_BUSY_BIT: u64 = @as(u64, 1) << 41;

pub const TSS_ACCESS_AVAILABLE: u8 = 0x89;
pub const TSS_ACCESS_BUSY: u8 = 0x8B;

pub const TSS_MIN_LIMIT: u20 = @sizeOf(Tss64) - 1; // 103 (0x0067)

/// Returns the initial static Phase 1 GDT table prior to encoding the runtime TSS descriptor.
/// Indices 1..4 (0x08..0x20) and 7..8 (0x38..0x40) remain 0 (Not-Present).
pub fn makeInitialGdtTable() [GDT_ENTRY_COUNT]u64 {
    var table: [GDT_ENTRY_COUNT]u64 = @splat(0);
    table[KERNEL_CODE_INDEX] = KERNEL_CODE_DESCRIPTOR;
    table[KERNEL_DATA_INDEX] = KERNEL_DATA_DESCRIPTOR;
    return table;
}

/// Encodes a 16-byte 64-bit Available TSS System Descriptor (Access = 0x89, Flags = 0, upper reserved bits = 0).
pub fn encodeTssDescriptor(base: u64, limit: u20) TssDescriptor16 {
    const limit_low: u64 = limit & 0xFFFF;
    const limit_high: u64 = @as(u64, (limit >> 16) & 0x0F) << 48;

    const base_low: u64 = (base & 0xFFFF) << 16;
    const base_mid: u64 = ((base >> 16) & 0xFF) << 32;
    const base_high: u64 = ((base >> 24) & 0xFF) << 56;
    const base_upper32: u64 = (base >> 32) & 0xFFFF_FFFF;

    const access: u64 = @as(u64, TSS_ACCESS_AVAILABLE) << 40;

    return .{
        .low = limit_low | base_low | base_mid | access | limit_high | base_high,
        .high = base_upper32,
    };
}

/// Extracts the Access byte (bits 47:40) from the lower quadword of a GDT/TSS descriptor.
pub fn tssAccessByte(tss_low: u64) u8 {
    return @truncate((tss_low >> 40) & 0xFF);
}

fn isSegmentDescriptorValidPostLoad(entry: u64, expected_initial: u64, require_accessed: bool) bool {
    if ((entry & ~DESCRIPTOR_ACCESSED_BIT) != expected_initial) return false;
    return !require_accessed or (entry & DESCRIPTOR_ACCESSED_BIT) != 0;
}

/// Validates that a loaded kernel CS descriptor matches `KERNEL_CODE_DESCRIPTOR` (accepting
/// Accessed=1 `0x9B` on silicon/KVM and Accessed=0 `0x9A` under QEMU TCG `lretq`).
pub fn isCodeDescriptorValidPostLoad(entry: u64) bool {
    return isSegmentDescriptorValidPostLoad(entry, KERNEL_CODE_DESCRIPTOR, false);
}

/// Validates that a loaded kernel DS/SS descriptor matches `KERNEL_DATA_DESCRIPTOR` with hardware Accessed bit set (0x93).
pub fn isDataDescriptorValidPostLoad(entry: u64) bool {
    return isSegmentDescriptorValidPostLoad(entry, KERNEL_DATA_DESCRIPTOR, true);
}

/// Validates that a 16-byte TSS descriptor matches `(expected_base, expected_limit)` with hardware Busy bit set (0x8B).
pub fn isTssDescriptorBusyValid(
    low: u64,
    high: u64,
    expected_base: u64,
    expected_limit: u20,
) bool {
    const expected = encodeTssDescriptor(expected_base, expected_limit);
    return low == (expected.low | TSS_BUSY_BIT) and
        high == expected.high and
        tssAccessByte(low) == TSS_ACCESS_BUSY;
}

/// Overflow-safe verification that two half-open intervals `[a_base, a_top)` and `[b_base, b_top)`
/// are non-empty and pairwise disjoint. Fails closed if either range is invalid/empty (`base >= top`).
pub fn areRangesDisjoint(a_base: u64, a_top: u64, b_base: u64, b_top: u64) bool {
    if (a_base >= a_top or b_base >= b_top) return false;
    return a_top <= b_base or b_top <= a_base;
}
