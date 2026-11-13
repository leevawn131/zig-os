// Stateful Kernel Heap Allocator Core
// Hardware-independent coalescing linked-list allocator shared between
// the freestanding kernel and host-side unit tests.

const std = @import("std");
const heap_layout = @import("heap_layout.zig");

pub const BlockHeader = heap_layout.BlockHeader;
pub const HEADER_SIZE: usize = heap_layout.HEADER_SIZE;

pub const PAGE_SIZE: u64 = 4096;
pub const MAGIC_FREE: u32 = 0x46524545; // 'FREE'
pub const MAGIC_USED: u32 = 0x55534544; // 'USED'
pub const CANARY: u32 = 0xCAFEBABE;

pub const InitError = error{
    InvalidInitialPageCount,
    CapacityExceeded,
    ExpansionFailed,
};

pub const FreeError = error{
    PointerOutOfBounds,
    BlockHeaderNotFound,
    CorruptBlockHeader,
    DoubleFree,
};

/// Maps one backing heap page at `page_vaddr`.
/// Production binds this to PMM frame allocation and VMM writable mapping;
/// host tests expose pre-allocated page-aligned writable host memory.
pub const PageMapper = struct {
    ctx: ?*anyopaque = null,
    mapPageFn: *const fn (ctx: ?*anyopaque, page_vaddr: u64) bool,

    pub inline fn mapPage(self: PageMapper, page_vaddr: u64) bool {
        return self.mapPageFn(self.ctx, page_vaddr);
    }
};

fn alignUpChecked(value: u64, alignment: u64) ?u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;
    const mask = alignment - 1;
    const added = std.math.add(u64, value, mask) catch return null;
    return added & ~mask;
}

fn ceilDivU64(numerator: u64, denominator: u64) ?u64 {
    if (denominator == 0) return null;
    if (numerator == 0) return 0;
    return ((numerator - 1) / denominator) + 1;
}

fn coalesceWithNext(left: *BlockHeader) void {
    const next_b = left.next orelse return;
    if (!left.is_free or left.magic != MAGIC_FREE or left.canary != CANARY) return;
    if (!next_b.is_free or next_b.magic != MAGIC_FREE or next_b.canary != CANARY) return;

    const left_addr = @intFromPtr(left);
    const next_addr = @intFromPtr(next_b);
    const header_plus_size = std.math.add(u64, HEADER_SIZE, left.size) catch return;
    const expected_next = std.math.add(u64, left_addr, header_plus_size) catch return;
    if (expected_next == next_addr) {
        const added_size = std.math.add(usize, HEADER_SIZE, next_b.size) catch return;
        left.size = std.math.add(usize, left.size, added_size) catch return;
        left.align_offset = 0;
        left.next = next_b.next;
        if (next_b.next) |nn| {
            nn.prev = left;
        }
    }
}

pub const HeapAllocator = struct {
    heap_start: u64,
    heap_max_size: u64,
    current_heap_end: u64,
    head_block: ?*BlockHeader = null,
    initialized: bool = false,
    total_allocated_bytes: usize = 0,
    total_freed_bytes: usize = 0,
    page_mapper: PageMapper,

    const Self = @This();

    pub fn create(heap_start: u64, heap_max_size: u64, page_mapper: PageMapper) Self {
        return .{
            .heap_start = heap_start,
            .heap_max_size = heap_max_size,
            .current_heap_end = heap_start,
            .head_block = null,
            .initialized = false,
            .total_allocated_bytes = 0,
            .total_freed_bytes = 0,
            .page_mapper = page_mapper,
        };
    }

    pub inline fn mappedBytes(self: *const Self) u64 {
        return self.current_heap_end - self.heap_start;
    }

    /// Initializes the heap with at least `initial_pages` backing pages.
    /// If a prior attempt mapped some pages before failing, preserves those mapped
    /// pages and maps only the remaining pages on retry without remapping old addresses.
    pub fn init(self: *Self, initial_pages: usize) InitError!void {
        if (self.initialized) return;
        if (initial_pages == 0) return error.InvalidInitialPageCount;

        const initial_pages_u64 = std.math.cast(u64, initial_pages) orelse return error.CapacityExceeded;
        const initial_bytes = std.math.mul(u64, initial_pages_u64, PAGE_SIZE) catch return error.CapacityExceeded;
        if (initial_bytes > self.heap_max_size) return error.CapacityExceeded;
        if (self.current_heap_end < self.heap_start) return error.ExpansionFailed;

        const already_mapped_bytes = self.current_heap_end - self.heap_start;
        if (already_mapped_bytes % PAGE_SIZE != 0) return error.ExpansionFailed;
        const already_mapped_pages = already_mapped_bytes / PAGE_SIZE;

        if (initial_pages_u64 > already_mapped_pages) {
            const pages_remaining = std.math.cast(usize, initial_pages_u64 - already_mapped_pages) orelse return error.CapacityExceeded;
            if (!self.expandHeap(pages_remaining)) {
                return error.ExpansionFailed;
            }
        }

        self.initialized = true;
    }

    pub fn expandHeap(self: *Self, page_count: usize) bool {
        for (0..page_count) |_| {
            if (self.current_heap_end < self.heap_start) return false;
            const used_span = self.current_heap_end - self.heap_start;
            if (used_span >= self.heap_max_size or self.heap_max_size - used_span < PAGE_SIZE) {
                return false;
            }
            const next_end = std.math.add(u64, self.current_heap_end, PAGE_SIZE) catch return false;

            if (!self.page_mapper.mapPage(self.current_heap_end)) {
                return false;
            }

            const new_block: *BlockHeader = @ptrFromInt(self.current_heap_end);
            new_block.* = BlockHeader{
                .magic = MAGIC_FREE,
                .canary = CANARY,
                .size = @as(usize, PAGE_SIZE) - HEADER_SIZE,
                .is_free = true,
                .align_offset = 0,
                .next = null,
                .prev = null,
            };

            if (self.head_block == null) {
                self.head_block = new_block;
            } else {
                var curr = self.head_block.?;
                while (curr.next) |next| {
                    curr = next;
                }
                curr.next = new_block;
                new_block.prev = curr;

                coalesceWithNext(curr);
            }

            self.current_heap_end = next_end;
        }

        return true;
    }

    fn coalescingFreeTail(self: *const Self) ?*BlockHeader {
        var curr = self.head_block orelse return null;
        while (curr.next) |next| {
            curr = next;
        }
        if (!curr.is_free or curr.magic != MAGIC_FREE or curr.canary != CANARY) {
            return null;
        }
        const curr_addr = @intFromPtr(curr);
        const tail_payload = std.math.add(u64, curr_addr, HEADER_SIZE) catch return null;
        const tail_end = std.math.add(u64, tail_payload, curr.size) catch return null;
        if (tail_end != self.current_heap_end) {
            return null;
        }
        return curr;
    }

    fn pagesNeededForExpansion(self: *const Self, aligned_size_u64: u64, align_val_u64: u64) ?u64 {
        if (self.coalescingFreeTail()) |tail| {
            const payload_addr = std.math.add(u64, @intFromPtr(tail), HEADER_SIZE) catch return null;
            const aligned_payload = alignUpChecked(payload_addr, align_val_u64) orelse return null;
            const align_offset = aligned_payload - payload_addr;
            if (std.math.cast(u32, align_offset) == null) return null;
            const total_needed = std.math.add(u64, aligned_size_u64, align_offset) catch return null;
            if (total_needed <= tail.size) return 0;
            const deficit = total_needed - tail.size;
            return ceilDivU64(deficit, PAGE_SIZE);
        }

        const payload_addr = std.math.add(u64, self.current_heap_end, HEADER_SIZE) catch return null;
        const aligned_payload = alignUpChecked(payload_addr, align_val_u64) orelse return null;
        const align_offset = aligned_payload - payload_addr;
        if (std.math.cast(u32, align_offset) == null) return null;
        const total_needed = std.math.add(u64, aligned_size_u64, align_offset) catch return null;
        const total_block_bytes = std.math.add(u64, HEADER_SIZE, total_needed) catch return null;
        return ceilDivU64(total_block_bytes, PAGE_SIZE);
    }

    fn tryAllocateFromFreeList(self: *Self, aligned_size: usize, align_val_u64: u64) ?[*]u8 {
        var curr = self.head_block;
        while (curr) |block| {
            if (block.is_free and block.magic == MAGIC_FREE and block.canary == CANARY) {
                const payload_addr = std.math.add(u64, @intFromPtr(block), HEADER_SIZE) catch {
                    curr = block.next;
                    continue;
                };
                const aligned_payload = alignUpChecked(payload_addr, align_val_u64) orelse {
                    curr = block.next;
                    continue;
                };
                const align_offset_u64 = aligned_payload - payload_addr;
                const align_offset_u32 = std.math.cast(u32, align_offset_u64) orelse {
                    curr = block.next;
                    continue;
                };
                const align_offset_usize = std.math.cast(usize, align_offset_u64) orelse {
                    curr = block.next;
                    continue;
                };
                const total_needed = std.math.add(usize, aligned_size, align_offset_usize) catch {
                    curr = block.next;
                    continue;
                };

                if (block.size >= total_needed) {
                    // Split block if excess space is sufficient for another header + min chunk
                    const excess = block.size - total_needed;
                    if (excess > HEADER_SIZE + 32) {
                        const split_addr = aligned_payload + @as(u64, aligned_size);
                        const next_block: *BlockHeader = @ptrFromInt(split_addr);
                        next_block.* = BlockHeader{
                            .magic = MAGIC_FREE,
                            .canary = CANARY,
                            .size = excess - HEADER_SIZE,
                            .is_free = true,
                            .align_offset = 0,
                            .next = block.next,
                            .prev = block,
                        };

                        if (block.next) |n| {
                            n.prev = next_block;
                        }
                        block.next = next_block;
                        block.size = total_needed;
                    }

                    block.align_offset = align_offset_u32;
                    block.magic = MAGIC_USED;
                    block.is_free = false;
                    self.total_allocated_bytes += block.size;

                    return @ptrFromInt(aligned_payload);
                }
            }
            curr = block.next;
        }

        return null;
    }

    pub fn allocate(self: *Self, size: usize, alignment: usize) ?[*]u8 {
        if (!self.initialized) return null;
        if (size == 0) return null;
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;

        // Enforce at least 16-byte System V ABI alignment while validating requested alignment
        const align_val_usize: usize = @max(alignment, 16);
        const align_val_u64 = std.math.cast(u64, align_val_usize) orelse return null;
        if (align_val_u64 > self.heap_max_size) return null;

        // Align request size up to 16 bytes using overflow-checked arithmetic
        const aligned_size_u64 = alignUpChecked(@as(u64, size), 16) orelse return null;
        if (aligned_size_u64 > self.heap_max_size) return null;
        const aligned_size = std.math.cast(usize, aligned_size_u64) orelse return null;

        if (self.tryAllocateFromFreeList(aligned_size, align_val_u64)) |ptr| {
            return ptr;
        }

        if (self.current_heap_end < self.heap_start) return null;
        const used_span = self.current_heap_end - self.heap_start;
        if (used_span >= self.heap_max_size) return null;

        const pages_needed = self.pagesNeededForExpansion(aligned_size_u64, align_val_u64) orelse return null;
        if (pages_needed == 0) return null;

        const remaining_pages = (self.heap_max_size - used_span) / PAGE_SIZE;
        if (remaining_pages == 0 or pages_needed > remaining_pages) {
            return null;
        }

        const batch_pages_u64 = @min(@max(pages_needed, @as(u64, 4)), remaining_pages);
        const batch_pages = std.math.cast(usize, batch_pages_u64) orelse return null;

        const end_before = self.current_heap_end;
        const expanded_full = self.expandHeap(batch_pages);
        if (expanded_full or self.current_heap_end > end_before) {
            return self.tryAllocateFromFreeList(aligned_size, align_val_u64);
        }

        return null;
    }

    pub fn deallocate(self: *Self, ptr: [*]u8) FreeError!void {
        const raw_addr = @intFromPtr(ptr);
        if (!self.initialized or raw_addr < self.heap_start or raw_addr >= self.current_heap_end) {
            return error.PointerOutOfBounds;
        }

        var curr = self.head_block;
        var found_block: ?*BlockHeader = null;

        while (curr) |block| {
            const payload_start = std.math.add(u64, @intFromPtr(block), HEADER_SIZE) catch return error.CorruptBlockHeader;
            const payload_end = std.math.add(u64, payload_start, block.size) catch return error.CorruptBlockHeader;
            if (raw_addr >= payload_start and raw_addr < payload_end) {
                found_block = block;
                break;
            }
            curr = block.next;
        }

        const block = found_block orelse return error.BlockHeaderNotFound;

        if (block.magic != MAGIC_USED or block.canary != CANARY) {
            return error.CorruptBlockHeader;
        }

        if (block.is_free) {
            return error.DoubleFree;
        }

        const align_offset_usize: usize = @intCast(block.align_offset);
        if (align_offset_usize > block.size or block.size - align_offset_usize < 16) {
            return error.CorruptBlockHeader;
        }

        const payload_start = @intFromPtr(block) + @as(u64, HEADER_SIZE);
        const expected_ptr = payload_start + @as(u64, block.align_offset);
        if (raw_addr != expected_ptr) {
            return error.BlockHeaderNotFound;
        }

        block.magic = MAGIC_FREE;
        block.is_free = true;
        block.align_offset = 0;
        self.total_freed_bytes += block.size;

        coalesceWithNext(block);
        if (block.prev) |prev_b| {
            coalesceWithNext(prev_b);
        }
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn vtableAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.allocate(len, alignment.toByteUnits());
    }

    fn vtableResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn vtableRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn vtableFree(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deallocate(memory.ptr) catch |err| switch (err) {
            error.PointerOutOfBounds => @panic("HEAP: Attempted to free pointer outside heap address space"),
            error.BlockHeaderNotFound => @panic("HEAP: Corrupt free - matching block header not found"),
            error.CorruptBlockHeader => @panic("HEAP: Corrupt block header - memory overwrite detected"),
            error.DoubleFree => @panic("HEAP: Double-free detected on heap memory block"),
        };
    }

    pub const allocator_vtable = std.mem.Allocator.VTable{
        .alloc = vtableAlloc,
        .resize = vtableResize,
        .remap = vtableRemap,
        .free = vtableFree,
    };
};
