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

fn coalesceWithNext(left: *BlockHeader) void {
    const next_b = left.next orelse return;
    if (!left.is_free or left.magic != MAGIC_FREE) return;
    if (!next_b.is_free or next_b.magic != MAGIC_FREE) return;

    const left_addr = @intFromPtr(left);
    const next_addr = @intFromPtr(next_b);
    if (left_addr + HEADER_SIZE + left.size == next_addr) {
        left.size += HEADER_SIZE + next_b.size;
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

    pub fn init(self: *Self, initial_pages: usize) void {
        if (self.initialized) return;

        self.current_heap_end = self.heap_start;
        self.head_block = null;
        self.total_allocated_bytes = 0;
        self.total_freed_bytes = 0;

        _ = self.expandHeap(initial_pages);

        self.initialized = true;
    }

    pub fn expandHeap(self: *Self, page_count: usize) bool {
        for (0..page_count) |_| {
            const used_span = self.current_heap_end - self.heap_start;
            if (used_span >= self.heap_max_size or self.heap_max_size - used_span < PAGE_SIZE) {
                return false;
            }

            if (!self.page_mapper.mapPage(self.current_heap_end)) {
                return false;
            }

            const new_block: *BlockHeader = @ptrFromInt(self.current_heap_end);
            new_block.* = BlockHeader{
                .magic = MAGIC_FREE,
                .canary = CANARY,
                .size = @as(usize, PAGE_SIZE) - HEADER_SIZE,
                .is_free = true,
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

            self.current_heap_end += PAGE_SIZE;
        }

        return true;
    }

    pub fn allocate(self: *Self, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;

        const align_val = @max(alignment, 16);
        // Align request size to 16 bytes for System V alignment
        const aligned_size = (size + 15) & ~@as(usize, 15);

        var curr = self.head_block;
        while (curr) |block| {
            if (block.is_free and block.magic == MAGIC_FREE and block.canary == CANARY) {
                const payload_addr = @intFromPtr(block) + HEADER_SIZE;
                const aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1);
                const align_offset = aligned_payload - payload_addr;
                const total_needed = aligned_size + align_offset;

                if (block.size >= total_needed) {
                    // Split block if excess space is sufficient for another header + min chunk
                    const excess = block.size - total_needed;
                    if (excess > HEADER_SIZE + 32) {
                        const split_addr = aligned_payload + aligned_size;
                        const next_block: *BlockHeader = @ptrFromInt(split_addr);
                        next_block.* = BlockHeader{
                            .magic = MAGIC_FREE,
                            .canary = CANARY,
                            .size = excess - HEADER_SIZE,
                            .is_free = true,
                            .next = block.next,
                            .prev = block,
                        };

                        if (block.next) |n| {
                            n.prev = next_block;
                        }
                        block.next = next_block;
                        block.size = total_needed;
                    }

                    block.magic = MAGIC_USED;
                    block.is_free = false;
                    self.total_allocated_bytes += block.size;

                    return @ptrFromInt(aligned_payload);
                }
            }
            curr = block.next;
        }

        const page_size_usize: usize = @intCast(PAGE_SIZE);
        const pages_needed = (aligned_size + HEADER_SIZE + page_size_usize - 1) / page_size_usize;
        if (self.expandHeap(@max(pages_needed, 4))) {
            return self.allocate(size, alignment);
        }

        return null;
    }

    pub fn deallocate(self: *Self, ptr: [*]u8) FreeError!void {
        const raw_addr = @intFromPtr(ptr);
        if (raw_addr < self.heap_start or raw_addr >= self.current_heap_end) {
            return error.PointerOutOfBounds;
        }

        var curr = self.head_block;
        var found_block: ?*BlockHeader = null;

        while (curr) |block| {
            const payload_start = @intFromPtr(block) + HEADER_SIZE;
            const payload_end = payload_start + block.size;
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

        block.magic = MAGIC_FREE;
        block.is_free = true;
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
