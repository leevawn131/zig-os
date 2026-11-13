// Virtual Memory Manager (VMM) Kernel Adapter
// Binds x86_64 CR3, HHDM table resolution, PMM table allocation, and `cpu.invlpg`
// to the shared hardware-independent VMM core.
const cpu = @import("../arch/x86_64/cpu.zig");
const pmm = @import("physical.zig");
const virtual_core = @import("virtual_core.zig");

pub const PAGE_SIZE: u64 = virtual_core.PAGE_SIZE;

pub const pml4Index = virtual_core.pml4Index;
pub const pdptIndex = virtual_core.pdptIndex;
pub const pdIndex = virtual_core.pdIndex;
pub const ptIndex = virtual_core.ptIndex;
pub const pageOffset = virtual_core.pageOffset;
pub const isCanonical = virtual_core.isCanonical;

pub const Flags = virtual_core.Flags;
pub const PageTable = virtual_core.PageTable;
pub const MapError = virtual_core.MapError;
pub const UnmapError = virtual_core.UnmapError;

fn kernelResolveTable(_: ?*anyopaque, table_phys: u64) *PageTable {
    return @ptrCast(@alignCast(pmm.physToVirt(table_phys)));
}

fn kernelAllocTable(_: ?*anyopaque) ?u64 {
    return pmm.allocPage();
}

fn kernelFreeTable(_: ?*anyopaque, table_phys: u64) void {
    pmm.freePage(table_phys);
}

fn kernelInvlpg(_: ?*anyopaque, virt: u64) void {
    cpu.invlpg(virt);
}

const kernel_backend: virtual_core.Backend = .{
    .ctx = null,
    .resolveTableFn = kernelResolveTable,
    .allocTableFn = kernelAllocTable,
    .freeTableFn = kernelFreeTable,
    .invlpgFn = kernelInvlpg,
};

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
) MapError!void {
    return virtual_core.mapPage(kernel_backend, pml4, virt, phys, flags);
}

pub fn unmapPage(pml4: *PageTable, virt: u64) UnmapError!void {
    return virtual_core.unmapPage(kernel_backend, pml4, virt);
}

pub fn virtToPhys(pml4: *PageTable, virt: u64) ?u64 {
    return virtual_core.virtToPhys(kernel_backend, pml4, virt);
}

pub fn isMapped(pml4: *PageTable, virt: u64) bool {
    return virtual_core.isMapped(kernel_backend, pml4, virt);
}

pub fn testVmm() bool {
    const pml4 = getActivePml4();

    // Choose an unmapped test virtual address in lower half
    const test_vaddr: u64 = 0x0000_0042_0000_0000;
    const non_canonical_vaddr: u64 = 0x0001_0000_0000_0000;

    if (isMapped(pml4, test_vaddr)) return false;
    if (isMapped(pml4, non_canonical_vaddr)) return false;
    if (virtToPhys(pml4, non_canonical_vaddr) != null) return false;

    if (unmapPage(pml4, non_canonical_vaddr)) |_| {
        return false;
    } else |err| {
        if (err != error.NonCanonicalAddress) return false;
    }

    if (unmapPage(pml4, test_vaddr + 1)) |_| {
        return false;
    } else |err| {
        if (err != error.UnalignedVirtualAddress) return false;
    }

    // Allocate a physical frame via PMM
    const phys_frame = pmm.allocPage() orelse return false;

    if (mapPage(pml4, non_canonical_vaddr, phys_frame, Flags.WRITABLE)) |_| {
        pmm.freePage(phys_frame);
        return false;
    } else |err| {
        if (err != error.NonCanonicalAddress) {
            pmm.freePage(phys_frame);
            return false;
        }
    }

    if (mapPage(pml4, test_vaddr + 1, phys_frame, Flags.WRITABLE)) |_| {
        pmm.freePage(phys_frame);
        return false;
    } else |err| {
        if (err != error.UnalignedVirtualAddress) {
            pmm.freePage(phys_frame);
            return false;
        }
    }

    if (mapPage(pml4, test_vaddr, phys_frame + 1, Flags.WRITABLE)) |_| {
        pmm.freePage(phys_frame);
        return false;
    } else |err| {
        if (err != error.UnalignedPhysicalAddress) {
            pmm.freePage(phys_frame);
            return false;
        }
    }

    // Map test_vaddr -> phys_frame
    mapPage(pml4, test_vaddr, phys_frame, Flags.WRITABLE) catch {
        pmm.freePage(phys_frame);
        return false;
    };

    // Verify mapping
    const resolved_phys = virtToPhys(pml4, test_vaddr) orelse {
        pmm.freePage(phys_frame);
        return false;
    };
    if (resolved_phys != phys_frame) {
        pmm.freePage(phys_frame);
        return false;
    }

    // Write data through the newly mapped virtual address
    const test_ptr: *volatile u64 = @ptrFromInt(test_vaddr);
    test_ptr.* = 0x12345678_ABCDEF01;

    // Verify data reached physical frame via HHDM
    const hhdm_ptr: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(phys_frame)));
    if (hhdm_ptr.* != 0x12345678_ABCDEF01) {
        pmm.freePage(phys_frame);
        return false;
    }

    // Unmap the page
    unmapPage(pml4, test_vaddr) catch {
        pmm.freePage(phys_frame);
        return false;
    };

    // Verify unmapped
    if (isMapped(pml4, test_vaddr)) {
        pmm.freePage(phys_frame);
        return false;
    }

    // Free frame back to PMM
    pmm.freePage(phys_frame);

    return true;
}
