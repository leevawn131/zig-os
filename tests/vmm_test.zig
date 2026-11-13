// Host-side Unit Tests for Stateful Virtual Memory Manager (VMM) Core
// Exercises the exact production `virtual_core` implementation shared with `kernel/src/mm/virtual.zig`.

const std = @import("std");
const testing = std.testing;

const vmm = @import("virtual_core");

const PAGE_SIZE = vmm.PAGE_SIZE;
const Flags = vmm.Flags;
const PageTable = vmm.PageTable;
const Backend = vmm.Backend;

const FakeVmmBackend = struct {
    const SlotState = enum {
        free_poisoned,
        allocated,
        seeded_table,
    };

    const MAX_LOG = 128;

    allocator: std.mem.Allocator,
    pool_base_phys: u64 = 0x0010_0000,
    pool: []PageTable,
    states: []SlotState,
    resolve_counts: []usize,
    trap_table: PageTable = .{},

    fail_after_allocs: ?usize = null,
    alloc_attempts: usize = 0,
    alloc_successes: usize = 0,
    alloc_failures: usize = 0,
    free_calls: usize = 0,
    live_allocations: usize = 0,
    resolve_calls: usize = 0,
    reuse_resolve_calls: usize = 0,

    unexpected_resolve: bool = false,
    last_unexpected_resolve_phys: u64 = 0,
    invalid_free: bool = false,
    last_invalid_free_phys: u64 = 0,

    allocated_count: usize = 0,
    allocated_frames: [MAX_LOG]u64 = @splat(0),
    freed_count: usize = 0,
    freed_frames: [MAX_LOG]u64 = @splat(0),

    invlpg_calls: usize = 0,
    invlpg_addrs: [MAX_LOG]u64 = @splat(0),

    const Self = @This();

    fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        const pool = try allocator.alloc(PageTable, capacity);
        errdefer allocator.free(pool);

        const states = try allocator.alloc(SlotState, capacity);
        errdefer allocator.free(states);

        const resolve_counts = try allocator.alloc(usize, capacity);
        @memset(resolve_counts, 0);
        @memset(states, .free_poisoned);
        for (pool) |*tbl| {
            // Bit 0 (PRESENT) and bit 7 (HUGE) are both 1 in 0xA5 so missing `.clear()` breaks fast.
            @memset(&tbl.entries, 0xA5A5_A5A5_A5A5_A5A5);
        }

        return .{
            .allocator = allocator,
            .pool = pool,
            .states = states,
            .resolve_counts = resolve_counts,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.resolve_counts);
        self.allocator.free(self.states);
        self.allocator.free(self.pool);
    }

    fn backend(self: *Self) Backend {
        return .{
            .ctx = self,
            .resolveTableFn = resolveTableFn,
            .allocTableFn = allocTableFn,
            .freeTableFn = freeTableFn,
            .invlpgFn = invlpgFn,
        };
    }

    fn slotPhys(self: *const Self, idx: usize) u64 {
        return self.pool_base_phys + @as(u64, @intCast(idx)) * PAGE_SIZE;
    }

    fn physToIndex(self: *const Self, phys: u64) ?usize {
        if (phys < self.pool_base_phys) return null;
        const offset = phys - self.pool_base_phys;
        if (offset % PAGE_SIZE != 0) return null;
        const idx: usize = @intCast(offset / PAGE_SIZE);
        if (idx >= self.pool.len) return null;
        return idx;
    }

    /// Reserves and zeroes a pool slot directly for synthetic pre-existing / huge-page tests.
    fn allocSeededTable(self: *Self) !u64 {
        for (self.states, 0..) |st, idx| {
            if (st == .free_poisoned) {
                self.states[idx] = .seeded_table;
                self.pool[idx].clear();
                return self.slotPhys(idx);
            }
        }
        return error.OutOfPoolCapacity;
    }

    /// Inspects a mapped/allocated pool table without altering production `resolve_calls` counters.
    fn peekTable(self: *const Self, table_phys: u64) !*const PageTable {
        const idx = self.physToIndex(table_phys) orelse return error.InvalidTestTablePhys;
        if (self.states[idx] == .free_poisoned) return error.TableNotAllocated;
        return &self.pool[idx];
    }

    fn peekTableMut(self: *Self, table_phys: u64) !*PageTable {
        const idx = self.physToIndex(table_phys) orelse return error.InvalidTestTablePhys;
        if (self.states[idx] == .free_poisoned) return error.TableNotAllocated;
        return &self.pool[idx];
    }

    fn resolveTableFn(ctx: ?*anyopaque, table_phys: u64) *PageTable {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.resolve_calls += 1;

        if (self.physToIndex(table_phys)) |idx| {
            if (self.states[idx] == .allocated or self.states[idx] == .seeded_table) {
                if (self.resolve_counts[idx] > 0) {
                    self.reuse_resolve_calls += 1;
                }
                self.resolve_counts[idx] += 1;
                return &self.pool[idx];
            }
        }

        self.unexpected_resolve = true;
        self.last_unexpected_resolve_phys = table_phys;
        self.trap_table.clear();
        return &self.trap_table;
    }

    fn allocTableFn(ctx: ?*anyopaque) ?u64 {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.alloc_attempts += 1;

        if (self.fail_after_allocs) |limit| {
            if (self.alloc_successes >= limit) {
                self.alloc_failures += 1;
                return null;
            }
        }

        for (self.states, 0..) |st, idx| {
            if (st == .free_poisoned) {
                self.states[idx] = .allocated;
                self.resolve_counts[idx] = 0;
                const phys = self.slotPhys(idx);
                if (self.allocated_count < MAX_LOG) {
                    self.allocated_frames[self.allocated_count] = phys;
                }
                self.allocated_count += 1;
                self.alloc_successes += 1;
                self.live_allocations += 1;
                return phys;
            }
        }

        self.alloc_failures += 1;
        return null;
    }

    fn freeTableFn(ctx: ?*anyopaque, table_phys: u64) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.free_calls += 1;

        if (self.physToIndex(table_phys)) |idx| {
            if (self.states[idx] == .allocated) {
                self.states[idx] = .free_poisoned;
                @memset(&self.pool[idx].entries, 0xA5A5_A5A5_A5A5_A5A5);
                if (self.freed_count < MAX_LOG) {
                    self.freed_frames[self.freed_count] = table_phys;
                }
                self.freed_count += 1;
                self.live_allocations -= 1;
                return;
            }
        }

        self.invalid_free = true;
        self.last_invalid_free_phys = table_phys;
    }

    fn invlpgFn(ctx: ?*anyopaque, virt: u64) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (self.invlpg_calls < MAX_LOG) {
            self.invlpg_addrs[self.invlpg_calls] = virt;
        }
        self.invlpg_calls += 1;
    }

    fn resetCounters(self: *Self) void {
        self.fail_after_allocs = null;
        self.alloc_attempts = 0;
        self.alloc_successes = 0;
        self.alloc_failures = 0;
        self.free_calls = 0;
        self.resolve_calls = 0;
        self.reuse_resolve_calls = 0;
        self.invlpg_calls = 0;
        self.allocated_count = 0;
        self.freed_count = 0;
    }

    fn assertClean(self: *const Self) !void {
        try testing.expect(!self.unexpected_resolve);
        try testing.expect(!self.invalid_free);
    }
};

fn expectTableClearedExcept(tbl: *const PageTable, keep_index: usize) !void {
    for (tbl.entries, 0..) |entry, i| {
        if (i == keep_index) {
            try testing.expect((entry & Flags.PRESENT) != 0);
        } else {
            try testing.expectEqual(@as(u64, 0), entry);
        }
    }
}

test "VMM A: basic 4 KiB mapping installs hierarchy entries, clears poison, translates, and invalidates TLB" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const virt: u64 = 0x0000_0042_1234_5000;
    const data_phys: u64 = 0x0000_0000_2000_7000; // Outside page-table pool
    const req_flags = Flags.WRITABLE | Flags.NO_EXECUTE;

    try vmm.mapPage(fake.backend(), &pml4, virt, data_phys, req_flags);
    try fake.assertClean();

    try testing.expectEqual(@as(usize, 3), fake.alloc_successes);
    try testing.expectEqual(@as(usize, 3), fake.live_allocations);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 1), fake.invlpg_calls);
    try testing.expectEqual(virt, fake.invlpg_addrs[0]);

    const pml4_i = vmm.pml4Index(virt);
    const pdpt_i = vmm.pdptIndex(virt);
    const pd_i = vmm.pdIndex(virt);
    const pt_i = vmm.ptIndex(virt);

    const pml4e = pml4.entries[pml4_i];
    try testing.expectEqual(Flags.PRESENT | Flags.WRITABLE, pml4e & ~Flags.PHYS_ADDR_MASK);
    try testing.expect((pml4e & Flags.USER) == 0);

    const pdpt = try fake.peekTable(pml4e & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pdpt, pdpt_i);
    const pdpte = pdpt.entries[pdpt_i];
    try testing.expectEqual(Flags.PRESENT | Flags.WRITABLE, pdpte & ~Flags.PHYS_ADDR_MASK);

    const pd = try fake.peekTable(pdpte & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pd, pd_i);
    const pde = pd.entries[pd_i];
    try testing.expectEqual(Flags.PRESENT | Flags.WRITABLE, pde & ~Flags.PHYS_ADDR_MASK);

    const pt = try fake.peekTable(pde & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pt, pt_i);
    try testing.expectEqual(data_phys | req_flags | Flags.PRESENT, pt.entries[pt_i]);

    try testing.expect(vmm.isMapped(fake.backend(), &pml4, virt));
    try testing.expectEqual(@as(?u64, data_phys), vmm.virtToPhys(fake.backend(), &pml4, virt));
    try testing.expectEqual(@as(usize, 1), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM B: address translation preserves offsets across 4 KiB pages and isMapped matches virtToPhys" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const base_v1: u64 = 0x0000_0010_0020_3000;
    const base_p1: u64 = 0x0000_0000_5500_4000;
    const base_v2: u64 = 0xffff_9000_0000_0000;
    const base_p2: u64 = 0x0000_0000_6600_8000;

    try vmm.mapPage(fake.backend(), &pml4, base_v1, base_p1, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, base_v2, base_p2, Flags.WRITABLE | Flags.NO_EXECUTE);

    fake.resetCounters();

    const offsets = [_]u64{ 0x0, 0x1, 0x123, 0x800, 0xFFF };
    for (offsets) |off| {
        try testing.expectEqual(@as(?u64, base_p1 + off), vmm.virtToPhys(fake.backend(), &pml4, base_v1 + off));
        try testing.expect(vmm.isMapped(fake.backend(), &pml4, base_v1 + off));

        try testing.expectEqual(@as(?u64, base_p2 + off), vmm.virtToPhys(fake.backend(), &pml4, base_v2 + off));
        try testing.expect(vmm.isMapped(fake.backend(), &pml4, base_v2 + off));
    }

    try testing.expectEqual(@as(?u64, null), vmm.virtToPhys(fake.backend(), &pml4, base_v1 + PAGE_SIZE));
    try testing.expect(!vmm.isMapped(fake.backend(), &pml4, base_v1 + PAGE_SIZE));
    try testing.expectEqual(@as(usize, 0), fake.alloc_attempts);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM C: remapping an existing 4 KiB page returns AlreadyMapped without mutation or invalidation" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const virt: u64 = 0x0000_0040_0000_0000;
    const orig_phys: u64 = 0x0000_0000_2100_0000;
    const alt_phys: u64 = 0x0000_0000_2200_0000;

    try vmm.mapPage(fake.backend(), &pml4, virt, orig_phys, Flags.WRITABLE);

    const pml4_i = vmm.pml4Index(virt);
    const pdpt_i = vmm.pdptIndex(virt);
    const pd_i = vmm.pdIndex(virt);
    const pt_i = vmm.ptIndex(virt);
    const pml4_before = pml4.entries[pml4_i];
    const pdpt = try fake.peekTable(pml4_before & Flags.PHYS_ADDR_MASK);
    const pdpt_before = pdpt.entries[pdpt_i];
    const pd = try fake.peekTable(pdpt_before & Flags.PHYS_ADDR_MASK);
    const pd_before = pd.entries[pd_i];
    const pt = try fake.peekTable(pd_before & Flags.PHYS_ADDR_MASK);
    const pt_before = pt.entries[pt_i];

    fake.resetCounters();

    // Even when requesting Flags.USER, AlreadyMapped must reject before propagating parent flags.
    try testing.expectError(
        error.AlreadyMapped,
        vmm.mapPage(fake.backend(), &pml4, virt, alt_phys, Flags.WRITABLE | Flags.USER),
    );

    try testing.expectEqual(pml4_before, pml4.entries[pml4_i]);
    try testing.expectEqual(pdpt_before, pdpt.entries[pdpt_i]);
    try testing.expectEqual(pd_before, pd.entries[pd_i]);
    try testing.expectEqual(pt_before, pt.entries[pt_i]);
    try testing.expectEqual(@as(?u64, orig_phys), vmm.virtToPhys(fake.backend(), &pml4, virt));
    try testing.expectEqual(@as(usize, 0), fake.alloc_attempts);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM D: unmapping clears leaf, keeps intermediate tables and data frame, and rejects repeat unmap" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const virt: u64 = 0x0000_0042_0000_5000;
    const data_phys: u64 = 0x0000_0000_3300_0000;

    try vmm.mapPage(fake.backend(), &pml4, virt, data_phys, Flags.WRITABLE);
    fake.resetCounters();

    try vmm.unmapPage(fake.backend(), &pml4, virt);
    try testing.expect(!vmm.isMapped(fake.backend(), &pml4, virt));
    try testing.expectEqual(@as(?u64, null), vmm.virtToPhys(fake.backend(), &pml4, virt));

    try testing.expectEqual(@as(usize, 1), fake.invlpg_calls);
    try testing.expectEqual(virt, fake.invlpg_addrs[0]);
    // Data frame and empty intermediate tables must not be returned to freeTableFn.
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 3), fake.live_allocations);

    const pdpt = try fake.peekTable(pml4.entries[vmm.pml4Index(virt)] & Flags.PHYS_ADDR_MASK);
    const pd = try fake.peekTable(pdpt.entries[vmm.pdptIndex(virt)] & Flags.PHYS_ADDR_MASK);
    const pt = try fake.peekTable(pd.entries[vmm.pdIndex(virt)] & Flags.PHYS_ADDR_MASK);
    try testing.expectEqual(@as(u64, 0), pt.entries[vmm.ptIndex(virt)]);

    try testing.expectError(error.NotMapped, vmm.unmapPage(fake.backend(), &pml4, virt));
    try testing.expectEqual(@as(usize, 1), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM E: intermediate table allocation reuses existing subtrees and clears poisoned table frames" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const v1: u64 = 0x0000_0000_0000_0000;
    const v2: u64 = 0x0000_0000_0000_1000; // Same PT
    const v3: u64 = 0x0000_0000_0020_0000; // Same PD, new PT (+2 MiB)
    const v4: u64 = 0x0000_0000_4000_0000; // Same PDPT, new PD + PT (+1 GiB)

    try vmm.mapPage(fake.backend(), &pml4, v1, 0x1000_0000, Flags.WRITABLE);
    try testing.expectEqual(@as(usize, 3), fake.alloc_successes);

    // Inspect newly allocated PT to confirm poison (0xA5A5...) was completely cleared.
    const pdpt = try fake.peekTable(pml4.entries[0] & Flags.PHYS_ADDR_MASK);
    const pd0 = try fake.peekTable(pdpt.entries[0] & Flags.PHYS_ADDR_MASK);
    const pt0 = try fake.peekTable(pd0.entries[0] & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pt0, 0);

    fake.resetCounters();
    try vmm.mapPage(fake.backend(), &pml4, v2, 0x1000_1000, Flags.WRITABLE);
    try testing.expectEqual(@as(usize, 0), fake.alloc_attempts);
    try testing.expectEqual(@as(usize, 1), fake.invlpg_calls);
    try testing.expectEqual(@as(usize, 3), fake.reuse_resolve_calls);

    fake.resetCounters();
    try vmm.mapPage(fake.backend(), &pml4, v3, 0x1020_0000, Flags.WRITABLE);
    try testing.expectEqual(@as(usize, 1), fake.alloc_successes);
    try testing.expectEqual(@as(usize, 2), fake.reuse_resolve_calls);

    const pt1 = try fake.peekTable(pd0.entries[1] & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pt1, 0);

    fake.resetCounters();
    try vmm.mapPage(fake.backend(), &pml4, v4, 0x2000_0000, Flags.WRITABLE);
    try testing.expectEqual(@as(usize, 2), fake.alloc_successes);
    try testing.expectEqual(@as(usize, 1), fake.reuse_resolve_calls);

    const pd1 = try fake.peekTable(pdpt.entries[1] & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pd1, 0);
    const pt2 = try fake.peekTable(pd1.entries[0] & Flags.PHYS_ADDR_MASK);
    try expectTableClearedExcept(pt2, 0);

    try testing.expectEqual(@as(?u64, 0x1000_0000), vmm.virtToPhys(fake.backend(), &pml4, v1));
    try testing.expectEqual(@as(?u64, 0x1000_1000), vmm.virtToPhys(fake.backend(), &pml4, v2));
    try testing.expectEqual(@as(?u64, 0x1020_0000), vmm.virtToPhys(fake.backend(), &pml4, v3));
    try testing.expectEqual(@as(?u64, 0x2000_0000), vmm.virtToPhys(fake.backend(), &pml4, v4));
    try fake.assertClean();
}

test "VMM F: out-of-memory rolls back partial intermediate allocations at every stage" {
    // 1. Empty PML4 failures at PDPT (fail after 0), PD (fail after 1), PT (fail after 2).
    const fail_limits = [_]usize{ 0, 1, 2 };
    for (fail_limits) |limit| {
        var fake = try FakeVmmBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var pml4: PageTable = .{};
        fake.fail_after_allocs = limit;

        const target: u64 = 0x0000_0008_0040_0000;
        try testing.expectError(
            error.OutOfMemory,
            vmm.mapPage(fake.backend(), &pml4, target, 0x3000_0000, Flags.WRITABLE | Flags.USER),
        );

        try testing.expectEqual(limit, fake.alloc_successes);
        try testing.expectEqual(@as(usize, 1), fake.alloc_failures);
        try testing.expectEqual(limit, fake.free_calls);
        try testing.expectEqual(@as(usize, 0), fake.live_allocations);
        try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
        try testing.expectEqual(@as(u64, 0), pml4.entries[vmm.pml4Index(target)]);
        try testing.expect(!vmm.isMapped(fake.backend(), &pml4, target));
        for (0..limit) |i| {
            try testing.expectEqual(fake.allocated_frames[limit - 1 - i], fake.freed_frames[i]);
        }
        try fake.assertClean();
    }

    // 2. Partial pre-existing supervisor hierarchy: PDPT exists, allocating PD succeeds and PT fails.
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const sup_virt: u64 = 0x0000_0040_0000_0000;
    const sup_phys: u64 = 0x0000_0000_4000_0000;
    const fail_virt: u64 = 0x0000_0040_4000_0000; // Shares PML4[0], needs new PD + PT

    try vmm.mapPage(fake.backend(), &pml4, sup_virt, sup_phys, Flags.WRITABLE);
    const pml4e_before = pml4.entries[vmm.pml4Index(sup_virt)];
    const pdpt = try fake.peekTable(pml4e_before & Flags.PHYS_ADDR_MASK);
    const pdpte_before = pdpt.entries[vmm.pdptIndex(fail_virt)];

    fake.resetCounters();
    fake.fail_after_allocs = 1; // Allow PD, fail on PT

    try testing.expectError(
        error.OutOfMemory,
        vmm.mapPage(fake.backend(), &pml4, fail_virt, 0x4100_0000, Flags.WRITABLE | Flags.USER),
    );

    try testing.expectEqual(@as(usize, 1), fake.alloc_successes);
    try testing.expectEqual(@as(usize, 1), fake.free_calls);
    try testing.expectEqual(fake.allocated_frames[0], fake.freed_frames[0]);
    try testing.expectEqual(@as(usize, 3), fake.live_allocations);
    try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
    // Pre-existing supervisor PML4E must retain USER=0 and PDPT slot stays empty.
    try testing.expectEqual(pml4e_before, pml4.entries[vmm.pml4Index(sup_virt)]);
    try testing.expectEqual(pdpte_before, pdpt.entries[vmm.pdptIndex(fail_virt)]);
    try testing.expectEqual(@as(?u64, sup_phys), vmm.virtToPhys(fake.backend(), &pml4, sup_virt));
    try fake.assertClean();
}

test "VMM G & F-09: huge-page translation succeeds and mapPage/unmapPage reject 1 GiB and 2 MiB conflicts" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};

    // Subtree 1: 1 GiB huge page at PDPT level -> data frame outside page-table pool.
    const vaddr_1g_base: u64 = 0xffff_8000_0000_0000;
    const paddr_1g_base: u64 = 0x0000_0000_4000_0000; // Strictly outside FakeVmmBackend pool
    const pdpt_1g_phys = try fake.allocSeededTable();
    const pdpt_1g_i = vmm.pdptIndex(vaddr_1g_base);
    const huge_1g_entry = paddr_1g_base | Flags.PRESENT | Flags.WRITABLE | Flags.HUGE;

    pml4.entries[vmm.pml4Index(vaddr_1g_base)] = pdpt_1g_phys | Flags.PRESENT | Flags.WRITABLE;
    const pdpt_1g = try fake.peekTableMut(pdpt_1g_phys);
    pdpt_1g.entries[pdpt_1g_i] = huge_1g_entry;

    // Subtree 2: 2 MiB huge page at PD level -> data frame outside page-table pool.
    const vaddr_2m_base: u64 = 0x0000_0020_0000_0000;
    const paddr_2m_base: u64 = 0x0000_0000_8020_0000; // Strictly outside FakeVmmBackend pool
    const pdpt_2m_phys = try fake.allocSeededTable();
    const pd_2m_phys = try fake.allocSeededTable();
    const huge_2m_entry = paddr_2m_base | Flags.PRESENT | Flags.WRITABLE | Flags.HUGE;

    pml4.entries[vmm.pml4Index(vaddr_2m_base)] = pdpt_2m_phys | Flags.PRESENT | Flags.WRITABLE;
    const pdpt_2m = try fake.peekTableMut(pdpt_2m_phys);
    pdpt_2m.entries[vmm.pdptIndex(vaddr_2m_base)] = pd_2m_phys | Flags.PRESENT | Flags.WRITABLE;
    const pd_2m = try fake.peekTableMut(pd_2m_phys);
    pd_2m.entries[vmm.pdIndex(vaddr_2m_base)] = huge_2m_entry;

    fake.resetCounters();

    // 1. Translation of 1 GiB and 2 MiB huge pages with non-zero offsets.
    try testing.expectEqual(@as(?u64, paddr_1g_base), vmm.virtToPhys(fake.backend(), &pml4, vaddr_1g_base));
    try testing.expectEqual(
        @as(?u64, paddr_1g_base + 0x1234_5678),
        vmm.virtToPhys(fake.backend(), &pml4, vaddr_1g_base + 0x1234_5678),
    );
    try testing.expectEqual(
        @as(?u64, paddr_1g_base + 0x3FFF_FFFF),
        vmm.virtToPhys(fake.backend(), &pml4, vaddr_1g_base + 0x3FFF_FFFF),
    );
    try testing.expect(vmm.isMapped(fake.backend(), &pml4, vaddr_1g_base + 0x2000_1234));

    try testing.expectEqual(@as(?u64, paddr_2m_base), vmm.virtToPhys(fake.backend(), &pml4, vaddr_2m_base));
    try testing.expectEqual(
        @as(?u64, paddr_2m_base + 0x0012_3456),
        vmm.virtToPhys(fake.backend(), &pml4, vaddr_2m_base + 0x0012_3456),
    );
    try testing.expectEqual(
        @as(?u64, paddr_2m_base + 0x001F_FFFF),
        vmm.virtToPhys(fake.backend(), &pml4, vaddr_2m_base + 0x001F_FFFF),
    );
    try testing.expect(vmm.isMapped(fake.backend(), &pml4, vaddr_2m_base + 0x0000_5000));
    try fake.assertClean();

    // 2. mapPage and unmapPage against 1 GiB huge page must fail with HugePageConflict without touching data/tables.
    const pml4_1g_before = pml4.entries[vmm.pml4Index(vaddr_1g_base)];
    const target_in_1g = vaddr_1g_base + 0x0020_5000;
    try testing.expectError(
        error.HugePageConflict,
        vmm.mapPage(fake.backend(), &pml4, target_in_1g, 0x5000_0000, Flags.WRITABLE | Flags.USER),
    );
    try testing.expectError(
        error.HugePageConflict,
        vmm.unmapPage(fake.backend(), &pml4, target_in_1g),
    );
    try testing.expectEqual(pml4_1g_before, pml4.entries[vmm.pml4Index(vaddr_1g_base)]);
    try testing.expectEqual(huge_1g_entry, pdpt_1g.entries[pdpt_1g_i]);

    // 3. mapPage and unmapPage against 2 MiB huge page must fail with HugePageConflict without touching data/tables.
    const pml4_2m_before = pml4.entries[vmm.pml4Index(vaddr_2m_base)];
    const pdpt_2m_before = pdpt_2m.entries[vmm.pdptIndex(vaddr_2m_base)];
    const target_in_2m = vaddr_2m_base + 0x0000_3000;
    try testing.expectError(
        error.HugePageConflict,
        vmm.mapPage(fake.backend(), &pml4, target_in_2m, 0x5100_0000, Flags.WRITABLE | Flags.USER),
    );
    try testing.expectError(
        error.HugePageConflict,
        vmm.unmapPage(fake.backend(), &pml4, target_in_2m),
    );
    try testing.expectEqual(pml4_2m_before, pml4.entries[vmm.pml4Index(vaddr_2m_base)]);
    try testing.expectEqual(pdpt_2m_before, pdpt_2m.entries[vmm.pdptIndex(vaddr_2m_base)]);
    try testing.expectEqual(huge_2m_entry, pd_2m.entries[vmm.pdIndex(vaddr_2m_base)]);

    try testing.expectEqual(@as(usize, 0), fake.alloc_attempts);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM H & F-13: 48-bit canonicality and 4 KiB alignment validation reject invalid requests before mutation" {
    // 1. Canonical boundary checks around bit 47 transition.
    try testing.expect(vmm.isCanonical(0x0000_0000_0000_0000));
    try testing.expect(vmm.isCanonical(0x0000_7FFF_FFFF_F000));
    try testing.expect(vmm.isCanonical(0x0000_7FFF_FFFF_FFFF));
    try testing.expect(!vmm.isCanonical(0x0000_8000_0000_0000));
    try testing.expect(!vmm.isCanonical(0x0001_0000_0000_0000));
    try testing.expect(!vmm.isCanonical(0x8000_0000_0000_0000));
    try testing.expect(!vmm.isCanonical(0xFFFF_0000_0000_0000));
    try testing.expect(!vmm.isCanonical(0xFFFF_7FFF_FFFF_F000));
    try testing.expect(!vmm.isCanonical(0xFFFF_7FFF_FFFF_FFFF));
    try testing.expect(vmm.isCanonical(0xFFFF_8000_0000_0000));
    try testing.expect(vmm.isCanonical(0xFFFF_FFFF_8000_0000));
    try testing.expect(vmm.isCanonical(0xFFFF_FFFF_FFFF_F000));
    try testing.expect(vmm.isCanonical(0xFFFF_FFFF_FFFF_FFFF));

    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const low_zero: u64 = 0x0000_0000_0000_0000;
    const low_ceil: u64 = 0x0000_7FFF_FFFF_F000;
    const high_floor: u64 = 0xffff_8000_0000_0000;

    try vmm.mapPage(fake.backend(), &pml4, low_zero, 0x2000_0000, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, low_ceil, 0x2000_1000, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, high_floor, 0x2000_2000, Flags.WRITABLE);

    try testing.expectEqual(@as(?u64, 0x2000_0000), vmm.virtToPhys(fake.backend(), &pml4, low_zero));
    try testing.expectEqual(@as(?u64, 0x2000_1000), vmm.virtToPhys(fake.backend(), &pml4, low_ceil));
    try testing.expectEqual(@as(?u64, 0x2000_2000), vmm.virtToPhys(fake.backend(), &pml4, high_floor));

    fake.resetCounters();

    // Non-canonical addresses including 0x0001_0000_0000_0000 (which aliases 0x0 indices if unvalidated).
    const non_canonical_addrs = [_]u64{
        0x0000_8000_0000_0000,
        0x0001_0000_0000_0000,
        0x8000_0000_0000_0000,
        0xFFFF_7FFF_FFFF_F000,
    };
    for (non_canonical_addrs) |bad_virt| {
        try testing.expectError(
            error.NonCanonicalAddress,
            vmm.mapPage(fake.backend(), &pml4, bad_virt, 0x2000_5000, Flags.WRITABLE),
        );
        try testing.expectError(
            error.NonCanonicalAddress,
            vmm.unmapPage(fake.backend(), &pml4, bad_virt),
        );
        try testing.expectEqual(@as(?u64, null), vmm.virtToPhys(fake.backend(), &pml4, bad_virt));
        try testing.expect(!vmm.isMapped(fake.backend(), &pml4, bad_virt));
    }

    // Reject unaligned virtual and physical addresses before touching tables or allocating.
    try testing.expectError(
        error.UnalignedVirtualAddress,
        vmm.mapPage(fake.backend(), &pml4, 0x0000_0040_0000_0001, 0x2000_6000, Flags.WRITABLE),
    );
    try testing.expectError(
        error.UnalignedVirtualAddress,
        vmm.mapPage(fake.backend(), &pml4, 0xffff_8000_0000_0fff, 0x2000_6000, Flags.WRITABLE),
    );
    try testing.expectError(
        error.UnalignedPhysicalAddress,
        vmm.mapPage(fake.backend(), &pml4, 0x0000_0040_0000_0000, 0x2000_6001, Flags.WRITABLE),
    );
    try testing.expectError(
        error.UnalignedPhysicalAddress,
        vmm.mapPage(fake.backend(), &pml4, 0x0000_0040_0000_0000, 0x2000_6fff, Flags.WRITABLE),
    );
    try testing.expectError(
        error.InvalidPhysicalAddress,
        vmm.mapPage(fake.backend(), &pml4, 0x0000_0040_0000_0000, 0x0010_0000_0000_0000, Flags.WRITABLE),
    );
    try testing.expectError(
        error.UnalignedVirtualAddress,
        vmm.unmapPage(fake.backend(), &pml4, low_ceil + 1),
    );
    try testing.expectError(
        error.UnalignedVirtualAddress,
        vmm.unmapPage(fake.backend(), &pml4, high_floor + 0x80),
    );

    // Valid mappings at 0x0, low_ceil, and high_floor must remain completely intact.
    try testing.expectEqual(@as(?u64, 0x2000_0000), vmm.virtToPhys(fake.backend(), &pml4, low_zero));
    try testing.expectEqual(@as(?u64, 0x2000_1000), vmm.virtToPhys(fake.backend(), &pml4, low_ceil));
    try testing.expectEqual(@as(?u64, 0x2000_2000), vmm.virtToPhys(fake.backend(), &pml4, high_floor));
    try testing.expectEqual(@as(usize, 0), fake.alloc_attempts);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expectEqual(@as(usize, 0), fake.invlpg_calls);
    try fake.assertClean();
}

test "VMM I & F-13: USER propagation updates existing hierarchy path while preserving supervisor siblings" {
    var fake = try FakeVmmBackend.init(testing.allocator, 24);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const sup_same_pt: u64 = 0x0000_0040_0000_0000; // PML4[0], PDPT[256], PD[0], PT[0]
    const user_same_pt: u64 = 0x0000_0040_0000_1000; // PML4[0], PDPT[256], PD[0], PT[1]
    const sup_sibling_pdpt: u64 = 0x0000_0040_4000_0000; // PML4[0], PDPT[257], PD[0], PT[0]
    const sup_other_pml4: u64 = 0x0000_00C0_0000_0000; // PML4[1], PDPT[256], PD[0], PT[0]

    // 1. Map supervisor pages first (all parent and leaf entries must have USER = 0).
    try vmm.mapPage(fake.backend(), &pml4, sup_same_pt, 0x3000_0000, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, sup_sibling_pdpt, 0x3000_2000, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, sup_other_pml4, 0x3000_3000, Flags.WRITABLE);

    const pdpt0 = try fake.peekTable(pml4.entries[0] & Flags.PHYS_ADDR_MASK);
    const pd_shared = try fake.peekTable(pdpt0.entries[256] & Flags.PHYS_ADDR_MASK);
    const pt_shared = try fake.peekTable(pd_shared.entries[0] & Flags.PHYS_ADDR_MASK);
    try testing.expect((pml4.entries[0] & Flags.USER) == 0);
    try testing.expect((pdpt0.entries[256] & Flags.USER) == 0);
    try testing.expect((pd_shared.entries[0] & Flags.USER) == 0);
    try testing.expect((pt_shared.entries[0] & Flags.USER) == 0);

    // 2. Map user page into the shared supervisor hierarchy.
    try vmm.mapPage(fake.backend(), &pml4, user_same_pt, 0x3000_1000, Flags.WRITABLE | Flags.USER);

    // 3. Existing PML4[0], PDPT[256], and PD[0] must gain Flags.USER.
    try testing.expect((pml4.entries[0] & Flags.USER) != 0);
    try testing.expect((pdpt0.entries[256] & Flags.USER) != 0);
    try testing.expect((pd_shared.entries[0] & Flags.USER) != 0);

    // 4. New user leaf must have Flags.USER, while earlier supervisor leaf stays supervisor-only.
    try testing.expect((pt_shared.entries[1] & Flags.USER) != 0);
    try testing.expect((pt_shared.entries[0] & Flags.USER) == 0);

    // 5. Sibling PDPT subtree (PDPT[257]) and unrelated PML4[1] subtree must remain supervisor-only.
    try testing.expect((pdpt0.entries[257] & Flags.USER) == 0);
    const pd_sib = try fake.peekTable(pdpt0.entries[257] & Flags.PHYS_ADDR_MASK);
    const pt_sib = try fake.peekTable(pd_sib.entries[0] & Flags.PHYS_ADDR_MASK);
    try testing.expect((pd_sib.entries[0] & Flags.USER) == 0);
    try testing.expect((pt_sib.entries[0] & Flags.USER) == 0);

    try testing.expect((pml4.entries[1] & Flags.USER) == 0);
    const pdpt1 = try fake.peekTable(pml4.entries[1] & Flags.PHYS_ADDR_MASK);
    const pd1 = try fake.peekTable(pdpt1.entries[256] & Flags.PHYS_ADDR_MASK);
    const pt1 = try fake.peekTable(pd1.entries[0] & Flags.PHYS_ADDR_MASK);
    try testing.expect((pdpt1.entries[256] & Flags.USER) == 0);
    try testing.expect((pd1.entries[0] & Flags.USER) == 0);
    try testing.expect((pt1.entries[0] & Flags.USER) == 0);

    // 6. Mapping a later supervisor page in the promoted subtree must NOT drop parent USER bits.
    const sup_later: u64 = 0x0000_0040_0000_2000;
    try vmm.mapPage(fake.backend(), &pml4, sup_later, 0x3000_4000, Flags.WRITABLE);
    try testing.expect((pml4.entries[0] & Flags.USER) != 0);
    try testing.expect((pdpt0.entries[256] & Flags.USER) != 0);
    try testing.expect((pd_shared.entries[0] & Flags.USER) != 0);
    try testing.expect((pt_shared.entries[2] & Flags.USER) == 0);
    try fake.assertClean();
}

test "VMM J: backend tracks invalidations and table-only resolutions across mixed operations" {
    var fake = try FakeVmmBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var pml4: PageTable = .{};
    const v1: u64 = 0x0000_1234_5678_9000;
    const p1: u64 = 0x0000_0000_7770_0000; // Outside page-table pool
    const v2: u64 = 0x0000_1234_5678_a000;
    const p2: u64 = 0x0000_0000_7770_1000; // Outside page-table pool

    try vmm.mapPage(fake.backend(), &pml4, v1, p1, Flags.WRITABLE);
    try vmm.mapPage(fake.backend(), &pml4, v2, p2, Flags.WRITABLE | Flags.USER);
    try testing.expectError(error.AlreadyMapped, vmm.mapPage(fake.backend(), &pml4, v1, p2, Flags.WRITABLE));
    try testing.expectError(error.NonCanonicalAddress, vmm.mapPage(fake.backend(), &pml4, 0x0001_0000_0000_0000, p2, Flags.WRITABLE));
    try vmm.unmapPage(fake.backend(), &pml4, v1);
    try testing.expectError(error.NotMapped, vmm.unmapPage(fake.backend(), &pml4, v1));

    // Only successful map(v1), map(v2), and unmap(v1) should invalidate TLB.
    try testing.expectEqual(@as(usize, 3), fake.invlpg_calls);
    try testing.expectEqual(v1, fake.invlpg_addrs[0]);
    try testing.expectEqual(v2, fake.invlpg_addrs[1]);
    try testing.expectEqual(v1, fake.invlpg_addrs[2]);

    // Exactly 3 intermediate tables created for v1, then reused for v2 and unmap.
    try testing.expectEqual(@as(usize, 3), fake.alloc_successes);
    try testing.expectEqual(@as(usize, 3), fake.live_allocations);
    try testing.expectEqual(@as(usize, 0), fake.free_calls);
    try testing.expect(fake.reuse_resolve_calls >= 3);
    try testing.expectEqual(@as(?u64, p2 + 0xABC), vmm.virtToPhys(fake.backend(), &pml4, v2 + 0xABC));
    try fake.assertClean();
}
