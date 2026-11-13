// Stateful Virtual Memory Manager (VMM) Core
// Hardware-independent 4-level x86_64 page-table allocator, mapper, and translator
// shared between the freestanding kernel and host unit tests.

const paging_math = @import("paging_math.zig");

pub const math = paging_math;
pub const PAGE_SIZE: u64 = paging_math.PAGE_SIZE;

pub const pml4Index = paging_math.pml4Index;
pub const pdptIndex = paging_math.pdptIndex;
pub const pdIndex = paging_math.pdIndex;
pub const ptIndex = paging_math.ptIndex;
pub const pageOffset = paging_math.pageOffset;

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
    pub const HUGE_2MIB_ADDR_MASK: u64 = 0x000F_FFFF_FFE0_0000;
    pub const HUGE_1GIB_ADDR_MASK: u64 = 0x000F_FFFF_C000_0000;

    pub const PAGE_OFFSET_MASK: u64 = 0xFFF;
    pub const HUGE_2MIB_OFFSET_MASK: u64 = 0x1F_FFFF;
    pub const HUGE_1GIB_OFFSET_MASK: u64 = 0x3FFF_FFFF;
};

pub const PageTable = extern struct {
    entries: [512]u64 align(PAGE_SIZE) = @splat(0),

    pub fn clear(self: *PageTable) void {
        @memset(&self.entries, 0);
    }
};

pub const MapError = error{
    OutOfMemory,
    AlreadyMapped,
    HugePageConflict,
    NonCanonicalAddress,
    UnalignedVirtualAddress,
    UnalignedPhysicalAddress,
    InvalidPhysicalAddress,
};

pub const UnmapError = error{
    NotMapped,
    HugePageConflict,
    NonCanonicalAddress,
    UnalignedVirtualAddress,
};

/// Minimal VMM hardware/host abstraction callbacks.
/// Production binds these to HHDM resolution, PMM alloc/free, and `cpu.invlpg`.
pub const Backend = struct {
    ctx: ?*anyopaque = null,
    resolveTableFn: *const fn (ctx: ?*anyopaque, table_phys: u64) *PageTable,
    allocTableFn: *const fn (ctx: ?*anyopaque) ?u64,
    freeTableFn: *const fn (ctx: ?*anyopaque, table_phys: u64) void,
    invlpgFn: *const fn (ctx: ?*anyopaque, virt: u64) void,

    pub inline fn resolveTable(self: Backend, table_phys: u64) *PageTable {
        return self.resolveTableFn(self.ctx, table_phys);
    }

    pub inline fn allocTable(self: Backend) ?u64 {
        return self.allocTableFn(self.ctx);
    }

    pub inline fn freeTable(self: Backend, table_phys: u64) void {
        self.freeTableFn(self.ctx, table_phys);
    }

    pub inline fn invlpg(self: Backend, virt: u64) void {
        self.invlpgFn(self.ctx, virt);
    }
};

/// Validates 4-level x86_64 canonicality: bits 48..63 must sign-extend bit 47.
pub inline fn isCanonical(virt: u64) bool {
    const signed: i64 = @bitCast(virt);
    const high_bits = signed >> 47;
    return high_bits == 0 or high_bits == -1;
}

fn validateVirtualPage(virt: u64) error{ NonCanonicalAddress, UnalignedVirtualAddress }!void {
    if (!isCanonical(virt)) {
        return error.NonCanonicalAddress;
    }
    if ((virt & Flags.PAGE_OFFSET_MASK) != 0) {
        return error.UnalignedVirtualAddress;
    }
}

fn allocAndClearTable(backend: Backend) MapError!struct { phys: u64, table: *PageTable } {
    const alloc_phys = backend.allocTable() orelse return error.OutOfMemory;
    const table = backend.resolveTable(alloc_phys);
    table.clear();
    return .{ .phys = alloc_phys, .table = table };
}

fn linkOrPromoteUser(entry: *u64, new_child_phys: ?u64, intermediate_flags: u64, propagate_user: bool) void {
    if (new_child_phys) |child_phys| {
        entry.* = (child_phys & Flags.PHYS_ADDR_MASK) | intermediate_flags;
    } else if (propagate_user) {
        entry.* |= Flags.USER;
    }
}

/// Maps a 4 KiB page (`virt` -> `phys`) in `pml4`, allocating missing intermediate tables.
/// Validates canonicality, alignment, huge-page conflicts, and duplicates before any mutation.
pub fn mapPage(
    backend: Backend,
    pml4: *PageTable,
    virt: u64,
    phys: u64,
    flags: u64,
) MapError!void {
    try validateVirtualPage(virt);
    if ((phys & Flags.PAGE_OFFSET_MASK) != 0) {
        return error.UnalignedPhysicalAddress;
    }
    if ((phys & ~Flags.PHYS_ADDR_MASK) != 0) {
        return error.InvalidPhysicalAddress;
    }

    const pml4_i = paging_math.pml4Index(virt);
    const pdpt_i = paging_math.pdptIndex(virt);
    const pd_i = paging_math.pdIndex(virt);
    const pt_i = paging_math.ptIndex(virt);

    var existing_pdpt: ?*PageTable = null;
    var existing_pd: ?*PageTable = null;
    var existing_pt: ?*PageTable = null;

    // Traverse existing hierarchy strictly read-only so rejected operations never mutate entries.
    if ((pml4.entries[pml4_i] & Flags.PRESENT) != 0) {
        const pdpt = backend.resolveTable(pml4.entries[pml4_i] & Flags.PHYS_ADDR_MASK);
        existing_pdpt = pdpt;

        const pdpte = pdpt.entries[pdpt_i];
        if ((pdpte & Flags.PRESENT) != 0) {
            if ((pdpte & Flags.HUGE) != 0) {
                return error.HugePageConflict;
            }
            const pd = backend.resolveTable(pdpte & Flags.PHYS_ADDR_MASK);
            existing_pd = pd;

            const pde = pd.entries[pd_i];
            if ((pde & Flags.PRESENT) != 0) {
                if ((pde & Flags.HUGE) != 0) {
                    return error.HugePageConflict;
                }
                const pt = backend.resolveTable(pde & Flags.PHYS_ADDR_MASK);
                existing_pt = pt;

                if ((pt.entries[pt_i] & Flags.PRESENT) != 0) {
                    return error.AlreadyMapped;
                }
            }
        }
    }

    var new_pdpt_phys: ?u64 = null;
    errdefer if (new_pdpt_phys) |p| backend.freeTable(p);
    var pdpt: *PageTable = undefined;
    if (existing_pdpt) |tbl| {
        pdpt = tbl;
    } else {
        const created = try allocAndClearTable(backend);
        new_pdpt_phys = created.phys;
        pdpt = created.table;
    }

    var new_pd_phys: ?u64 = null;
    errdefer if (new_pd_phys) |p| backend.freeTable(p);
    var pd: *PageTable = undefined;
    if (existing_pd) |tbl| {
        pd = tbl;
    } else {
        const created = try allocAndClearTable(backend);
        new_pd_phys = created.phys;
        pd = created.table;
    }

    var new_pt_phys: ?u64 = null;
    errdefer if (new_pt_phys) |p| backend.freeTable(p);
    var pt: *PageTable = undefined;
    if (existing_pt) |tbl| {
        pt = tbl;
    } else {
        const created = try allocAndClearTable(backend);
        new_pt_phys = created.phys;
        pt = created.table;
    }

    const propagate_user = (flags & Flags.USER) != 0;
    const intermediate_flags = Flags.PRESENT | Flags.WRITABLE | (flags & Flags.USER);

    // Commit leaf first, then publish newly cleared tables and promote USER along existing parents.
    pt.entries[pt_i] = phys | flags | Flags.PRESENT;
    linkOrPromoteUser(&pd.entries[pd_i], new_pt_phys, intermediate_flags, propagate_user);
    linkOrPromoteUser(&pdpt.entries[pdpt_i], new_pd_phys, intermediate_flags, propagate_user);
    linkOrPromoteUser(&pml4.entries[pml4_i], new_pdpt_phys, intermediate_flags, propagate_user);

    backend.invlpg(virt);
}

/// Unmaps a 4 KiB page leaf (`virt`) from `pml4` without freeing the backing physical frame
/// or automatically reclaiming empty intermediate page tables.
pub fn unmapPage(backend: Backend, pml4: *PageTable, virt: u64) UnmapError!void {
    try validateVirtualPage(virt);

    const pml4_i = paging_math.pml4Index(virt);
    const pml4e = pml4.entries[pml4_i];
    if ((pml4e & Flags.PRESENT) == 0) return error.NotMapped;
    const pdpt = backend.resolveTable(pml4e & Flags.PHYS_ADDR_MASK);

    const pdpt_i = paging_math.pdptIndex(virt);
    const pdpte = pdpt.entries[pdpt_i];
    if ((pdpte & Flags.PRESENT) == 0) return error.NotMapped;
    if ((pdpte & Flags.HUGE) != 0) return error.HugePageConflict;
    const pd = backend.resolveTable(pdpte & Flags.PHYS_ADDR_MASK);

    const pd_i = paging_math.pdIndex(virt);
    const pde = pd.entries[pd_i];
    if ((pde & Flags.PRESENT) == 0) return error.NotMapped;
    if ((pde & Flags.HUGE) != 0) return error.HugePageConflict;
    const pt = backend.resolveTable(pde & Flags.PHYS_ADDR_MASK);

    const pt_i = paging_math.ptIndex(virt);
    if ((pt.entries[pt_i] & Flags.PRESENT) == 0) return error.NotMapped;

    pt.entries[pt_i] = 0;
    backend.invlpg(virt);
}

/// Translates `virt` in `pml4` across 4 KiB pages and 1 GiB / 2 MiB huge pages.
/// Rejects non-canonical addresses without traversing page tables.
pub fn virtToPhys(backend: Backend, pml4: *PageTable, virt: u64) ?u64 {
    if (!isCanonical(virt)) return null;

    const pml4_i = paging_math.pml4Index(virt);
    const pml4e = pml4.entries[pml4_i];
    if ((pml4e & Flags.PRESENT) == 0) return null;
    const pdpt = backend.resolveTable(pml4e & Flags.PHYS_ADDR_MASK);

    const pdpt_i = paging_math.pdptIndex(virt);
    const pdpte = pdpt.entries[pdpt_i];
    if ((pdpte & Flags.PRESENT) == 0) return null;
    if ((pdpte & Flags.HUGE) != 0) {
        const base = pdpte & Flags.HUGE_1GIB_ADDR_MASK;
        return base + (virt & Flags.HUGE_1GIB_OFFSET_MASK);
    }
    const pd = backend.resolveTable(pdpte & Flags.PHYS_ADDR_MASK);

    const pd_i = paging_math.pdIndex(virt);
    const pde = pd.entries[pd_i];
    if ((pde & Flags.PRESENT) == 0) return null;
    if ((pde & Flags.HUGE) != 0) {
        const base = pde & Flags.HUGE_2MIB_ADDR_MASK;
        return base + (virt & Flags.HUGE_2MIB_OFFSET_MASK);
    }
    const pt = backend.resolveTable(pde & Flags.PHYS_ADDR_MASK);

    const pt_i = paging_math.ptIndex(virt);
    const pte = pt.entries[pt_i];
    if ((pte & Flags.PRESENT) == 0) return null;

    const base = pte & Flags.PHYS_ADDR_MASK;
    return base + paging_math.pageOffset(virt);
}

pub fn isMapped(backend: Backend, pml4: *PageTable, virt: u64) bool {
    return virtToPhys(backend, pml4, virt) != null;
}
