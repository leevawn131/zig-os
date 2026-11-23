// CPU Exception & Interrupt Handlers
const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("../cpu.zig");
const gdt = @import("../gdt/gdt.zig");
const serial = @import("../../../drivers/serial/serial.zig");
const vectors = @import("../interrupts/vectors.zig");
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

// Dedicated canonical unmapped single-page window used exclusively by isolated `test-df`.
pub const DF_TEST_UNMAPPED_PAGE: u64 = 0x0000_0042_0001_0000;
pub const DF_TEST_UNMAPPED_RSP: u64 = DF_TEST_UNMAPPED_PAGE + 0x800;

// Test control hooks for controlled, non-fatal exception verification
pub var test_expected_vector: ?u64 = null;
pub var test_occurred: bool = false;
pub var test_fault_cr2: u64 = 0;
pub var test_skip_instruction_len: u64 = 0;
pub var test_observed_rip: u64 = 0;
pub var test_observed_rsp: u64 = 0;
pub var test_observed_cs: u64 = 0;
pub var test_observed_ss: u64 = 0;
pub var test_observed_frame_addr: u64 = 0;

pub var df_state: vectors.DfStateMachine = .{};

const DfTriggerExtern = if (build_options.test_double_fault) struct {
    extern const x86_64_trigger_df_ud2_sentinel: u8;
} else struct {};

pub fn resetTestHooks() void {
    test_expected_vector = null;
    test_occurred = false;
    test_fault_cr2 = 0;
    test_skip_instruction_len = 0;
    test_observed_rip = 0;
    test_observed_rsp = 0;
    test_observed_cs = 0;
    test_observed_ss = 0;
    test_observed_frame_addr = 0;
}

const SerialOut = struct {
    fn str(s: []const u8) bool {
        return serial.tryWriteStringBounded(s, serial.MAX_TX_POLL_SPINS);
    }

    fn hex(val: u64) bool {
        return serial.tryWriteHexBounded(val, serial.MAX_TX_POLL_SPINS);
    }

    fn dec(val: u64) bool {
        return serial.tryWriteDecBounded(val, serial.MAX_TX_POLL_SPINS);
    }

    fn labelHex(label: []const u8, val: u64) bool {
        return str(label) and hex(val);
    }
};

fn haltWithOptionalLog(frame: *const InterruptFrame, header: []const u8) noreturn {
    if (!serial.initialized) {
        cpu.haltLoop();
    }
    if (SerialOut.str(header)) {
        logException(frame);
    }
    cpu.haltLoop();
}

fn handleStandaloneDfDispatch(frame: *const InterruptFrame) void {
    if (comptime !build_options.test_double_fault) return;

    if (frame.vector > std.math.maxInt(u8)) {
        if (df_state.load() == .inactive) return;
        haltWithOptionalLog(frame, "[DF-TEST] FAIL: Exception with out-of-range vector number.\n");
    }

    const action = df_state.onException(@intCast(frame.vector));
    switch (action) {
        .normal_kernel_dispatch => return,
        .halt_silent => cpu.haltLoop(),
        .log_inconclusive_and_halt => haltWithOptionalLog(
            frame,
            "[DF-TEST] INCONCLUSIVE: Asynchronous hardware event interrupted Double Fault test.\n",
        ),
        .log_nested_fail_and_halt => {
            const msg = if (frame.vector == vectors.DOUBLE_FAULT_VECTOR)
                "[DF-TEST] FAIL: Nested #DF during #DF verification.\n"
            else
                "[DF-TEST] FAIL: Nested synchronous exception during #DF verification.\n";
            haltWithOptionalLog(frame, msg);
        },
        .log_fail_and_halt => {
            const msg = if (frame.vector == vectors.INVALID_OPCODE_VECTOR) blk: {
                if (frame.rip == @intFromPtr(&DfTriggerExtern.x86_64_trigger_df_ud2_sentinel)) {
                    break :blk "[DF-TEST] FAIL: push 0 did not fault (hit ud2 sentinel, Vector 6 #UD).\n";
                }
                break :blk "[DF-TEST] FAIL: Unexpected Vector 6 (#UD).\n";
            } else "[DF-TEST] FAIL: Unexpected synchronous exception instead of #DF escalation.\n";
            haltWithOptionalLog(frame, msg);
        },
        .verify_df_forensics => {
            const cr2 = cpu.readCr2();
            const ev: vectors.DfForensicEvidence = .{
                .vector = frame.vector,
                .error_code = frame.error_code,
                .frame_addr = @intFromPtr(frame),
                .frame_size = @sizeOf(InterruptFrame),
                .ist1_base = gdt.ist1Base(),
                .ist1_top = gdt.ist1Top(),
                .cs = frame.cs,
                .ss = frame.ss,
                .expected_cs = gdt.KERNEL_CODE_SELECTOR,
                .expected_ss = gdt.KERNEL_DATA_SELECTOR,
                .frame_rsp = frame.rsp,
                .cr2 = cr2,
                .unmapped_rsp = DF_TEST_UNMAPPED_RSP,
            };

            if (vectors.validateDfForensics(ev)) {
                // Two-phase CAS (`ITR-2`): transition `.handling_df -> .passed_halting` strictly BEFORE emitting PASS.
                if (!df_state.completeDfPass()) {
                    cpu.haltLoop();
                }
                if (serial.initialized) {
                    if (SerialOut.str("[DF-TEST] PASS: Double Fault caught on IST1 stack.\n") and
                        SerialOut.labelHex("[DF-TEST] Faulting Linear Address (CR2): ", cr2) and
                        SerialOut.str("\n"))
                    {
                        logException(frame);
                    }
                }
                // #DF is an architectural non-restartable abort: never return or execute IRETQ.
                cpu.haltLoop();
            }

            if (!df_state.completeDfFail()) {
                cpu.haltLoop();
            }
            if (serial.initialized) {
                if (SerialOut.str("[DF-TEST] FAIL: Vector 8 (#DF) forensic verification failed.\n") and
                    SerialOut.labelHex("[DF-TEST] Faulting Linear Address (CR2): ", cr2) and
                    SerialOut.str("\n"))
                {
                    logException(frame);
                }
            }
            cpu.haltLoop();
        },
    }
}

pub export fn x86_64_interrupt_dispatch(frame: *InterruptFrame) callconv(.c) void {
    if (comptime build_options.test_double_fault) {
        handleStandaloneDfDispatch(frame);
    }

    // Architectural #DF (Vector 8) and Phase 1 Policy #MC (Vector 18) never recover or IRETQ.
    const is_non_recoverable = (frame.vector == vectors.DOUBLE_FAULT_VECTOR or
        frame.vector == vectors.MACHINE_CHECK_VECTOR);

    // Check if this exception was triggered as part of a controlled self-test hook.
    if (!is_non_recoverable) {
        if (test_expected_vector) |expected| {
            if (frame.vector == expected) {
                test_occurred = true;
                test_observed_rip = frame.rip;
                test_observed_rsp = frame.rsp;
                test_observed_cs = frame.cs;
                test_observed_ss = frame.ss;
                test_observed_frame_addr = @intFromPtr(frame);

                if (frame.vector == vectors.PAGE_FAULT_VECTOR) {
                    test_fault_cr2 = cpu.readCr2();
                    // Only #PF (Fault) advances past the synthetic faulting mov instruction;
                    // Vector 3 (#BP Trap) already pushes the next instruction RIP.
                    frame.rip += test_skip_instruction_len;
                }
                return;
            }
        }
    }

    // Pre-serial emergency path (e.g., exception between idt.initEarly() and serial.init()):
    // skip UART logging completely and halt cleanly with zero SIMD/polling operations.
    if (!serial.initialized) {
        cpu.haltLoop();
    }

    // Unhandled or unexpected exception -> bounded diagnostic log, then permanent halt.
    logException(frame);
    cpu.haltLoop();
}

pub fn logException(frame: *const InterruptFrame) void {
    if (!serial.initialized) return;

    if (!SerialOut.str("\n\n====================================================\n")) return;
    if (!SerialOut.str("           CPU EXCEPTION DETECTED!                  \n")) return;
    if (!SerialOut.str("====================================================\n")) return;

    const vec_name = if (frame.vector < EXCEPTION_MESSAGES.len)
        EXCEPTION_MESSAGES[frame.vector]
    else
        "Hardware Interrupt";

    if (!SerialOut.str("[EXCEPTION] Vector: ")) return;
    if (!SerialOut.dec(frame.vector)) return;
    if (!SerialOut.str(" (")) return;
    if (!SerialOut.str(vec_name)) return;
    if (!SerialOut.str(")\n")) return;

    if (!SerialOut.labelHex("[EXCEPTION] Error Code: ", frame.error_code)) return;
    if (!SerialOut.str("\n")) return;

    if (frame.vector == vectors.PAGE_FAULT_VECTOR) {
        const cr2 = cpu.readCr2();
        if (!SerialOut.labelHex("[PAGE FAULT] Faulting Linear Address (CR2): ", cr2)) return;
        if (!SerialOut.str("\n[PAGE FAULT] Cause: ")) return;

        const cause = PageFaultCause.decode(frame.error_code);

        if (cause.protection_violation) {
            if (!SerialOut.str("[protection violation] ")) return;
        } else {
            if (!SerialOut.str("[non-present page] ")) return;
        }
        if (cause.write) {
            if (!SerialOut.str("[write access] ")) return;
        } else {
            if (!SerialOut.str("[read access] ")) return;
        }
        if (cause.user_mode) {
            if (!SerialOut.str("[user mode] ")) return;
        } else {
            if (!SerialOut.str("[kernel mode] ")) return;
        }
        if (cause.reserved_bit) {
            if (!SerialOut.str("[reserved bit violation] ")) return;
        }
        if (cause.instruction_fetch) {
            if (!SerialOut.str("[instruction fetch (NX)] ")) return;
        }
        if (!SerialOut.str("\n")) return;
    }

    if (!SerialOut.str("\n--- CPU Register State ---\n")) return;
    if (!SerialOut.labelHex("RIP: ", frame.rip)) return;
    if (!SerialOut.labelHex("  CS:     ", frame.cs)) return;
    if (!SerialOut.labelHex("  RFLAGS: ", frame.rflags)) return;
    if (!SerialOut.str("\n")) return;

    if (!SerialOut.labelHex("RSP: ", frame.rsp)) return;
    if (!SerialOut.labelHex("  SS:     ", frame.ss)) return;
    if (!SerialOut.str("\n")) return;

    const RegRow = struct {
        l0: []const u8,
        v0: u64,
        l1: []const u8,
        v1: u64,
        l2: []const u8,
        v2: u64,
    };
    const rows = [_]RegRow{
        .{ .l0 = "RAX: ", .v0 = frame.rax, .l1 = "  RBX:    ", .v1 = frame.rbx, .l2 = "  RCX:    ", .v2 = frame.rcx },
        .{ .l0 = "RDX: ", .v0 = frame.rdx, .l1 = "  RSI:    ", .v1 = frame.rsi, .l2 = "  RDI:    ", .v2 = frame.rdi },
        .{ .l0 = "RBP: ", .v0 = frame.rbp, .l1 = "  R8:     ", .v1 = frame.r8, .l2 = "  R9:     ", .v2 = frame.r9 },
        .{ .l0 = "R10: ", .v0 = frame.r10, .l1 = "  R11:    ", .v1 = frame.r11, .l2 = "  R12:    ", .v2 = frame.r12 },
        .{ .l0 = "R13: ", .v0 = frame.r13, .l1 = "  R14:    ", .v1 = frame.r14, .l2 = "  R15:    ", .v2 = frame.r15 },
    };

    for (rows) |row| {
        if (!SerialOut.labelHex(row.l0, row.v0)) return;
        if (!SerialOut.labelHex(row.l1, row.v1)) return;
        if (!SerialOut.labelHex(row.l2, row.v2)) return;
        if (!SerialOut.str("\n")) return;
    }
    _ = SerialOut.str("====================================================\n");
}
