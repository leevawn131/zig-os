// COM1 16550 UART Serial Driver
const std = @import("std");
const cpu = @import("../../arch/x86_64/cpu.zig");

pub const COM1: u16 = 0x3F8;

pub const REG_DATA: u16 = 0; // Data Register (DLAB=0)
pub const REG_IER: u16 = 1;  // Interrupt Enable Register (DLAB=0)
pub const REG_DLL: u16 = 0;  // Divisor Latch Low (DLAB=1)
pub const REG_DLH: u16 = 1;  // Divisor Latch High (DLAB=1)
pub const REG_FCR: u16 = 2;  // FIFO Control Register
pub const REG_LCR: u16 = 3;  // Line Control Register
pub const REG_MCR: u16 = 4;  // Modem Control Register
pub const REG_LSR: u16 = 5;  // Line Status Register

pub var initialized: bool = false;

pub fn init() bool {
    // Disable all UART interrupts during early boot
    cpu.outb(COM1 + REG_IER, 0x00);

    // Enable DLAB (set baud rate divisor)
    cpu.outb(COM1 + REG_LCR, 0x80);

    // Set baud rate divisor to 1 (115200 baud)
    cpu.outb(COM1 + REG_DLL, 0x01);
    cpu.outb(COM1 + REG_DLH, 0x00);

    // 8 bits, no parity, one stop bit (8N1), clear DLAB
    cpu.outb(COM1 + REG_LCR, 0x03);

    // Enable FIFO, clear TX and RX FIFOs, 14-byte threshold
    cpu.outb(COM1 + REG_FCR, 0xC7);

    // RTS/DSR set, enable auxiliary output 2
    cpu.outb(COM1 + REG_MCR, 0x0B);

    // Perform hardware loopback self-test to verify UART function
    cpu.outb(COM1 + REG_MCR, 0x1E);
    cpu.outb(COM1 + REG_DATA, 0xAE);
    cpu.ioWait();

    if (cpu.inb(COM1 + REG_DATA) != 0xAE) {
        return false;
    }

    // Set normal operating mode (not loopback, RTS/DSR set, OUT1/OUT2 enabled)
    cpu.outb(COM1 + REG_MCR, 0x0F);
    initialized = true;
    return true;
}

pub inline fn isTransmitEmpty() bool {
    return (cpu.inb(COM1 + REG_LSR) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
    if (!initialized) {
        _ = init();
    }

    // Handle carriage return insertion for standard newlines
    if (byte == '\n') {
        while (!isTransmitEmpty()) {}
        cpu.outb(COM1 + REG_DATA, '\r');
    }

    while (!isTransmitEmpty()) {}
    cpu.outb(COM1 + REG_DATA, byte);
}

pub fn writeString(str: []const u8) void {
    for (str) |byte| {
        writeByte(byte);
    }
}

pub fn writeHex(val: u64) void {
    const hex_digits = "0123456789abcdef";
    writeString("0x");
    var shift: u6 = 60;
    while (true) {
        const nibble: u8 = @truncate((val >> shift) & 0xF);
        writeByte(hex_digits[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn writeDec(val: u64) void {
    if (val == 0) {
        writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var idx: usize = 0;
    var temp = val;
    while (temp > 0) {
        buf[idx] = @truncate('0' + (temp % 10));
        temp /= 10;
        idx += 1;
    }
    while (idx > 0) {
        idx -= 1;
        writeByte(buf[idx]);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |str| {
        writeString(str);
    } else |_| {
        writeString("[SERIAL FORMAT ERROR]\n");
    }
}
