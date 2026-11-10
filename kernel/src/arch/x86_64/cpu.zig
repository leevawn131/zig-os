// Low-level x86_64 CPU instructions, control registers, and port I/O

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

pub inline fn enableSse() void {
    // Clear CR0.EM (bit 2), set CR0.MP (bit 1)
    var cr0 = readCr0();
    cr0 &= ~@as(u64, 1 << 2);
    cr0 |= (1 << 1);
    writeCr0(cr0);

    // Set CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10)
    var cr4 = readCr4();
    cr4 |= (1 << 9);
    cr4 |= (1 << 10);
    writeCr4(cr4);
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
