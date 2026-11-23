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

/// Bounded spin budget per UART byte during emergency panic / exception logging (`N-03`).
pub const MAX_TX_POLL_SPINS: u32 = 100_000;

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

/// Pure, host-testable bounded polling loop for UART transmit readiness.
/// Zero hardware/port I/O references inside body so host unit tests compile cleanly.
pub fn waitForTxReady(
    ctx: anytype,
    comptime readyFn: fn (@TypeOf(ctx)) bool,
    max_spins: u32,
) bool {
    var spins: u32 = 0;
    while (spins < max_spins) : (spins += 1) {
        if (readyFn(ctx)) return true;
    }
    return false;
}

fn com1TxReady(_: void) bool {
    return isTransmitEmpty();
}

/// Bounded emergency UART byte output: never initializes COM1 when `!initialized`,
/// and returns `false` if `LSR.THRE` does not assert within `max_spins` iterations.
pub fn tryWriteByteBounded(byte: u8, max_spins: u32) bool {
    if (!initialized) return false;

    if (byte == '\n') {
        if (!waitForTxReady({}, com1TxReady, max_spins)) return false;
        cpu.outb(COM1 + REG_DATA, '\r');
    }

    if (!waitForTxReady({}, com1TxReady, max_spins)) return false;
    cpu.outb(COM1 + REG_DATA, byte);
    return true;
}

pub fn tryWriteStringBounded(str: []const u8, max_spins: u32) bool {
    if (!initialized) return false;
    for (str) |byte| {
        if (!tryWriteByteBounded(byte, max_spins)) return false;
    }
    return true;
}

pub fn tryWriteHexBounded(val: u64, max_spins: u32) bool {
    var buf: [18]u8 = undefined;
    return tryWriteStringBounded(formatHex(val, &buf), max_spins);
}

pub fn tryWriteDecBounded(val: u64, max_spins: u32) bool {
    var buf: [20]u8 = undefined;
    return tryWriteStringBounded(formatDec(val, &buf), max_spins);
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

fn formatHex(val: u64, buf: *[18]u8) []const u8 {
    const hex_digits = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    var idx: usize = 2;
    var shift: u6 = 60;
    while (true) : (idx += 1) {
        const nibble: u8 = @truncate((val >> shift) & 0xF);
        buf[idx] = hex_digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }
    return buf[0..18];
}

fn formatDec(val: u64, buf: *[20]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var rev_idx: usize = 20;
    var temp = val;
    while (temp > 0) {
        rev_idx -= 1;
        buf[rev_idx] = @truncate('0' + (temp % 10));
        temp /= 10;
    }
    return buf[rev_idx..20];
}

pub fn writeHex(val: u64) void {
    var buf: [18]u8 = undefined;
    writeString(formatHex(val, &buf));
}

pub fn writeDec(val: u64) void {
    var buf: [20]u8 = undefined;
    writeString(formatDec(val, &buf));
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |str| {
        writeString(str);
    } else |_| {
        writeString("[SERIAL FORMAT ERROR]\n");
    }
}
