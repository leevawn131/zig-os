// CPU Exception & Interrupt Handlers
const std = @import("std");
const cpu = @import("../cpu.zig");
const serial = @import("../../../drivers/serial/serial.zig");
const page_fault = @import("../interrupts/page_fault.zig");

pub const PageFaultCause = page_fault.PageFaultCause;

pub const InterruptFrame = extern struct {
    // General Purpose Registers pushed by isr_common
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Pushed by specific ISR vector stub
    vector: u64,
    error_code: u64,

    // Hardware-pushed stack frame by x86_64 CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const EXCEPTION_MESSAGES = [_][]const u8{
    "#DE: Divide-by-Zero Error",
    "#DB: Debug Exception",
    "#NMI: Non-Maskable Interrupt",
    "#BP: Breakpoint Exception",
    "#OF: Overflow",
    "#BR: Bound Range Exceeded",
    "#UD: Invalid Opcode",
    "#NM: Device Not Available (No Math Coprocessor)",
    "#DF: Double Fault",
    "Coprocessor Segment Overrun",
    "#TS: Invalid TSS",
    "#NP: Segment Not Present",
    "#SS: Stack-Segment Fault",
    "#GP: General Protection Fault",
    "#PF: Page Fault",
    "Reserved",
    "#MF: x87 FPU Floating-Point Error",
    "#AC: Alignment Check",
    "#MC: Machine Check",
    "#XM/#XF: SIMD Floating-Point Exception",
    "#VE: Virtualization Exception",
    "#CP: Control Protection Exception",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "#HV: Hypervisor Injection Exception",
    "#VC: VMM Communication Exception",
    "#SX: Security Exception",
    "Reserved",
};

// Test control hooks for controlled, non-fatal exception verification
pub var test_expected_vector: ?u64 = null;
pub var test_occurred: bool = false;
pub var test_fault_cr2: u64 = 0;
pub var test_skip_instruction_len: u64 = 0;

pub export fn x86_64_interrupt_dispatch(frame: *InterruptFrame) callconv(.c) void {
    // Check if this exception was triggered as part of a controlled test
    if (test_expected_vector) |expected| {
        if (frame.vector == expected) {
            test_occurred = true;
            if (frame.vector == 14) {
                test_fault_cr2 = cpu.readCr2();
            }
            // Skip the faulting instruction if requested by the test harness
            frame.rip += test_skip_instruction_len;
            return;
        }
    }

    // Unhandled or unexpected exception -> Log full diagnostic report
    logException(frame);

    // Halt system safely on unrecoverable CPU exceptions
    cpu.haltLoop();
}

pub fn logException(frame: *const InterruptFrame) void {
    serial.writeString("\n\n====================================================\n");
    serial.writeString("           CPU EXCEPTION DETECTED!                  \n");
    serial.writeString("====================================================\n");

    const vec_name = if (frame.vector < EXCEPTION_MESSAGES.len)
        EXCEPTION_MESSAGES[frame.vector]
    else
        "Hardware Interrupt";

    serial.writeString("[EXCEPTION] Vector: ");
    serial.writeDec(frame.vector);
    serial.writeString(" (");
    serial.writeString(vec_name);
    serial.writeString(")\n");

    serial.writeString("[EXCEPTION] Error Code: ");
    serial.writeHex(frame.error_code);
    serial.writeString("\n");

    if (frame.vector == 14) {
        const cr2 = cpu.readCr2();
        serial.writeString("[PAGE FAULT] Faulting Linear Address (CR2): ");
        serial.writeHex(cr2);
        serial.writeString("\n[PAGE FAULT] Cause: ");

        const cause = PageFaultCause.decode(frame.error_code);

        if (cause.protection_violation) serial.writeString("[protection violation] ") else serial.writeString("[non-present page] ");
        if (cause.write) serial.writeString("[write access] ") else serial.writeString("[read access] ");
        if (cause.user_mode) serial.writeString("[user mode] ") else serial.writeString("[kernel mode] ");
        if (cause.reserved_bit) serial.writeString("[reserved bit violation] ");
        if (cause.instruction_fetch) serial.writeString("[instruction fetch (NX)] ");
        serial.writeString("\n");
    }

    serial.writeString("\n--- CPU Register State ---\n");
    serial.writeString("RIP: ");
    serial.writeHex(frame.rip);
    serial.writeString("  CS:     ");
    serial.writeHex(frame.cs);
    serial.writeString("  RFLAGS: ");
    serial.writeHex(frame.rflags);
    serial.writeString("\n");

    serial.writeString("RSP: ");
    serial.writeHex(frame.rsp);
    serial.writeString("  SS:     ");
    serial.writeHex(frame.ss);
    serial.writeString("\n");

    serial.writeString("RAX: ");
    serial.writeHex(frame.rax);
    serial.writeString("  RBX:    ");
    serial.writeHex(frame.rbx);
    serial.writeString("  RCX:    ");
    serial.writeHex(frame.rcx);
    serial.writeString("\n");

    serial.writeString("RDX: ");
    serial.writeHex(frame.rdx);
    serial.writeString("  RSI:    ");
    serial.writeHex(frame.rsi);
    serial.writeString("  RDI:    ");
    serial.writeHex(frame.rdi);
    serial.writeString("\n");

    serial.writeString("RBP: ");
    serial.writeHex(frame.rbp);
    serial.writeString("  R8:     ");
    serial.writeHex(frame.r8);
    serial.writeString("  R9:     ");
    serial.writeHex(frame.r9);
    serial.writeString("\n");

    serial.writeString("R10: ");
    serial.writeHex(frame.r10);
    serial.writeString("  R11:    ");
    serial.writeHex(frame.r11);
    serial.writeString("  R12:    ");
    serial.writeHex(frame.r12);
    serial.writeString("\n");

    serial.writeString("R13: ");
    serial.writeHex(frame.r13);
    serial.writeString("  R14:    ");
    serial.writeHex(frame.r14);
    serial.writeString("  R15:    ");
    serial.writeHex(frame.r15);
    serial.writeString("\n");
    serial.writeString("====================================================\n");
}
