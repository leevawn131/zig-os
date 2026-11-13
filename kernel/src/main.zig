// ZIG-OS Kernel Entry Point
const std = @import("std");
pub const panic = @import("panic.zig").panicHandler;

const limine = @import("limine.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const serial = @import("drivers/serial/serial.zig");
const idt = @import("arch/x86_64/idt/idt.zig");
const pmm = @import("mm/physical.zig");
const vmm = @import("mm/virtual.zig");
const heap = @import("mm/heap.zig");

export fn _start() callconv(.c) noreturn {
    // 1. Disable maskable hardware interrupts during early initialization
    cpu.cli();

    // 2. Enable SSE/FPU floating-point unit in CR0/CR4
    cpu.enableSse();

    // 3. Initialize COM1 serial logging
    if (!serial.init()) {
        cpu.haltLoop();
    }

    // 4. Verify Limine base revision compliance
    if (!limine.isBaseRevisionSupported()) {
        serial.writeString("[FATAL] Limine base revision not supported.\n");
        cpu.haltLoop();
    }

    // 5. Output Phase 0 banner and core boot markers
    serial.writeString("\n");
    serial.writeString("====================================\n");
    serial.writeString("            ZIG-OS v0.1             \n");
    serial.writeString("====================================\n");
    serial.writeString("\n");
    serial.writeString("[BOOT] Limine boot protocol initialized.\n");
    serial.writeString("[CPU] Architecture: x86_64\n");
    if (!cpu.testSseCr0Init()) {
        serial.writeString("[FATAL] CPU SSE/CR0.TS initialization self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[CPU] SSE/CR0.TS initialization verified.\n");
    serial.writeString("[KERNEL] Zig kernel entry reached.\n");

    // 6. Inspect Limine bootloader memory map
    if (limine.memmap_request.response) |_| {
        serial.writeString("[MEMORY] Bootloader memory map received.\n");
    } else {
        serial.writeString("[MEMORY] Warning: Memory map request failed.\n");
        cpu.haltLoop();
    }

    // 7. Initialize and verify IDT (256 entries) & CPU Exception dispatch
    idt.init();
    if (!idt.testExceptionDispatch()) {
        serial.writeString("[FATAL] IDT exception dispatch self-test failed.\n");
        cpu.haltLoop();
    }
    if (!idt.testPageFaultHandling()) {
        serial.writeString("[FATAL] IDT page fault handling self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[IDT] 256 interrupt gates configured and verified.\n");

    // 8. Initialize Physical Memory Manager (PMM)
    pmm.init();
    if (!pmm.testPmm()) {
        serial.writeString("[FATAL] PMM allocation/free self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[PMM] Physical frame allocator initialized and verified.\n");

    // 9. Verify Virtual Memory Manager (VMM) 4-level paging primitives
    if (!vmm.testVmm()) {
        serial.writeString("[FATAL] VMM mapping/unmapping self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[VMM] 4-level paging and translation primitives verified.\n");

    // 10. Initialize Kernel Heap Allocator backed by PMM & VMM
    heap.init(4);
    if (!heap.testHeap()) {
        serial.writeString("[FATAL] Kernel heap allocator self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[HEAP] Dynamic memory allocator initialized and verified.\n");

    // 11. Complete initialization sequence
    serial.writeString("[STATUS] Kernel initialization complete.\n");
    serial.writeString("\n");
    serial.writeString("zig-os:~$ ");

    // 12. Quiescent CPU halt loop
    cpu.haltLoop();
}
