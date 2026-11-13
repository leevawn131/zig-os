// x86_64 Interrupt Vector Policy and Descriptor Validation
// Hardware-independent policy module shared between kernel subsystems and host tests.

/// Total number of entries in an x86_64 Interrupt Descriptor Table (IDT).
pub const IDT_ENTRY_COUNT: usize = 256;

/// Number of CPU architectural exception vectors (vectors 0 through 31).
pub const EXCEPTION_VECTOR_COUNT: usize = 32;

/// First interrupt vector available for external hardware IRQs, APIC/IOAPIC, MSI, or non-exception software use.
pub const FIRST_EXTERNAL_VECTOR: u8 = 32;

/// Controlled software breakpoint vector (`int $3`, #BP) permitted in kernel self-tests.
pub const CONTROLLED_BREAKPOINT_VECTOR: u8 = 3;

/// Remapped vector base for the master 8259 PIC (IRQ 0..7 -> vectors 0x20..0x27).
pub const LEGACY_PIC_MASTER_OFFSET: u8 = 0x20;

/// Remapped vector base for the slave 8259 PIC (IRQ 8..15 -> vectors 0x28..0x2F).
pub const LEGACY_PIC_SLAVE_OFFSET: u8 = 0x28;

/// Number of IRQ lines serviced by each 8259 PIC controller.
pub const PIC_IRQ_LINE_COUNT: u8 = 8;

/// IDT Type field for a 64-bit Interrupt Gate (clears RFLAGS.IF on entry).
pub const IDT_GATE_TYPE_INTERRUPT_64: u8 = 0x0E;

/// IDT Present bit in the type/attributes byte.
pub const IDT_GATE_PRESENT: u8 = 0x80;

/// IDT Descriptor Privilege Level 0 (kernel-only software INT access).
pub const IDT_GATE_DPL_RING0: u8 = 0x00;

/// Bitmask covering the DPL field (bits 6:5) in the IDT type/attributes byte.
pub const IDT_GATE_DPL_MASK: u8 = 0x60;

/// Standard kernel-only 64-bit Interrupt Gate flags: Present (0x80) | DPL 0 (0x00) | Interrupt Gate (0x0E).
pub const IDT_GATE_FLAGS_KERNEL_INTERRUPT: u8 =
    IDT_GATE_PRESENT | IDT_GATE_DPL_RING0 | IDT_GATE_TYPE_INTERRUPT_64;

/// Exact set of x86_64 architectural exception vectors that push a hardware error code.
pub const ERROR_CODE_VECTORS = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };

pub const VectorError = error{
    ReservedExceptionVector,
};

/// Returns true iff the x86_64 CPU pushes a hardware error code onto the stack for `vector`.
pub fn pushesHardwareErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Returns true iff `vector` lies in the CPU architectural exception range (0..31).
pub fn isExceptionVector(vector: u8) bool {
    return vector < FIRST_EXTERNAL_VECTOR;
}

/// Returns true iff `vector` may be assigned to external interrupts (PIC, LAPIC, IOAPIC, MSI/MSI-X, IPIs).
pub fn isExternalVectorAllowed(vector: u8) bool {
    return vector >= FIRST_EXTERNAL_VECTOR;
}

/// Validates that `vector` does not collide with reserved CPU exception vectors (0..31).
pub fn validateExternalVector(vector: u8) VectorError!u8 {
    if (!isExternalVectorAllowed(vector)) {
        return error.ReservedExceptionVector;
    }
    return vector;
}

/// Returns true iff kernel source must allow a software `INT n` targeting `vector`.
/// Only controlled `#BP` (vector 3) for IDT self-tests and vectors >= 32 are permitted.
pub fn isAllowedKernelSoftwareIntVector(vector: u8) bool {
    return vector == CONTROLLED_BREAKPOINT_VECTOR or vector >= FIRST_EXTERNAL_VECTOR;
}

/// Returns true iff issuing software `INT n` for `vector` is forbidden in kernel source.
/// Rejects all hardware-error-code exception vectors and all non-breakpoint reserved exception vectors.
pub fn isForbiddenSoftwareIntVector(vector: u8) bool {
    return !isAllowedKernelSoftwareIntVector(vector);
}

/// Validates legacy 8259 PIC vector base offsets:
/// - Both master and slave bases must be 8-vector aligned.
/// - Both ranges [base, base + 8) must reside in external vector space (>= 32, <= 255).
/// - Master and slave 8-vector ranges must not overlap.
pub fn isPicOffsetValid(master_offset: u8, slave_offset: u8) bool {
    if ((master_offset & 0x07) != 0 or (slave_offset & 0x07) != 0) {
        return false;
    }
    if (master_offset < FIRST_EXTERNAL_VECTOR or slave_offset < FIRST_EXTERNAL_VECTOR) {
        return false;
    }

    const m_start: u16 = master_offset;
    const m_end: u16 = m_start + PIC_IRQ_LINE_COUNT;
    const s_start: u16 = slave_offset;
    const s_end: u16 = s_start + PIC_IRQ_LINE_COUNT;

    if (m_end > IDT_ENTRY_COUNT or s_end > IDT_ENTRY_COUNT) {
        return false;
    }

    // Disjoint 8-vector ranges.
    return m_end <= s_start or s_end <= m_start;
}

/// Pure architectural validation for a kernel-only 64-bit IDT interrupt gate descriptor.
pub fn isValidKernelInterruptGate(
    type_attr: u8,
    ist: u8,
    reserved: u32,
    actual_selector: u16,
    expected_selector: u16,
    actual_offset: u64,
    expected_offset: u64,
) bool {
    if (type_attr != IDT_GATE_FLAGS_KERNEL_INTERRUPT) return false;
    if ((ist & 0xF8) != 0) return false;
    if (reserved != 0) return false;
    if (actual_selector != expected_selector) return false;
    if (actual_offset != expected_offset) return false;
    return true;
}
