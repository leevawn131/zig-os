// x86_64 Interrupt Vector Policy, IST Mapping, Overflow-Safe Stack Checks, and DF Test State Machine
// Hardware-independent policy module shared between kernel subsystems and host tests.
const std = @import("std");

/// Total number of entries in an x86_64 Interrupt Descriptor Table (IDT).
pub const IDT_ENTRY_COUNT: usize = 256;

/// Number of CPU architectural exception vectors (vectors 0 through 31).
pub const EXCEPTION_VECTOR_COUNT: usize = 32;

/// First interrupt vector available for external hardware IRQs, APIC/IOAPIC, MSI, or non-exception software use.
pub const FIRST_EXTERNAL_VECTOR: u8 = 32;

/// Architectural Non-Maskable Interrupt vector (#NMI, Vector 2).
pub const NMI_VECTOR: u8 = 2;

/// Controlled software breakpoint vector (`int $3`, #BP) permitted in kernel self-tests.
pub const BREAKPOINT_VECTOR: u8 = 3;
pub const CONTROLLED_BREAKPOINT_VECTOR: u8 = BREAKPOINT_VECTOR;

/// Architectural Invalid Opcode vector (#UD, Vector 6).
pub const INVALID_OPCODE_VECTOR: u8 = 6;

/// Architectural Double Fault abort vector (#DF, Vector 8).
pub const DOUBLE_FAULT_VECTOR: u8 = 8;

/// Architectural Page Fault vector (#PF, Vector 14).
pub const PAGE_FAULT_VECTOR: u8 = 14;

/// Architectural Machine Check exception vector (#MC, Vector 18).
pub const MACHINE_CHECK_VECTOR: u8 = 18;

/// Interrupt Stack Table (IST) indices configured in BSP IDT gates (1-based; 0 = legacy RSP switch).
pub const IST_NONE: u8 = 0;
pub const IST_DOUBLE_FAULT: u8 = 1;
pub const IST_NMI: u8 = 2;
pub const IST_MACHINE_CHECK: u8 = 3;

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

/// Returns the Phase 1 production IST slot (1..3) expected for `vector`, or `IST_NONE` (0).
pub fn expectedIstForVector(vector: u8) u8 {
    return switch (vector) {
        DOUBLE_FAULT_VECTOR => IST_DOUBLE_FAULT,
        NMI_VECTOR => IST_NMI,
        MACHINE_CHECK_VECTOR => IST_MACHINE_CHECK,
        else => IST_NONE,
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
    expected_ist: u8,
    reserved: u32,
    actual_selector: u16,
    expected_selector: u16,
    actual_offset: u64,
    expected_offset: u64,
) bool {
    if (type_attr != IDT_GATE_FLAGS_KERNEL_INTERRUPT) return false;
    if ((ist & 0xF8) != 0) return false;
    if ((expected_ist & 0xF8) != 0) return false;
    if (ist != expected_ist) return false;
    if (reserved != 0) return false;
    if (actual_selector != expected_selector) return false;
    if (actual_offset != expected_offset) return false;
    return true;
}

/// Overflow-safe verification that non-empty contiguous `[frame_addr, frame_addr + frame_size)`
/// lies strictly within half-open `[stack_base, stack_top)`.
/// Rejects invalid stack bounds (`stack_base > stack_top`) and empty frames (`frame_size == 0`,
/// including when `frame_addr == stack_top`). Performs zero wrapping address additions.
pub fn isFrameWithinStack(
    frame_addr: u64,
    frame_size: u64,
    stack_base: u64,
    stack_top: u64,
) bool {
    if (stack_base > stack_top or frame_size == 0) return false;
    if (frame_addr < stack_base) return false;
    if (frame_addr > stack_top) return false;
    const remaining: u64 = stack_top - frame_addr;
    return frame_size <= remaining;
}

/// Overflow-safe verification that non-empty contiguous `[frame_addr, frame_addr + frame_size)`
/// is a valid non-overflowing range with zero byte overlap against `[stack_base, stack_top)`.
/// Fails closed (returns `false`) if `stack_base > stack_top`, `frame_size == 0`, or
/// `frame_addr + frame_size` overflows `u64`.
pub fn isFrameDisjointFromStack(
    frame_addr: u64,
    frame_size: u64,
    stack_base: u64,
    stack_top: u64,
) bool {
    if (stack_base > stack_top or frame_size == 0) return false;

    const frame_end = std.math.add(
        u64,
        frame_addr,
        frame_size,
    ) catch return false;

    return frame_end <= stack_base or frame_addr >= stack_top;
}

/// Explicit 8-state lifecycle for the standalone Double Fault test harness.
pub const DfTestState = enum(u8) {
    inactive = 0,
    preparing = 1,
    armed = 2,
    handling_df = 3,
    passed_halting = 4,
    failed = 5,
    aborted_async = 6,
    nested_fault = 7,

    pub fn isTerminal(self: DfTestState) bool {
        return switch (self) {
            .passed_halting, .failed, .aborted_async, .nested_fault => true,
            .inactive, .preparing, .armed, .handling_df => false,
        };
    }
};

pub const DfDispatchAction = enum(u8) {
    normal_kernel_dispatch,
    verify_df_forensics,
    log_fail_and_halt,
    log_nested_fail_and_halt,
    log_inconclusive_and_halt,
    halt_silent,
};

pub fn isValidDfTransition(from: DfTestState, to: DfTestState) bool {
    return switch (from) {
        .inactive => to == .preparing,
        .preparing => to == .armed or to == .failed or to == .aborted_async,
        .armed => to == .handling_df or to == .failed or to == .aborted_async,
        .handling_df => to == .passed_halting or to == .failed or to == .aborted_async or to == .nested_fault,
        .passed_halting, .failed, .aborted_async, .nested_fault => false,
    };
}

/// Atomic compare-and-exchange (CAS) state machine governing standalone Double Fault testing.
/// Terminal states are strictly immutable once entered.
pub const DfStateMachine = struct {
    state: std.atomic.Value(DfTestState) = std.atomic.Value(DfTestState).init(.inactive),

    pub fn load(self: *const DfStateMachine) DfTestState {
        return self.state.load(.seq_cst);
    }

    /// Conditional atomic transition via strong CAS (.seq_cst).
    /// Returns true strictly if prior state equaled `expected` and was replaced with `next`.
    /// Never overwrites any terminal state.
    pub fn tryTransition(self: *DfStateMachine, expected: DfTestState, next: DfTestState) bool {
        if (expected.isTerminal() or !isValidDfTransition(expected, next)) return false;
        return self.state.cmpxchgStrong(expected, next, .seq_cst, .seq_cst) == null;
    }

    /// Dispatcher entry decision using conditional atomic CAS.
    /// Once in any terminal state, refuses state mutation and stops further exception processing.
    pub fn onException(self: *DfStateMachine, vector: u8) DfDispatchAction {
        const cur = self.load();
        const is_async = (vector == NMI_VECTOR or vector == MACHINE_CHECK_VECTOR);
        return switch (cur) {
            .inactive => .normal_kernel_dispatch,
            .passed_halting, .failed, .aborted_async, .nested_fault => .halt_silent,
            .preparing => if (is_async)
                (if (self.tryTransition(.preparing, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
            else
                (if (self.tryTransition(.preparing, .failed)) .log_fail_and_halt else .halt_silent),
            .armed => if (vector == DOUBLE_FAULT_VECTOR)
                (if (self.tryTransition(.armed, .handling_df)) .verify_df_forensics else .halt_silent)
            else if (is_async)
                (if (self.tryTransition(.armed, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
            else
                (if (self.tryTransition(.armed, .failed)) .log_fail_and_halt else .halt_silent),
            .handling_df => if (is_async)
                (if (self.tryTransition(.handling_df, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
            else
                (if (self.tryTransition(.handling_df, .nested_fault)) .log_nested_fail_and_halt else .halt_silent),
        };
    }

    /// Final PASS transition via atomic CAS (.handling_df -> .passed_halting).
    /// Caller MUST emit PASS strictly only when this returns true.
    pub fn completeDfPass(self: *DfStateMachine) bool {
        return self.tryTransition(.handling_df, .passed_halting);
    }

    /// Final FAIL transition when hardware forensics fail (.handling_df -> .failed).
    pub fn completeDfFail(self: *DfStateMachine) bool {
        return self.tryTransition(.handling_df, .failed);
    }
};

/// Pure hardware evidence captured during Vector 8 (#DF) verification.
pub const DfForensicEvidence = struct {
    vector: u64,
    error_code: u64,
    frame_addr: u64,
    frame_size: u64,
    ist1_base: u64,
    ist1_top: u64,
    cs: u64,
    ss: u64,
    expected_cs: u16,
    expected_ss: u16,
    frame_rsp: u64,
    cr2: u64,
    unmapped_rsp: u64,
};

/// Pure 6-factor hardware forensic validator for standalone #DF verification (`N-02`).
/// Uses overflow-safe frame containment checks and underflow-guarded RSP/CR2 windows.
pub fn validateDfForensics(ev: DfForensicEvidence) bool {
    if (ev.vector != DOUBLE_FAULT_VECTOR) return false;
    if (ev.error_code != 0) return false;
    if (!isFrameWithinStack(ev.frame_addr, ev.frame_size, ev.ist1_base, ev.ist1_top)) return false;
    if (ev.cs != ev.expected_cs or ev.ss != ev.expected_ss) return false;
    if (ev.unmapped_rsp < 0x30) return false;

    const lower: u64 = ev.unmapped_rsp - 0x30;
    if (ev.frame_rsp < lower or ev.frame_rsp > ev.unmapped_rsp) return false;
    if (ev.cr2 < lower or ev.cr2 >= ev.unmapped_rsp) return false;
    return true;
}
