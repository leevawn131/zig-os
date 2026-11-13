// Low-level x86_64 CPU instructions, control registers, and port I/O

pub const sse = @import("sse.zig");

pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub inline fn ioWait() void {
    // Port 0x80 is traditionally used for POST codes and safe I/O delay
    outb(0x80, 0);
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub fn haltLoop() noreturn {
    cli();
    while (true) {
        hlt();
    }
}

pub inline fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeCr0(val: u64) void {
    asm volatile ("mov %[val], %%cr0"
        :
        : [val] "r" (val),
    );
}

pub inline fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeCr3(val: u64) void {
    asm volatile ("mov %[val], %%cr3"
        :
        : [val] "r" (val),
    );
}

pub inline fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeCr4(val: u64) void {
    asm volatile ("mov %[val], %%cr4"
        :
        : [val] "r" (val),
    );
}

/// Initialize x86_64 FPU/SSE support by clearing CR0.EM (bit 2) and CR0.TS (bit 3),
/// setting CR0.MP (bit 1), and setting CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10).
pub inline fn enableSse() void {
    // Clear CR0.EM (bit 2) and CR0.TS (bit 3), set CR0.MP (bit 1)
    writeCr0(sse.computeSseCr0(readCr0()));

    // Set CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10)
    writeCr4(sse.computeSseCr4(readCr4()));
}

/// Ring 0 regression test verifying enableSse() clears CR0.TS and CR0.EM while
/// setting CR0.MP, CR4.OSFXSR, and CR4.OSXMMEXCPT and preserving unrelated control bits.
pub fn testSseCr0Init() bool {
    const boot_cr0 = readCr0();
    const boot_cr4 = readCr4();
    if (!sse.isSseCr0Valid(boot_cr0) or !sse.isSseCr4Valid(boot_cr4)) {
        return false;
    }

    const saved_rflags = readRflags();
    const was_if_set = (saved_rflags & (@as(u64, 1) << 9)) != 0;
    cli();

    // Confirm maskable interrupts are disabled before mutating CR0
    if ((readRflags() & (@as(u64, 1) << 9)) != 0) {
        return false;
    }

    // Deliberately set CR0.TS=1 and CR0.EM=1 immediately before calling enableSse()
    // with zero intervening FPU/SSE instructions.
    const baseline_cr0 = readCr0();
    const baseline_cr4 = readCr4();
    writeCr0(baseline_cr0 | sse.CR0_EM_BIT | sse.CR0_TS_BIT);
    enableSse();

    const actual_cr0 = readCr0();
    const actual_cr4 = readCr4();

    if (was_if_set) {
        sti();
    }

    const cr0_preserved_mask: u64 = ~(sse.CR0_MP_BIT | sse.CR0_EM_BIT | sse.CR0_TS_BIT);
    const cr4_preserved_mask: u64 = ~(sse.CR4_OSFXSR_BIT | sse.CR4_OSXMMEXCPT_BIT);
    const cr0_preserved_ok = (actual_cr0 & cr0_preserved_mask) == (baseline_cr0 & cr0_preserved_mask);
    const cr4_preserved_ok = (actual_cr4 & cr4_preserved_mask) == (baseline_cr4 & cr4_preserved_mask);

    return sse.isSseCr0Valid(actual_cr0) and
        sse.isSseCr4Valid(actual_cr4) and
        cr0_preserved_ok and
        cr4_preserved_ok;
}

pub inline fn readRflags() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[ret]
        : [ret] "=r" (-> u64),
    );
}

pub inline fn invlpg(vaddr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (vaddr),
    );
}

pub inline fn lidt(desc_ptr: *const anyopaque) void {
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (desc_ptr),
    );
}
