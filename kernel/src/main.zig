// ZIG-OS Kernel Entry Point
const std = @import("std");
const build_options = @import("build_options");
pub const panic = @import("panic.zig").panicHandler;

const limine = @import("limine.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const serial = @import("drivers/serial/serial.zig");
const pic = @import("arch/x86_64/interrupts/pic.zig");
const gdt = @import("arch/x86_64/gdt/gdt.zig");
const idt = @import("arch/x86_64/idt/idt.zig");
const pmm = @import("mm/physical.zig");
const vmm = @import("mm/virtual.zig");
const heap = @import("mm/heap.zig");

export fn _start() callconv(.c) noreturn {
    // Step 1: Disable maskable hardware interrupts during early initialization (IF = 0 throughout Phase 1).
    cpu.cli();

    // Step 2: Install early 256-gate IDT (ist = 0) immediately after cli() to minimize IDTR=undefined window.
    idt.initEarly();

    // Step 3: Enable SSE/FPU floating-point unit in CR0/CR4 (preserving Limine CR4.MCE bit per MCE-2).
    cpu.enableSse();

    // Step 4: Initialize COM1 serial logging (halt cleanly on UART loopback failure).
    if (!serial.init()) {
        cpu.haltLoop();
    }

    // Step 5: Verify Limine base revision, SSE CR0/CR4 state, memory map, and legacy 8259 PIC isolation.
    if (!limine.isBaseRevisionSupported()) {
        serial.writeString("[FATAL] Limine base revision not supported.\n");
        cpu.haltLoop();
    }

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

    if (limine.memmap_request.response) |_| {
        serial.writeString("[MEMORY] Bootloader memory map received.\n");
    } else {
        serial.writeString("[MEMORY] Warning: Memory map request failed.\n");
        cpu.haltLoop();
    }

    if (!pic.remapAndMask()) {
        serial.writeString("[FATAL] Legacy 8259 PIC remap/mask verification failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[PIC] Legacy 8259 PIC remapped to 0x20-0x2F and masked (0xFF/0xFF).\n");

    // Step 6: Strict one-shot BSP kernel GDT, 64-bit TSS, and IST1-IST3 stack initialization.
    gdt.init();
    if (!gdt.testGdtAndTss()) {
        serial.writeString("[FATAL] Kernel GDT/TSS/IST initialization self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[GDT] Kernel GDT, 64-bit TSS, and IST1-IST3 stacks initialized and verified.\n");

    // Step 7: Ordered IST verification & gate activation (`N-05`), then final IDT & #PF validation.
    if (!idt.testExceptionDispatch()) {
        serial.writeString("[FATAL] IDT exception dispatch self-test failed.\n");
        cpu.haltLoop();
    }
    if (!idt.testIstStackSwitch()) {
        serial.writeString("[FATAL] IDT IST stack-switch self-test failed.\n");
        cpu.haltLoop();
    }
    idt.enableIstGates();
    if (!idt.validateExceptionGates()) {
        serial.writeString("[FATAL] IDT exception gate validation failed.\n");
        cpu.haltLoop();
    }
    if (!idt.testPageFaultHandling()) {
        serial.writeString("[FATAL] IDT page fault handling self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[IDT] 256 interrupt gates configured and verified.\n");

    // Step 8: Initialize & verify PMM, VMM, and Heap; then halt or run isolated DF test.
    pmm.init();
    if (!pmm.testPmm()) {
        serial.writeString("[FATAL] PMM allocation/free self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[PMM] Physical frame allocator initialized and verified.\n");

    if (!vmm.testVmm()) {
        serial.writeString("[FATAL] VMM mapping/unmapping self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[VMM] 4-level paging and translation primitives verified.\n");

    heap.init(4);
    if (!heap.testHeap()) {
        serial.writeString("[FATAL] Kernel heap allocator self-test failed.\n");
        cpu.haltLoop();
    }
    serial.writeString("[HEAP] Dynamic memory allocator initialized and verified.\n");

    if (comptime build_options.test_double_fault) {
        idt.runStandaloneDoubleFaultTest();
    }

    serial.writeString("[STATUS] Kernel initialization complete.\n");
    serial.writeString("\n");
    serial.writeString("zig-os:~$ ");

    cpu.haltLoop();
}
