// Pure 4-level x86_64 paging address decomposition mathematics
// Hardware-independent pure logic module shared between kernel and host unit tests.

pub const PAGE_SIZE: u64 = 4096;

pub inline fn pml4Index(virt: u64) usize {
    return @intCast((virt >> 39) & 0x1FF);
}

pub inline fn pdptIndex(virt: u64) usize {
    return @intCast((virt >> 30) & 0x1FF);
}

pub inline fn pdIndex(virt: u64) usize {
    return @intCast((virt >> 21) & 0x1FF);
}

pub inline fn ptIndex(virt: u64) usize {
    return @intCast((virt >> 12) & 0x1FF);
}

pub inline fn pageOffset(virt: u64) usize {
    return @intCast(virt & 0xFFF);
}
