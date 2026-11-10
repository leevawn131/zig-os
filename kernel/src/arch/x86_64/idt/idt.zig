// Interrupt Descriptor Table (IDT) Configuration
const std = @import("std");
const cpu = @import("../cpu.zig");
const gdt = @import("../gdt/gdt.zig");
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

pub var idt_table: [256]IdtEntry align(16) = undefined;
pub var idtr: IdtDescriptor = undefined;

// Exported from assembly stubs
extern const isr_stub_table: [256]*const fn () callconv(.c) void;

pub fn init() void {
    // Force inclusion of the interrupt dispatcher export
    _ = &handlers.x86_64_interrupt_dispatch;

    const kernel_cs = gdt.getCs();

    // Populate all 256 IDT gates with their corresponding assembly stub
    for (0..256) |i| {
        const handler_addr = @intFromPtr(isr_stub_table[i]);
        // 0x8E = Present (0x80) | DPL 0 (0x00) | 64-bit Interrupt Gate (0x0E)
        idt_table[i].setGate(handler_addr, kernel_cs, 0x8E, 0);
    }

    idtr = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    cpu.lidt(&idtr);
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
