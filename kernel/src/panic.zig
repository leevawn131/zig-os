// Kernel Panic Handler
const std = @import("std");
const serial = @import("drivers/serial/serial.zig");
const cpu = @import("arch/x86_64/cpu.zig");

pub fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    cpu.cli();
    _ = serial.init();

    serial.writeString("\n\n====================================\n");
    serial.writeString("           KERNEL PANIC!            \n");
    serial.writeString("====================================\n");
    serial.writeString("[PANIC] Reason: ");
    serial.writeString(msg);
    serial.writeString("\n");

    if (ret_addr) |ra| {
        serial.writeString("[PANIC] Return Address: ");
        serial.writeHex(ra);
        serial.writeString("\n");
    }

    serial.writeString("[PANIC] System halted.\n");

    cpu.haltLoop();
}

pub const panicHandler = std.debug.FullPanic(panicFn);
