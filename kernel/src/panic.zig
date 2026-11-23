// Kernel Panic Handler
const std = @import("std");
pub const serial = @import("drivers/serial/serial.zig");
pub const cpu = @import("arch/x86_64/cpu.zig");

pub fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    cpu.cli();
    if (!serial.initialized) {
        if (!serial.init()) cpu.haltLoop();
    }

    const spins = serial.MAX_TX_POLL_SPINS;
    if (!serial.tryWriteStringBounded("\n\n====================================\n", spins)) cpu.haltLoop();
    if (!serial.tryWriteStringBounded("           KERNEL PANIC!            \n", spins)) cpu.haltLoop();
    if (!serial.tryWriteStringBounded("====================================\n", spins)) cpu.haltLoop();
    if (!serial.tryWriteStringBounded("[PANIC] Reason: ", spins)) cpu.haltLoop();
    if (!serial.tryWriteStringBounded(msg, spins)) cpu.haltLoop();
    if (!serial.tryWriteStringBounded("\n", spins)) cpu.haltLoop();

    if (ret_addr) |ra| {
        if (!serial.tryWriteStringBounded("[PANIC] Return Address: ", spins)) cpu.haltLoop();
        if (!serial.tryWriteHexBounded(ra, spins)) cpu.haltLoop();
        if (!serial.tryWriteStringBounded("\n", spins)) cpu.haltLoop();
    }

    _ = serial.tryWriteStringBounded("[PANIC] System halted.\n", spins);
    cpu.haltLoop();
}

pub const panicHandler = std.debug.FullPanic(panicFn);
