// Global Descriptor Table (GDT) Management & Inspection
//
// Technical Note on GDT in Phase 1:
// Limine 12.9.6 sets up a 64-bit GDT prior to kernel handoff:
// - Code Segment Selector: 0x28 (Ring 0, 64-bit code)
// - Data Segment Selector: 0x30 (Ring 0, 64-bit data)
//
// In accordance with Phase 1 engineering requirements:
// "Do not reload or replace Limine's GDT without a documented technical reason."
//
// Reloading the GDT during Phase 1 is not required because all Phase 1 core
// infrastructure (PMM, VMM, IDT exceptions, and heap) operates strictly in
// 64-bit kernel supervisor mode (Ring 0) where Limine's descriptors are fully
// valid. Replacing Limine's GDT prematurely would risk segment register desynchronization.
// We dynamically query getCs() when setting up IDT gates.
// In Phase 2, a custom GDT with a Task State Segment (TSS) will be installed
// to support Ring 3 user mode transitions and dedicated Interrupt Stack Tables (IST).

pub const KERNEL_CODE_SELECTOR: u16 = 0x28;
pub const KERNEL_DATA_SELECTOR: u16 = 0x30;

pub inline fn getCs() u16 {
    return asm volatile ("mov %%cs, %[ret]"
        : [ret] "=r" (-> u16),
    );
}

pub inline fn getDs() u16 {
    return asm volatile ("mov %%ds, %[ret]"
        : [ret] "=r" (-> u16),
    );
}

pub inline fn getSs() u16 {
    return asm volatile ("mov %%ss, %[ret]"
        : [ret] "=r" (-> u16),
    );
}
