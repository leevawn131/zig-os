// Interrupt Descriptor Table (IDT) Configuration
const std = @import("std");
const cpu = @import("../cpu.zig");
const gdt = @import("../gdt/gdt.zig");
const vectors = @import("../interrupts/vectors.zig");
pub const handlers = @import("handlers.zig");

pub const IdtEntry = extern struct {
    offset_low: u16,      // Target offset bits 0..15
    selector: u16,        // Code segment selector in GDT
    ist: u8,              // Bits 0..2: IST index (0 = disabled), bits 3..7: reserved (0)
    flags: u8,            // Type (0xE = 64-bit Interrupt Gate), DPL (0), Present (1) -> 0x8E
    offset_mid: u16,      // Target offset bits 16..31
    offset_high: u32,     // Target offset bits 32..63
    reserved: u32 = 0,    // Reserved, must be 0

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

fn entryOffset(entry: IdtEntry) u64 {
    return (@as(u64, entry.offset_high) << 32) |
        (@as(u64, entry.offset_mid) << 16) |
        @as(u64, entry.offset_low);
}

pub fn init() void {
    // Force inclusion of the interrupt dispatcher export
    _ = &handlers.x86_64_interrupt_dispatch;

    const kernel_cs = gdt.getCs();

    // Populate all 256 IDT gates with their corresponding assembly stub
    for (0..vectors.IDT_ENTRY_COUNT) |i| {
        const handler_addr = @intFromPtr(isr_stub_table[i]);
        // 0x8E = Present (0x80) | DPL 0 (0x00) | 64-bit Interrupt Gate (0x0E)
        idt_table[i].setGate(handler_addr, kernel_cs, vectors.IDT_GATE_FLAGS_KERNEL_INTERRUPT, 0);
    }

    idtr = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    cpu.lidt(&idtr);
}

/// Validates all 256 IDT gates and enforces exception vector invariants:
/// - IDTR limit and base match `idt_table`.
/// - Every gate (including 0..31) is Present, DPL=0, 64-bit Interrupt Gate (0x8E),
///   uses current kernel CS, has reserved bits cleared, and points to its exact ISR stub.
/// - All 32 exception vectors map to distinct ISR stub addresses.
pub fn validateExceptionGates() bool {
    if (idtr.limit != @sizeOf(@TypeOf(idt_table)) - 1) return false;
    if (idtr.base != @intFromPtr(&idt_table)) return false;

    const expected_cs = gdt.getCs();

    for (0..vectors.IDT_ENTRY_COUNT) |i| {
        const entry = idt_table[i];
        const expected_offset = @intFromPtr(isr_stub_table[i]);
        if (expected_offset == 0) return false;

        if (!vectors.isValidKernelInterruptGate(
            entry.flags,
            entry.ist,
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

pub fn testExceptionDispatch() bool {
    handlers.test_expected_vector = 3;
    handlers.test_occurred = false;

    // Trigger controlled software breakpoint exception
    asm volatile ("int $3");

    const passed = handlers.test_occurred;
    handlers.test_expected_vector = null;
    handlers.test_occurred = false;
    return passed;
}

pub fn testPageFaultHandling() bool {
    handlers.test_expected_vector = 14;
    handlers.test_occurred = false;
    handlers.test_fault_cr2 = 0;
    // Instruction to fault on: 2-byte `mov (%rax), %al` (0x8a 0x00)
    handlers.test_skip_instruction_len = 2;

    const fault_addr: u64 = 0x0000_0000_DEAD_B000;
    asm volatile (
        \\ mov %[addr], %%rax
        \\ mov (%%rax), %%al
        :
        : [addr] "r" (fault_addr),
        : .{ .rax = true }
    );

    const passed = handlers.test_occurred and handlers.test_fault_cr2 == fault_addr;
    handlers.test_expected_vector = null;
    handlers.test_occurred = false;
    handlers.test_fault_cr2 = 0;
    handlers.test_skip_instruction_len = 0;
    return passed;
}
