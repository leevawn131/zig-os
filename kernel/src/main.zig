// ZIG-OS Kernel Entry Point
const std = @import("std");
pub const panic = @import("panic.zig").panicHandler;

const limine = @import("limine.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const serial = @import("drivers/serial/serial.zig");

export fn _start() callconv(.c) noreturn {
    // Disable interrupts on entry until IDT and ISRs are configured
    cpu.cli();

    // Initialize COM1 serial port for early kernel logging
    if (!serial.init()) {
        cpu.haltLoop();
    }

    // Verify Limine base revision compliance
    if (!limine.isBaseRevisionSupported()) {
        serial.writeString("[FATAL] Limine base revision not supported.\n");
        cpu.haltLoop();
    }

    // Output kernel banner and initialization messages
    serial.writeString("\n");
    serial.writeString("====================================\n");
    serial.writeString("            ZIG-OS v0.1             \n");
    serial.writeString("====================================\n");
    serial.writeString("\n");
    serial.writeString("[BOOT] Limine boot protocol initialized.\n");
    serial.writeString("[CPU] Architecture: x86_64\n");
    serial.writeString("[KERNEL] Zig kernel entry reached.\n");

    // Inspect Limine bootloader memory map
    if (limine.memmap_request.response) |memmap| {
        serial.writeString("[MEMORY] Bootloader memory map received.\n");
        _ = memmap;
    } else {
        serial.writeString("[MEMORY] Warning: Memory map request failed.\n");
    }

    serial.writeString("[STATUS] Kernel initialization complete.\n");
    serial.writeString("\n");
    serial.writeString("zig-os:~$ ");

    // Quiescent halt loop - waits for interrupts without spinning CPU
    cpu.haltLoop();
}
