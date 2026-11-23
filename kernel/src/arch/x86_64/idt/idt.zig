// Interrupt Descriptor Table (IDT) Configuration & Controlled Exception Tests
const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("../cpu.zig");
const gdt = @import("../gdt/gdt.zig");
const serial = @import("../../../drivers/serial/serial.zig");
const pmm = @import("../../../mm/physical.zig");
const vmm = @import("../../../mm/virtual.zig");
const vectors = @import("../interrupts/vectors.zig");
pub const handlers = @import("handlers.zig");

pub const IdtEntry = extern struct {
    offset_low: u16,   // Target offset bits 0..15
    selector: u16,     // Code segment selector in GDT
    ist: u8,           // Bits 0..2: IST index (0 = disabled), bits 3..7: reserved (0)
    flags: u8,         // Type (0xE = 64-bit Interrupt Gate), DPL (0), Present (1) -> 0x8E
    offset_mid: u16,   // Target offset bits 16..31
    offset_high: u32,  // Target offset bits 32..63
    reserved: u32 = 0, // Reserved, must be 0

    pub fn setGate(self: *IdtEntry, handler_addr: u64, selector: u16, flags: u8, ist: u8) void {
        self.offset_low = @truncate(handler_addr);
        self.selector = selector;
        self.ist = ist & 0x07;
        self.flags = flags;
        self.offset_mid = @truncate(handler_addr >> 16);
        self.offset_high = @truncate(handler_addr >> 32);
        self.reserved = 0;
    }
};

pub const IdtDescriptor = packed struct(u80) {
    limit: u16,
    base: u64,
};

pub var idt_table: [vectors.IDT_ENTRY_COUNT]IdtEntry align(16) = undefined;
pub var idtr: IdtDescriptor = undefined;

// Exported from assembly stubs
extern const isr_stub_table: [vectors.IDT_ENTRY_COUNT]*const fn () callconv(.c) void;

const DfTriggerExtern = if (build_options.test_double_fault) struct {
    extern fn x86_64_trigger_df_unmapped_stack(unmapped_rsp: u64) callconv(.{ .x86_64_sysv = .{} }) noreturn;
} else struct {};

fn entryOffset(entry: IdtEntry) u64 {
    return (@as(u64, entry.offset_high) << 32) |
        (@as(u64, entry.offset_mid) << 16) |
        @as(u64, entry.offset_low);
}

/// Early boot IDT installation immediately after `cpu.cli()`:
/// populates all 256 gates with `ist = 0` using the active kernel CS (`0x28`) and loads IDTR.
pub fn initEarly() void {
    // Force inclusion of the interrupt dispatcher export
    _ = &handlers.x86_64_interrupt_dispatch;

    const kernel_cs = gdt.getCs();

    // Populate all 256 IDT gates with their corresponding assembly stub (`ist = 0` initially).
    for (0..vectors.IDT_ENTRY_COUNT) |i| {
        const handler_addr = @intFromPtr(isr_stub_table[i]);
        idt_table[i].setGate(handler_addr, kernel_cs, vectors.IDT_GATE_FLAGS_KERNEL_INTERRUPT, vectors.IST_NONE);
    }

    idtr = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    cpu.lidt(&idtr);
}

/// Activates `IST1` (#DF Vector 8), `IST2` (#NMI Vector 2), and `IST3` (#MC Vector 18)
/// through ordered per-entry IDT updates while `RFLAGS.IF = 0`.
/// Requires `gdt.init()` (TSS + all three IST stacks) to be completed first.
/// Because `CLI` does not mask NMI or #MC, an NMI/#MC arriving during this window may
/// observe either the prior valid (`ist = 0`) gate or the activated IST gate; both paths are valid.
pub fn enableIstGates() void {
    if (!gdt.isInitialized()) {
        @panic("IDT: kernel GDT/TSS and IST stacks must be initialized before enabling IST gates");
    }

    // Perform ordered per-entry updates (not a single atomic multi-entry hardware transaction).
    idt_table[vectors.DOUBLE_FAULT_VECTOR].ist = vectors.IST_DOUBLE_FAULT;
    idt_table[vectors.NMI_VECTOR].ist = vectors.IST_NMI;
    idt_table[vectors.MACHINE_CHECK_VECTOR].ist = vectors.IST_MACHINE_CHECK;
}

/// Validates all 256 IDT gates and enforces exception vector invariants:
/// - IDTR limit and base match `idt_table`.
/// - Every gate (including 0..31) is Present, DPL=0, 64-bit Interrupt Gate (0x8E),
///   uses kernel CS (`0x28`), has expected IST index (8->1, 2->2, 18->3, others->0),
///   has reserved bits cleared, and points to its exact ISR stub.
/// - All 32 exception vectors map to distinct ISR stub addresses.
pub fn validateExceptionGates() bool {
    if (idtr.limit != @sizeOf(@TypeOf(idt_table)) - 1) return false;
    if (idtr.base != @intFromPtr(&idt_table)) return false;

    const expected_cs = gdt.getCs();
    if (expected_cs != gdt.KERNEL_CODE_SELECTOR) return false;

    for (0..vectors.IDT_ENTRY_COUNT) |i| {
        const entry = idt_table[i];
        const expected_offset = @intFromPtr(isr_stub_table[i]);
        if (expected_offset == 0) return false;

        const expected_ist = vectors.expectedIstForVector(@intCast(i));
        if (!vectors.isValidKernelInterruptGate(
            entry.flags,
            entry.ist,
            expected_ist,
            entry.reserved,
            entry.selector,
            expected_cs,
            entryOffset(entry),
            expected_offset,
        )) {
            return false;
        }
    }

    // Verify all 32 architectural exception vectors (0..31) target distinct ISR stubs.
    for (0..vectors.EXCEPTION_VECTOR_COUNT) |a| {
        const addr_a = @intFromPtr(isr_stub_table[a]);
        for (a + 1..vectors.EXCEPTION_VECTOR_COUNT) |b| {
            if (addr_a == @intFromPtr(isr_stub_table[b])) return false;
        }
    }

    return true;
}

fn runBreakpointDispatchCheck(test_ist: u8) bool {
    const bp_vec = vectors.BREAKPOINT_VECTOR;
    const prev_ist = idt_table[bp_vec].ist;
    idt_table[bp_vec].ist = test_ist & 0x07;
    defer idt_table[bp_vec].ist = prev_ist;

    handlers.resetTestHooks();
    handlers.test_expected_vector = bp_vec;
    // Trap vector 3 (#BP) already saves RIP pointing at the next instruction; never add a skip length.
    handlers.test_skip_instruction_len = 0;
    defer handlers.resetTestHooks();

    var pre_rsp: u64 = 0;
    var post_rsp: u64 = 0;
    var expected_resume_rip: u64 = 0;
    var resume_marker: u64 = 0;

    asm volatile (
        \\ movq %%rsp, %[pre_rsp]
        \\ leaq 1f(%%rip), %[expected_rip]
        \\ int $3
        \\ 1:
        \\ movq $0x5A5A5A5AA5A5A5A5, %[marker]
        \\ movq %%rsp, %[post_rsp]
        : [pre_rsp] "=&r" (pre_rsp),
          [post_rsp] "=&r" (post_rsp),
          [expected_rip] "=&r" (expected_resume_rip),
          [marker] "=&r" (resume_marker),
        :
        : .{ .memory = true }
    );

    if (!handlers.test_occurred) return false;
    if (handlers.test_observed_rip != expected_resume_rip) return false;
    if (resume_marker != 0x5A5A5A5AA5A5A5A5) return false;
    if (handlers.test_observed_rsp != pre_rsp or post_rsp != pre_rsp) return false;
    if (handlers.test_observed_cs != gdt.KERNEL_CODE_SELECTOR) return false;
    if (handlers.test_observed_ss != gdt.KERNEL_DATA_SELECTOR) return false;

    const frame_addr = handlers.test_observed_frame_addr;
    const frame_size = @sizeOf(handlers.InterruptFrame);

    if (test_ist == 0) {
        for ([_]u8{ 1, 2, 3 }) |idx| {
            const r = gdt.istRange(idx) orelse return false;
            if (!vectors.isFrameDisjointFromStack(frame_addr, frame_size, r.base, r.top)) return false;
        }
        return true;
    }

    const target = gdt.istRange(test_ist) orelse return false;
    return vectors.isFrameWithinStack(frame_addr, frame_size, target.base, target.top);
}

pub fn testExceptionDispatch() bool {
    if (!gdt.isInitialized()) return false;
    if (idt_table[vectors.BREAKPOINT_VECTOR].ist != 0) return false;
    return runBreakpointDispatchCheck(vectors.IST_NONE);
}

/// Exercises hardware TSS IST1, IST2, and IST3 stack switching via recoverable `int $3` (#BP).
/// Must run before `enableIstGates()` so `idt_table[2]` (`#NMI`) still has `ist = 0`.
/// Note: Exercising `IST3` via `int $3` validates `TSS.IST3` stack-switching mechanics only
/// and never generates or simulates a real hardware Machine Check Exception.
pub fn testIstStackSwitch() bool {
    if (!gdt.isInitialized()) return false;
    if (idt_table[vectors.DOUBLE_FAULT_VECTOR].ist != 0) return false;
    if (idt_table[vectors.NMI_VECTOR].ist != 0) return false;
    if (idt_table[vectors.MACHINE_CHECK_VECTOR].ist != 0) return false;
    if (idt_table[vectors.BREAKPOINT_VECTOR].ist != 0) return false;

    for ([_]u8{ vectors.IST_DOUBLE_FAULT, vectors.IST_NMI, vectors.IST_MACHINE_CHECK }) |ist_idx| {
        if (!runBreakpointDispatchCheck(ist_idx)) return false;
    }

    return idt_table[vectors.BREAKPOINT_VECTOR].ist == 0;
}

pub fn testPageFaultHandling() bool {
    handlers.resetTestHooks();
    handlers.test_expected_vector = vectors.PAGE_FAULT_VECTOR;
    // Instruction to fault on: 2-byte `mov (%rax), %al` (0x8a 0x00)
    handlers.test_skip_instruction_len = 2;
    defer handlers.resetTestHooks();

    const fault_addr: u64 = 0x0000_0000_DEAD_B000;
    asm volatile (
        \\ mov %[addr], %%rax
        \\ mov (%%rax), %%al
        :
        : [addr] "r" (fault_addr),
        : .{ .rax = true }
    );

    return handlers.test_occurred and handlers.test_fault_cr2 == fault_addr;
}

fn dfFailAndHalt(msg: []const u8) noreturn {
    _ = handlers.df_state.tryTransition(.preparing, .failed);
    if (serial.initialized) {
        _ = serial.tryWriteStringBounded(msg, serial.MAX_TX_POLL_SPINS);
    }
    cpu.haltLoop();
}

/// Standalone, noreturn QEMU test (`iso-df-test` / `test-df` profile only):
/// proves real stack-overflow #PF -> #DF escalation switches onto `TSS.IST1`.
pub fn runStandaloneDoubleFaultTest() noreturn {
    if (comptime !build_options.test_double_fault) {
        @compileError("runStandaloneDoubleFaultTest is only compiled in isolated test-df builds");
    }

    if (!handlers.df_state.tryTransition(.inactive, .preparing)) {
        cpu.haltLoop();
    }

    const test_page = handlers.DF_TEST_UNMAPPED_PAGE;
    const test_rsp = handlers.DF_TEST_UNMAPPED_RSP;

    if (!vmm.isCanonical(test_page) or !vmm.isCanonical(test_rsp)) {
        dfFailAndHalt("[DF-TEST] FAIL: Non-canonical DF test address.\n");
    }

    const pml4 = vmm.getActivePml4();

    // Refuse to unmap any pre-existing mapping outside test ownership.
    if (vmm.isMapped(pml4, test_page) or vmm.virtToPhys(pml4, test_page) != null) {
        dfFailAndHalt("[DF-TEST] FAIL: Unexpected pre-existing mapping at test page; refusing to unmap.\n");
    }

    const phys = pmm.allocPage() orelse {
        dfFailAndHalt("[DF-TEST] FAIL: PMM allocPage failed.\n");
    };

    // Perform an explicit test-owned map -> verify -> unmap -> verify-unmapped cycle
    // before releasing `phys` (`ITR-1`: never free a physical frame while still mapped).
    vmm.mapPage(pml4, test_page, phys, vmm.Flags.WRITABLE) catch {
        if (!vmm.isMapped(pml4, test_page) and vmm.virtToPhys(pml4, test_page) == null) {
            pmm.freePage(phys);
        }
        dfFailAndHalt("[DF-TEST] FAIL: VMM mapPage failed.\n");
    };

    if (vmm.virtToPhys(pml4, test_page) != phys) {
        dfFailAndHalt("[DF-TEST] FAIL: Test mapping verification failed.\n");
    }

    vmm.unmapPage(pml4, test_page) catch {
        // ITR-1: Do NOT free `phys` because mapping may remain active.
        dfFailAndHalt("[DF-TEST] FAIL: VMM unmapPage failed; refusing to free mapped frame.\n");
    };

    // Verify mapping removal BEFORE calling `pmm.freePage(phys)` (`ITR-1`).
    if (vmm.isMapped(pml4, test_page) or vmm.virtToPhys(pml4, test_page) != null) {
        dfFailAndHalt("[DF-TEST] FAIL: Residual mapping present after unmapPage; refusing to free frame.\n");
    }
    pmm.freePage(phys);

    if (!gdt.isInitialized() or
        idt_table[vectors.PAGE_FAULT_VECTOR].ist != 0 or
        idt_table[vectors.DOUBLE_FAULT_VECTOR].ist != vectors.IST_DOUBLE_FAULT or
        gdt.kernel_tss.ist1 != gdt.ist1Top())
    {
        dfFailAndHalt("[DF-TEST] FAIL: IDT/TSS precondition failed.\n");
    }

    if (serial.initialized) {
        _ = serial.tryWriteStringBounded(
            "[DF-TEST] Armed: invoking standalone unmapped-stack trigger...\n",
            serial.MAX_TX_POLL_SPINS,
        );
    }

    if (!handlers.df_state.tryTransition(.preparing, .armed)) {
        cpu.haltLoop();
    }

    DfTriggerExtern.x86_64_trigger_df_unmapped_stack(test_rsp);
}
