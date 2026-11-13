// Legacy 8259A Programmable Interrupt Controller (PIC) Remap and Masking
// Remaps master/slave PIC IRQs out of the architectural CPU exception range (0x00..0x1F)
// to 0x20..0x2F and masks all 16 legacy IRQ lines while interrupt handling transitions to APIC.

const cpu = @import("../cpu.zig");
const vectors = @import("vectors.zig");

pub const PIC1_COMMAND_PORT: u16 = 0x20;
pub const PIC1_DATA_PORT: u16 = 0x21;
pub const PIC2_COMMAND_PORT: u16 = 0xA0;
pub const PIC2_DATA_PORT: u16 = 0xA1;

const ICW1_ICW4: u8 = 0x01;
const ICW1_INIT: u8 = 0x10;
const ICW1_COMMAND: u8 = ICW1_INIT | ICW1_ICW4; // 0x11

const ICW3_MASTER_SLAVE_ON_IRQ2: u8 = 0x04;
const ICW3_SLAVE_CASCADE_ID: u8 = 0x02;

const ICW4_8086_MODE: u8 = 0x01;

pub const ALL_IRQS_MASKED: u8 = 0xFF;

comptime {
    if (!vectors.isPicOffsetValid(vectors.LEGACY_PIC_MASTER_OFFSET, vectors.LEGACY_PIC_SLAVE_OFFSET)) {
        @compileError("Legacy 8259 PIC offsets violate architectural vector reservation");
    }
}

pub const PicMasks = struct {
    master: u8,
    slave: u8,
};

/// Reads the current Interrupt Mask Registers (IMRs) from both legacy 8259 PICs.
pub fn readMasks() PicMasks {
    return .{
        .master = cpu.inb(PIC1_DATA_PORT),
        .slave = cpu.inb(PIC2_DATA_PORT),
    };
}

/// Returns true iff all 16 legacy 8259 PIC IRQ lines are masked (IMRs == 0xFF/0xFF).
pub fn areAllMasked() bool {
    const masks = readMasks();
    return masks.master == ALL_IRQS_MASKED and masks.slave == ALL_IRQS_MASKED;
}

/// Remaps the dual 8259 PICs to vectors 0x20..0x2F and masks all IRQ lines.
/// Returns true iff both IMR registers read back as 0xFF after initialization.
/// Must be called with CPU interrupts disabled (IF = 0). Never enables interrupts.
pub fn remapAndMask() bool {
    if (!vectors.isPicOffsetValid(vectors.LEGACY_PIC_MASTER_OFFSET, vectors.LEGACY_PIC_SLAVE_OFFSET)) {
        return false;
    }

    // Mask all IRQs prior to resetting controller state via ICW1.
    cpu.outb(PIC1_DATA_PORT, ALL_IRQS_MASKED);
    cpu.ioWait();
    cpu.outb(PIC2_DATA_PORT, ALL_IRQS_MASKED);
    cpu.ioWait();

    // ICW1: start cascade initialization sequence requiring ICW4.
    cpu.outb(PIC1_COMMAND_PORT, ICW1_COMMAND);
    cpu.ioWait();
    cpu.outb(PIC2_COMMAND_PORT, ICW1_COMMAND);
    cpu.ioWait();

    // ICW2: set remapped interrupt vector offsets outside CPU exceptions (0x20..0x2F).
    cpu.outb(PIC1_DATA_PORT, vectors.LEGACY_PIC_MASTER_OFFSET);
    cpu.ioWait();
    cpu.outb(PIC2_DATA_PORT, vectors.LEGACY_PIC_SLAVE_OFFSET);
    cpu.ioWait();

    // ICW3: configure master/slave cascade wiring on IRQ2.
    cpu.outb(PIC1_DATA_PORT, ICW3_MASTER_SLAVE_ON_IRQ2);
    cpu.ioWait();
    cpu.outb(PIC2_DATA_PORT, ICW3_SLAVE_CASCADE_ID);
    cpu.ioWait();

    // ICW4: select 8086/88 mode.
    cpu.outb(PIC1_DATA_PORT, ICW4_8086_MODE);
    cpu.ioWait();
    cpu.outb(PIC2_DATA_PORT, ICW4_8086_MODE);
    cpu.ioWait();

    // Mask all 16 IRQs after ICW initialization sequence completes.
    cpu.outb(PIC1_DATA_PORT, ALL_IRQS_MASKED);
    cpu.ioWait();
    cpu.outb(PIC2_DATA_PORT, ALL_IRQS_MASKED);
    cpu.ioWait();

    return areAllMasked();
}
