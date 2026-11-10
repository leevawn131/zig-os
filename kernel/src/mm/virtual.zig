// Virtual Memory Manager (VMM)
// 4-level x86_64 paging, page table management, and address translation
const std = @import("std");
const cpu = @import("../arch/x86_64/cpu.zig");
const pmm = @import("physical.zig");

pub const PAGE_SIZE: u64 = 4096;

pub const Flags = struct {
    pub const PRESENT: u64 = 1 << 0;
    pub const WRITABLE: u64 = 1 << 1;
    pub const USER: u64 = 1 << 2;
    pub const WRITE_THROUGH: u64 = 1 << 3;
    pub const NO_CACHE: u64 = 1 << 4;
    pub const ACCESSED: u64 = 1 << 5;
    pub const DIRTY: u64 = 1 << 6;
    pub const HUGE: u64 = 1 << 7;
    pub const GLOBAL: u64 = 1 << 8;
    pub const NO_EXECUTE: u64 = 1 << 63;
    pub const PHYS_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
};

pub const PageTable = extern struct {
    entries: [512]u64,

    pub fn clear(self: *PageTable) void {
        @memset(&self.entries, 0);
    }
};

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

pub fn getActivePml4() *PageTable {
    const cr3 = cpu.readCr3();
    const pml4_phys = cr3 & Flags.PHYS_ADDR_MASK;
    return @ptrCast(@alignCast(pmm.physToVirt(pml4_phys)));
}

pub fn mapPage(
    pml4: *PageTable,
    virt: u64,
    phys: u64,
    flags: u64,
) error{ OutOfMemory, AlreadyMapped }!void {
    const intermediate_flags = Flags.PRESENT | Flags.WRITABLE | (flags & Flags.USER);

    // Level 4: PML4 -> PDPT
    const pml4_i = pml4Index(virt);
    if ((pml4.entries[pml4_i] & Flags.PRESENT) == 0) {
        const new_table_phys = pmm.allocPage() orelse return error.OutOfMemory;
        pml4.entries[pml4_i] = new_table_phys | intermediate_flags;
    }
    const pdpt_phys = pml4.entries[pml4_i] & Flags.PHYS_ADDR_MASK;
    const pdpt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pdpt_phys)));

    // Level 3: PDPT -> PD
    const pdpt_i = pdptIndex(virt);
    if ((pdpt.entries[pdpt_i] & Flags.PRESENT) == 0) {
        const new_table_phys = pmm.allocPage() orelse return error.OutOfMemory;
        pdpt.entries[pdpt_i] = new_table_phys | intermediate_flags;
    }
    const pd_phys = pdpt.entries[pdpt_i] & Flags.PHYS_ADDR_MASK;
    const pd: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pd_phys)));

    // Level 2: PD -> PT
    const pd_i = pdIndex(virt);
    if ((pd.entries[pd_i] & Flags.PRESENT) == 0) {
        const new_table_phys = pmm.allocPage() orelse return error.OutOfMemory;
        pd.entries[pd_i] = new_table_phys | intermediate_flags;
    }
    const pt_phys = pd.entries[pd_i] & Flags.PHYS_ADDR_MASK;
    const pt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pt_phys)));

    // Level 1: PT -> Physical frame
    const pt_i = ptIndex(virt);
    if ((pt.entries[pt_i] & Flags.PRESENT) != 0) {
        return error.AlreadyMapped;
    }

    pt.entries[pt_i] = (phys & Flags.PHYS_ADDR_MASK) | flags | Flags.PRESENT;
    cpu.invlpg(virt);
}

pub fn unmapPage(pml4: *PageTable, virt: u64) error{NotMapped}!void {
    const pml4_i = pml4Index(virt);
    if ((pml4.entries[pml4_i] & Flags.PRESENT) == 0) return error.NotMapped;
    const pdpt_phys = pml4.entries[pml4_i] & Flags.PHYS_ADDR_MASK;
    const pdpt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pdpt_phys)));

    const pdpt_i = pdptIndex(virt);
    if ((pdpt.entries[pdpt_i] & Flags.PRESENT) == 0) return error.NotMapped;
    const pd_phys = pdpt.entries[pdpt_i] & Flags.PHYS_ADDR_MASK;
    const pd: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pd_phys)));

    const pd_i = pdIndex(virt);
    if ((pd.entries[pd_i] & Flags.PRESENT) == 0) return error.NotMapped;
    const pt_phys = pd.entries[pd_i] & Flags.PHYS_ADDR_MASK;
    const pt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pt_phys)));

    const pt_i = ptIndex(virt);
    if ((pt.entries[pt_i] & Flags.PRESENT) == 0) return error.NotMapped;

    pt.entries[pt_i] = 0;
    cpu.invlpg(virt);
}

pub fn virtToPhys(pml4: *PageTable, virt: u64) ?u64 {
    const pml4_i = pml4Index(virt);
    if ((pml4.entries[pml4_i] & Flags.PRESENT) == 0) return null;
    const pdpt_phys = pml4.entries[pml4_i] & Flags.PHYS_ADDR_MASK;
    const pdpt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pdpt_phys)));

    const pdpt_i = pdptIndex(virt);
    if ((pdpt.entries[pdpt_i] & Flags.PRESENT) == 0) return null;
    if ((pdpt.entries[pdpt_i] & Flags.HUGE) != 0) {
        // 1 GiB Huge Page
        const base = pdpt.entries[pdpt_i] & 0x000F_FFFF_C000_0000;
        return base + (virt & 0x3FFF_FFFF);
    }
    const pd_phys = pdpt.entries[pdpt_i] & Flags.PHYS_ADDR_MASK;
    const pd: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pd_phys)));

    const pd_i = pdIndex(virt);
    if ((pd.entries[pd_i] & Flags.PRESENT) == 0) return null;
    if ((pd.entries[pd_i] & Flags.HUGE) != 0) {
        // 2 MiB Huge Page
        const base = pd.entries[pd_i] & 0x000F_FFFF_FFE0_0000;
        return base + (virt & 0x1F_FFFF);
    }
    const pt_phys = pd.entries[pd_i] & Flags.PHYS_ADDR_MASK;
    const pt: *PageTable = @ptrCast(@alignCast(pmm.physToVirt(pt_phys)));

    const pt_i = ptIndex(virt);
    if ((pt.entries[pt_i] & Flags.PRESENT) == 0) return null;

    const base = pt.entries[pt_i] & Flags.PHYS_ADDR_MASK;
    return base + (virt & 0xFFF);
}

pub fn isMapped(pml4: *PageTable, virt: u64) bool {
    return virtToPhys(pml4, virt) != null;
}

pub fn testVmm() bool {
    const pml4 = getActivePml4();

    // Choose an unmapped test virtual address in lower half
    const test_vaddr: u64 = 0x0000_0042_0000_0000;

    if (isMapped(pml4, test_vaddr)) return false;

    // Allocate a physical frame via PMM
    const phys_frame = pmm.allocPage() orelse return false;

    // Map test_vaddr -> phys_frame
    mapPage(pml4, test_vaddr, phys_frame, Flags.WRITABLE) catch return false;

    // Verify mapping
    const resolved_phys = virtToPhys(pml4, test_vaddr) orelse return false;
    if (resolved_phys != phys_frame) return false;

    // Write data through the newly mapped virtual address
    const test_ptr: *volatile u64 = @ptrFromInt(test_vaddr);
    test_ptr.* = 0x12345678_ABCDEF01;

    // Verify data reached physical frame via HHDM
    const hhdm_ptr: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(phys_frame)));
    if (hhdm_ptr.* != 0x12345678_ABCDEF01) return false;

    // Unmap the page
    unmapPage(pml4, test_vaddr) catch return false;

    // Verify unmapped
    if (isMapped(pml4, test_vaddr)) return false;

    // Free frame back to PMM
    pmm.freePage(phys_frame);

    return true;
}
