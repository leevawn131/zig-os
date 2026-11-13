// Host-side Unit Tests for Stateful Kernel Heap Allocator Core
// Exercises the exact production `heap_core.HeapAllocator` shared with `kernel/src/mm/heap.zig`.

const std = @import("std");
const testing = std.testing;

const heap_core = @import("heap_core");

const BlockHeader = heap_core.BlockHeader;
const HEADER_SIZE = heap_core.HEADER_SIZE;
const PAGE_SIZE = heap_core.PAGE_SIZE;
const MAGIC_FREE = heap_core.MAGIC_FREE;
const MAGIC_USED = heap_core.MAGIC_USED;
const CANARY = heap_core.CANARY;
const HeapAllocator = heap_core.HeapAllocator;

const FakeHeapBackend = struct {
    const PageFrame = extern struct {
        bytes: [PAGE_SIZE]u8 align(PAGE_SIZE),
    };

    const MAX_LOG = 64;

    allocator: std.mem.Allocator,
    frames: []PageFrame,
    fail_after_pages: ?usize = null,
    map_calls: usize = 0,
    mapped_pages: usize = 0,
    map_failures: usize = 0,
    mapped_addrs: [MAX_LOG]u64 = @splat(0),
    unexpected_addr: bool = false,
    last_unexpected_addr: u64 = 0,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, capacity_pages: usize) !Self {
        const frames = try allocator.alloc(PageFrame, capacity_pages);
        for (frames) |*frame| {
            @memset(&frame.bytes, 0xDD);
        }
        return .{
            .allocator = allocator,
            .frames = frames,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.frames);
    }

    fn baseVaddr(self: *const Self) u64 {
        return @intFromPtr(self.frames.ptr);
    }

    fn maxSize(self: *const Self) u64 {
        return @as(u64, @intCast(self.frames.len)) * PAGE_SIZE;
    }

    fn pageMapper(self: *Self) heap_core.PageMapper {
        return .{
            .ctx = self,
            .mapPageFn = mapPageFn,
        };
    }

    fn mapPageFn(ctx: ?*anyopaque, page_vaddr: u64) bool {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.map_calls += 1;

        const base = self.baseVaddr();
        const expected = base + @as(u64, @intCast(self.mapped_pages)) * PAGE_SIZE;
        if (page_vaddr != expected or page_vaddr % PAGE_SIZE != 0 or self.mapped_pages >= self.frames.len) {
            self.unexpected_addr = true;
            self.last_unexpected_addr = page_vaddr;
            return false;
        }

        if (self.fail_after_pages) |limit| {
            if (self.mapped_pages >= limit) {
                self.map_failures += 1;
                return false;
            }
        }

        if (self.mapped_pages < MAX_LOG) {
            self.mapped_addrs[self.mapped_pages] = page_vaddr;
        }
        self.mapped_pages += 1;
        return true;
    }

    fn expectUnmappedPoisonedFrom(self: *const Self, first_unmapped_page: usize) !void {
        for (self.frames[first_unmapped_page..]) |*frame| {
            for (frame.bytes) |b| {
                try testing.expectEqual(@as(u8, 0xDD), b);
            }
        }
    }
};


fn findBlockForPtr(heap: *const HeapAllocator, ptr: [*]u8) !*BlockHeader {
    const target = @intFromPtr(ptr);
    var curr = heap.head_block;
    while (curr) |block| {
        const payload_start = @intFromPtr(block) + HEADER_SIZE;
        const payload_end = payload_start + block.size;
        if (target >= payload_start and target < payload_end) {
            return block;
        }
        curr = block.next;
    }
    return error.BlockNotFoundInTest;
}

fn countBlocks(heap: *const HeapAllocator) usize {
    var count: usize = 0;
    var curr = heap.head_block;
    while (curr) |block| {
        count += 1;
        curr = block.next;
    }
    return count;
}

fn assertListInvariants(heap: *const HeapAllocator) !void {
    const total_mapped = heap.mappedBytes();
    try testing.expectEqual(@as(u64, 0), total_mapped % PAGE_SIZE);

    if (total_mapped == 0) {
        try testing.expectEqual(@as(?*BlockHeader, null), heap.head_block);
        return;
    }

    const head = heap.head_block orelse return error.MissingHeadBlock;
    try testing.expectEqual(heap.heap_start, @intFromPtr(head));
    try testing.expectEqual(@as(?*BlockHeader, null), head.prev);

    var accounted_bytes: u64 = 0;
    var prev_block: ?*BlockHeader = null;
    var curr: ?*BlockHeader = head;

    while (curr) |block| {
        try testing.expectEqual(prev_block, block.prev);
        try testing.expectEqual(CANARY, block.canary);
        if (block.is_free) {
            try testing.expectEqual(MAGIC_FREE, block.magic);
            try testing.expectEqual(@as(u32, 0), block.align_offset);
            if (prev_block) |pb| {
                try testing.expect(!pb.is_free);
            }
        } else {
            try testing.expectEqual(MAGIC_USED, block.magic);
            try testing.expect(@as(usize, block.align_offset) <= block.size);
            try testing.expect(block.size - @as(usize, block.align_offset) >= 16);
        }

        const block_addr = @intFromPtr(block);
        try testing.expect(block_addr >= heap.heap_start);
        try testing.expect(block_addr + HEADER_SIZE <= heap.current_heap_end);

        const span = HEADER_SIZE + block.size;
        accounted_bytes += span;

        if (block.next) |next_b| {
            try testing.expectEqual(block_addr + span, @intFromPtr(next_b));
        }

        prev_block = block;
        curr = block.next;
    }

    try testing.expectEqual(total_mapped, accounted_bytes);
}

test "Heap 01: initialization creates coalesced initial free block and idempotent re-init" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try testing.expect(!heap.initialized);
    try testing.expectEqual(@as(u64, 0), heap.mappedBytes());

    try heap.init(4);
    try testing.expect(heap.initialized);
    try testing.expect(!fake.unexpected_addr);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
    try testing.expectEqual(@as(u64, 4 * PAGE_SIZE), heap.mappedBytes());

    const head = heap.head_block orelse return error.TestUnexpectedResult;
    try testing.expectEqual(MAGIC_FREE, head.magic);
    try testing.expectEqual(CANARY, head.canary);
    try testing.expect(head.is_free);
    try testing.expectEqual(@as(usize, 4 * PAGE_SIZE - HEADER_SIZE), head.size);
    try testing.expectEqual(@as(?*BlockHeader, null), head.prev);
    try testing.expectEqual(@as(?*BlockHeader, null), head.next);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try assertListInvariants(&heap);
    try fake.expectUnmappedPoisonedFrom(4);

    // Calling init a second time must be a no-op.
    try heap.init(2);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
    try testing.expectEqual(@as(u64, 4 * PAGE_SIZE), heap.mappedBytes());
}

test "Heap 02: zero-sized allocation returns null without modifying heap state" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(2);
    const prev_size = heap.head_block.?.size;

    try testing.expectEqual(@as(?[*]u8, null), heap.allocate(0, 16));
    try testing.expectEqual(@as(?[*]u8, null), heap.allocate(0, 64));
    try testing.expectEqual(@as(usize, 2), fake.map_calls);
    try testing.expectEqual(@as(usize, 0), heap.total_allocated_bytes);
    try testing.expectEqual(prev_size, heap.head_block.?.size);
    try testing.expect(heap.head_block.?.is_free);
    try assertListInvariants(&heap);
}

test "Heap 03: basic small allocations enforce minimum 16-byte alignment and USED metadata" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const p1 = heap.allocate(1, 1) orelse return error.TestUnexpectedResult;
    const p2 = heap.allocate(24, 8) orelse return error.TestUnexpectedResult;
    const p3 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 0), @intFromPtr(p1) % 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p2) % 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p3) % 16);

    const b1 = try findBlockForPtr(&heap, p1);
    const b2 = try findBlockForPtr(&heap, p2);
    const b3 = try findBlockForPtr(&heap, p3);
    try testing.expectEqual(MAGIC_USED, b1.magic);
    try testing.expectEqual(CANARY, b1.canary);
    try testing.expect(!b1.is_free);
    try testing.expect(!b2.is_free);
    try testing.expect(!b3.is_free);

    p1[0] = 0x11;
    @memset(p2[0..24], 0x22);
    @memset(p3[0..64], 0x33);

    try assertListInvariants(&heap);
    try testing.expect(heap.total_allocated_bytes >= 1 + 24 + 64);

    try heap.deallocate(p3);
    try heap.deallocate(p2);
    try heap.deallocate(p1);
    try assertListInvariants(&heap);
}

test "Heap 04: power-of-two over-alignment returns 64-byte and 256-byte aligned payloads" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const p64 = heap.allocate(128, 64) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p64) % 64);
    @memset(p64[0..128], 0x5A);

    const p256 = heap.allocate(300, 256) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p256) % 256);
    @memset(p256[0..300], 0xA5);

    for (p64[0..128]) |b| try testing.expectEqual(@as(u8, 0x5A), b);
    for (p256[0..300]) |b| try testing.expectEqual(@as(u8, 0xA5), b);
    try assertListInvariants(&heap);

    try heap.deallocate(p64);
    try heap.deallocate(p256);
    try assertListInvariants(&heap);
}

test "Heap 05: allocation splitting preserves list links and skips splitting below threshold" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(1); // Single free block of 4096 - 40 = 4056 bytes

    // Split case: aligned_size=64, align_offset=8, total_needed=72; excess = 4056 - 72 = 3984 > HEADER_SIZE + 32.
    const p1 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), countBlocks(&heap));

    const b1 = try findBlockForPtr(&heap, p1);
    const tail = b1.next orelse return error.TestUnexpectedResult;
    try testing.expectEqual(b1, tail.prev.?);
    try testing.expect(tail.is_free);
    try testing.expectEqual(MAGIC_FREE, tail.magic);
    try testing.expectEqual(@as(usize, 4056 - 72 - HEADER_SIZE), tail.size);
    try assertListInvariants(&heap);

    // Non-split threshold case: create a free block whose remaining excess <= HEADER_SIZE + 32 (72).
    // Current tail payload is 3944 bytes (aligned_payload offset 8 from tail+40): request aligned_size=3872.
    // total_needed = 3872 + 8 = 3880 -> excess = 3944 - 3880 = 64 <= 72 -> must NOT split.
    const p2 = heap.allocate(3872, 16) orelse return error.TestUnexpectedResult;
    const b2 = try findBlockForPtr(&heap, p2);
    try testing.expectEqual(@as(usize, 2), countBlocks(&heap));
    try testing.expectEqual(@as(usize, 3944), b2.size);
    try testing.expectEqual(@as(?*BlockHeader, null), b2.next);
    try assertListInvariants(&heap);

    try heap.deallocate(p2);
    try heap.deallocate(p1);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(@as(usize, 4056), heap.head_block.?.size);
}

test "Heap 06: deallocation and forward coalescing merge adjacent trailing free block" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const a = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const b = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const c = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const d = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    // Blocks are now [USED A][USED B][USED C][USED D][FREE tail].
    try testing.expectEqual(@as(usize, 5), countBlocks(&heap));

    const blk_b = try findBlockForPtr(&heap, b);
    const blk_c = try findBlockForPtr(&heap, c);
    const expected_merged_size = blk_b.size + HEADER_SIZE + blk_c.size;

    // Free C first ([USED B][FREE C][USED D]), then free B so B must coalesce forward with C only.
    try heap.deallocate(c);
    try testing.expectEqual(@as(usize, 5), countBlocks(&heap));
    try heap.deallocate(b);

    try testing.expectEqual(@as(usize, 4), countBlocks(&heap));
    try testing.expect(blk_b.is_free);
    try testing.expectEqual(MAGIC_FREE, blk_b.magic);
    try testing.expectEqual(expected_merged_size, blk_b.size);
    const blk_a = try findBlockForPtr(&heap, a);
    const blk_d = try findBlockForPtr(&heap, d);
    try testing.expectEqual(blk_b, blk_a.next.?);
    try testing.expectEqual(blk_d, blk_b.next.?);
    try testing.expectEqual(blk_b, blk_d.prev.?);
    try assertListInvariants(&heap);
}

test "Heap 07: deallocation performs backward coalescing and bidirectional three-way merge" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const a = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const b = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const c = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const d = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const e = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    // Blocks: [USED A][USED B][USED C][USED D][USED E][FREE tail]
    try testing.expectEqual(@as(usize, 6), countBlocks(&heap));

    const blk_a = try findBlockForPtr(&heap, a);
    const blk_b = try findBlockForPtr(&heap, b);
    const blk_c = try findBlockForPtr(&heap, c);
    const blk_d = try findBlockForPtr(&heap, d);
    const ab_merged_size = blk_a.size + HEADER_SIZE + blk_b.size;

    // 1. Pure backward coalesce: free A, then free B (C is USED so no forward coalesce).
    try heap.deallocate(a);
    try heap.deallocate(b);
    try testing.expectEqual(@as(usize, 5), countBlocks(&heap));
    try testing.expectEqual(blk_a, heap.head_block.?);
    try testing.expectEqual(ab_merged_size, blk_a.size);
    try testing.expectEqual(blk_c, blk_a.next.?);
    try testing.expectEqual(blk_a, blk_c.prev.?);
    try assertListInvariants(&heap);

    // 2. Three-way bidirectional coalesce: [FREE AB][USED C][FREE D][USED E]...
    try heap.deallocate(d);
    try testing.expectEqual(@as(usize, 5), countBlocks(&heap));
    const three_way_size = blk_a.size + HEADER_SIZE + blk_c.size + HEADER_SIZE + blk_d.size;

    try heap.deallocate(c);
    const blk_e = try findBlockForPtr(&heap, e);
    try testing.expectEqual(@as(usize, 3), countBlocks(&heap)); // [FREE ABC D][USED E][FREE tail]
    try testing.expectEqual(three_way_size, blk_a.size);
    try testing.expectEqual(blk_e, blk_a.next.?);
    try testing.expectEqual(blk_a, blk_e.prev.?);
    try assertListInvariants(&heap);

    try heap.deallocate(e);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(@as(usize, 4 * PAGE_SIZE - HEADER_SIZE), heap.head_block.?.size);
}

test "Heap 08: freeing and reusing a block reclaims capacity without extra page mappings" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const p1 = heap.allocate(256, 16) orelse return error.TestUnexpectedResult;
    const p2 = heap.allocate(256, 16) orelse return error.TestUnexpectedResult;
    @memset(p1[0..256], 0xAA);
    @memset(p2[0..256], 0xBB);

    const maps_before_free = fake.map_calls;
    try heap.deallocate(p1);

    const p1_reused = heap.allocate(200, 16) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromPtr(p1), @intFromPtr(p1_reused));
    try testing.expectEqual(maps_before_free, fake.map_calls);
    for (p2[0..256]) |byte| try testing.expectEqual(@as(u8, 0xBB), byte);
    try assertListInvariants(&heap);

    try heap.deallocate(p1_reused);
    try heap.deallocate(p2);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
}

test "Heap 09: multiple concurrent allocations maintain payload isolation and canary integrity" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const specs = [_]struct { size: usize, alignment: usize, tag: u8 }{
        .{ .size = 32, .alignment = 16, .tag = 0x11 },
        .{ .size = 96, .alignment = 32, .tag = 0x22 },
        .{ .size = 128, .alignment = 64, .tag = 0x33 },
        .{ .size = 250, .alignment = 16, .tag = 0x44 },
        .{ .size = 512, .alignment = 128, .tag = 0x55 },
        .{ .size = 64, .alignment = 16, .tag = 0x66 },
    };

    var ptrs: [specs.len][*]u8 = undefined;
    for (specs, 0..) |spec, i| {
        const ptr = heap.allocate(spec.size, spec.alignment) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % @max(spec.alignment, 16));
        @memset(ptr[0..spec.size], spec.tag);
        ptrs[i] = ptr;
    }

    // Verify zero overlap / corruption across all active allocations and headers.
    for (specs, 0..) |spec, i| {
        for (ptrs[i][0..spec.size]) |byte| {
            try testing.expectEqual(spec.tag, byte);
        }
    }
    try assertListInvariants(&heap);

    // Free in scrambled order while verifying surviving chunks stay intact.
    const free_order = [_]usize{ 2, 0, 4, 1, 5, 3 };
    for (free_order) |idx| {
        try heap.deallocate(ptrs[idx]);
        try assertListInvariants(&heap);
    }

    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(@as(usize, 4 * PAGE_SIZE - HEADER_SIZE), heap.head_block.?.size);
}

test "Heap 10: heap expansion dynamically maps multiple additional pages on demand" {
    var fake = try FakeHeapBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(1); // Only 4056 bytes initially
    try testing.expectEqual(@as(usize, 1), fake.mapped_pages);

    const small = heap.allocate(2048, 16) orelse return error.TestUnexpectedResult;
    @memset(small[0..2048], 0x7E);

    // 10,000 bytes exceeds remaining 1-page capacity -> expands by >= 4 pages via backend.
    const big = heap.allocate(10000, 16) orelse return error.TestUnexpectedResult;
    @memset(big[0..10000], 0x3C);

    try testing.expect(fake.mapped_pages >= 5);
    try testing.expect(!fake.unexpected_addr);
    try testing.expectEqual(@as(u64, fake.mapped_pages) * PAGE_SIZE, heap.mappedBytes());
    for (small[0..2048]) |b| try testing.expectEqual(@as(u8, 0x7E), b);
    for (big[0..10000]) |b| try testing.expectEqual(@as(u8, 0x3C), b);
    try assertListInvariants(&heap);

    try heap.deallocate(small);
    try heap.deallocate(big);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try assertListInvariants(&heap);
}

test "Heap 11: partial page-mapping failure preserves already mapped pages and linked-list state" {
    var fake = try FakeHeapBackend.init(testing.allocator, 12);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(2); // Pages 0..1 mapped

    const held = heap.allocate(6000, 16) orelse return error.TestUnexpectedResult;
    @memset(held[0..6000], 0x81);

    // Allow 2 more mapped pages (indices 2..3), then fail on page 4 during a 4-page expansion.
    fake.fail_after_pages = 4;
    const failed_large = heap.allocate(16384, 16);
    try testing.expectEqual(@as(?[*]u8, null), failed_large);
    try testing.expect(!fake.unexpected_addr);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
    try testing.expectEqual(@as(usize, 1), fake.map_failures);
    try testing.expectEqual(@as(u64, 4 * PAGE_SIZE), heap.mappedBytes());

    // Previously allocated block and newly partially mapped pages must form a coherent linked list.
    for (held[0..6000]) |b| try testing.expectEqual(@as(u8, 0x81), b);
    try assertListInvariants(&heap);
    try fake.expectUnmappedPoisonedFrom(4);

    // A smaller allocation fits inside the 2 partially mapped free pages without triggering new maps.
    const maps_before = fake.map_calls;
    const fits_partial = heap.allocate(4096, 16) orelse return error.TestUnexpectedResult;
    @memset(fits_partial[0..4096], 0x92);
    try testing.expectEqual(maps_before, fake.map_calls);
    try assertListInvariants(&heap);

    try heap.deallocate(fits_partial);
    try heap.deallocate(held);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
}

test "Heap 12: heap capacity exhaustion fails gracefully and recovers on free" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    // Limit max heap size strictly to 6 pages inside the larger 8-page backing pool
    // so allocate's minimum 4-page expansion reaches capped_max cleanly on the second growth.
    const capped_max = 6 * PAGE_SIZE;
    var heap = HeapAllocator.create(fake.baseVaddr(), capped_max, fake.pageMapper());
    try heap.init(2);

    const a = heap.allocate(7000, 16) orelse return error.TestUnexpectedResult;
    @memset(a[0..7000], 0x51);
    const b = heap.allocate(7000, 16) orelse return error.TestUnexpectedResult;
    @memset(b[0..7000], 0x52);
    const c = heap.allocate(9000, 16) orelse return error.TestUnexpectedResult;
    @memset(c[0..9000], 0x54);

    try testing.expectEqual(capped_max, heap.mappedBytes());

    // Further growth exceeds heap_max_size -> allocate must return null cleanly.
    try testing.expectEqual(@as(?[*]u8, null), heap.allocate(4096, 16));
    try testing.expectEqual(capped_max, heap.mappedBytes());
    try testing.expectEqual(@as(usize, 6), fake.mapped_pages);
    try fake.expectUnmappedPoisonedFrom(6);

    for (a[0..7000]) |byte| try testing.expectEqual(@as(u8, 0x51), byte);
    for (b[0..7000]) |byte| try testing.expectEqual(@as(u8, 0x52), byte);
    for (c[0..9000]) |byte| try testing.expectEqual(@as(u8, 0x54), byte);
    try assertListInvariants(&heap);

    // Freeing capacity allows subsequent allocations within existing mapped pages.
    try heap.deallocate(a);
    const a_reused = heap.allocate(6000, 16) orelse return error.TestUnexpectedResult;
    @memset(a_reused[0..6000], 0x53);
    try testing.expectEqual(@as(usize, 6), fake.mapped_pages);
    try assertListInvariants(&heap);
}

test "Heap 13: deallocate validates address bounds, corrupt headers, and repeated free state" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(2);

    const p1 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const p2 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const b2 = try findBlockForPtr(&heap, p2);

    const before_ptr: [*]u8 = @ptrFromInt(heap.heap_start - 16);
    const end_ptr: [*]u8 = @ptrFromInt(heap.current_heap_end);
    try testing.expectError(error.PointerOutOfBounds, heap.deallocate(before_ptr));
    try testing.expectError(error.PointerOutOfBounds, heap.deallocate(end_ptr));

    // Corrupt canary detection on p2 without damaging p1.
    const saved_canary = b2.canary;
    b2.canary = 0xDEADBEEF;
    try testing.expectError(error.CorruptBlockHeader, heap.deallocate(p2));
    b2.canary = saved_canary;

    // Free p1 cleanly, then repeat-free p1 -> rejected (magic changed to MAGIC_FREE).
    try heap.deallocate(p1);
    try testing.expectError(error.CorruptBlockHeader, heap.deallocate(p1));
    try heap.deallocate(p2);
    try assertListInvariants(&heap);
}

test "Heap 14: byte accounting and std.mem.Allocator vtable stay consistent across operations" {
    var fake = try FakeHeapBackend.init(testing.allocator, 10);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);

    const std_alloc = heap.allocator();
    const slice = try std_alloc.alloc(u32, 256);
    for (slice, 0..) |*val, i| {
        val.* = @intCast(i * 10);
    }
    for (slice, 0..) |val, i| {
        try testing.expectEqual(@as(u32, @intCast(i * 10)), val);
    }

    // Unsupported resize / remap behave identically to kernel heap vtable.
    const resize_buf = std.mem.sliceAsBytes(slice);
    try testing.expect(!std_alloc.resize(resize_buf, 2048));
    try testing.expect(std_alloc.remap(resize_buf, 2048) == null);

    const p_extra = heap.allocate(200, 32) orelse return error.TestUnexpectedResult;
    try testing.expect(heap.total_allocated_bytes > heap.total_freed_bytes);
    try assertListInvariants(&heap);

    std_alloc.free(slice);
    try heap.deallocate(p_extra);

    // Once all allocations are freed, freed bytes equal allocated bytes and all blocks merge to one.
    try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(heap.mappedBytes() - HEADER_SIZE, heap.head_block.?.size);
    try assertListInvariants(&heap);
}

test "Heap 15: F-06 rejects interior, prefix padding, header, and tail-slack pointers without mutation" {
    // Part A: split block with non-zero alignment prefix padding
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(2);

        const p1 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
        const p2 = heap.allocate(128, 64) orelse return error.TestUnexpectedResult;
        const p3 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
        @memset(p2[0..128], 0xAB);

        const blk2 = try findBlockForPtr(&heap, p2);
        try testing.expect(blk2.align_offset >= 16);

        const p2_addr = @intFromPtr(p2);
        const freed_before = heap.total_freed_bytes;
        const blocks_before = countBlocks(&heap);

        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p2_addr - 8)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(@intFromPtr(blk2) + 8)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p2_addr + 1)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p2_addr + 64)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p2_addr + 128)));

        // Failed frees must not mutate state or corrupt live payload.
        try testing.expectEqual(freed_before, heap.total_freed_bytes);
        try testing.expectEqual(blocks_before, countBlocks(&heap));
        try testing.expect(!blk2.is_free);
        try testing.expectEqual(MAGIC_USED, blk2.magic);
        for (p2[0..128]) |byte| {
            try testing.expectEqual(@as(u8, 0xAB), byte);
        }

        // Corrupt align_offset bounds check
        const saved_offset = blk2.align_offset;
        blk2.align_offset = @intCast(blk2.size + 1);
        try testing.expectError(error.CorruptBlockHeader, heap.deallocate(p2));
        blk2.align_offset = saved_offset;

        try heap.deallocate(p2);
        try heap.deallocate(p1);
        try heap.deallocate(p3);
        try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
        try assertListInvariants(&heap);
    }

    // Part B: unsplit block containing tail slack after user payload
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 4);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1); // 4056 usable bytes in single free block

        // payload_start = base + 40; align 64 yields align_offset = 24, total_needed = 4024,
        // leaving excess = 32 <= HEADER_SIZE + 32 so the block is NOT split.
        const p_slack = heap.allocate(4000, 64) orelse return error.TestUnexpectedResult;
        const blk = try findBlockForPtr(&heap, p_slack);
        try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
        try testing.expectEqual(PAGE_SIZE - HEADER_SIZE, blk.size);
        try testing.expect(blk.align_offset >= 16);
        try testing.expect(blk.size - @as(usize, blk.align_offset) >= 4032);

        const p_addr = @intFromPtr(p_slack);
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p_addr - 8)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p_addr + 1)));
        try testing.expectError(error.BlockHeaderNotFound, heap.deallocate(@ptrFromInt(p_addr + 4016)));

        try heap.deallocate(p_slack);
        try testing.expectEqual(@as(u32, 0), heap.head_block.?.align_offset);
        try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
        try assertListInvariants(&heap);
    }
}

test "Heap 16: F-11 expansion accounts for alignment padding and coalescing free tail" {
    // Case A: 16336 bytes at 64-byte alignment requires 5 new pages (40 + 24 + 16336 = 16400 > 4 * 4096).
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1);

        // Consume page 0 without leaving a coalescing free tail.
        const p0 = heap.allocate(4000, 16) orelse return error.TestUnexpectedResult;
        const p1 = heap.allocate(16336, 64) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(p1) % 64);
        try testing.expectEqual(@as(usize, 6), fake.mapped_pages);
        @memset(p1[0..16336], 0x5A);
        for (p1[0..16336]) |byte| {
            try testing.expectEqual(@as(u8, 0x5A), byte);
        }

        try fake.expectUnmappedPoisonedFrom(6);
        try assertListInvariants(&heap);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
        try assertListInvariants(&heap);
    }

    // Case B: 16320 bytes at 128-byte alignment crosses 4-page boundary due to alignment padding (40 + 88 + 16320 = 16448).
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1);

        const p0 = heap.allocate(4000, 16) orelse return error.TestUnexpectedResult;
        const p1 = heap.allocate(16320, 128) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(p1) % 128);
        try testing.expectEqual(@as(usize, 6), fake.mapped_pages);
        @memset(p1[0..16320], 0xC3);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
        try assertListInvariants(&heap);
    }

    // Case C: coalescing free tail allows allocation within exact tight capacity (1 new page instead of 2).
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 2);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1); // 4056 free, 1 remaining page

        const p0 = heap.allocate(2000, 16) orelse return error.TestUnexpectedResult; // leaves ~2016-byte coalescing tail
        const p1 = heap.allocate(5000, 16) orelse return error.TestUnexpectedResult; // needs 1 new page with tail, 2 without
        try testing.expectEqual(@as(usize, 2), fake.mapped_pages);
        try testing.expectEqual(@as(usize, 0), fake.map_failures);
        @memset(p1[0..5000], 0x33);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
        try testing.expectEqual(heap.mappedBytes() - HEADER_SIZE, heap.head_block.?.size);
        try assertListInvariants(&heap);
    }
}

test "Heap 17: F-11 clamps expansion batch to remaining headroom and handles partial expansion cleanly" {
    // Part A: 2-page headroom succeeds when batch size (4) exceeds remaining_pages (2).
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 4);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(2);

        const p0 = heap.allocate(8100, 16) orelse return error.TestUnexpectedResult;
        const p1 = heap.allocate(4096, 16) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
        try testing.expectEqual(@as(usize, 0), fake.map_failures);
        try testing.expect(!fake.unexpected_addr);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try assertListInvariants(&heap);
    }

    // Part B: partial expansion (2 of 4 requested batch pages) still satisfies a 2-page allocation once.
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1);

        const p0 = heap.allocate(4000, 16) orelse return error.TestUnexpectedResult;
        fake.fail_after_pages = 3; // allow pages 1..2 during batch=4, fail on page 3

        const p1 = heap.allocate(6000, 16) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 3), fake.mapped_pages);
        try testing.expectEqual(@as(usize, 1), fake.map_failures);
        @memset(p1[0..6000], 0x91);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try assertListInvariants(&heap);
    }

    // Part C: insufficient partial expansion returns null without recursion and preserves mapped free block.
    {
        var fake = try FakeHeapBackend.init(testing.allocator, 8);
        defer fake.deinit();

        var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
        try heap.init(1);

        const p0 = heap.allocate(4000, 16) orelse return error.TestUnexpectedResult;
        fake.fail_after_pages = 2; // allow only 1 expansion page when 2 are needed

        try testing.expect(heap.allocate(6000, 16) == null);
        try testing.expectEqual(@as(usize, 2), fake.mapped_pages);
        try testing.expectEqual(@as(usize, 1), fake.map_failures);

        // Smaller request must reuse the newly mapped page without requiring another map call.
        const p1 = heap.allocate(3000, 16) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 2), fake.mapped_pages);

        try heap.deallocate(p1);
        try heap.deallocate(p0);
        try assertListInvariants(&heap);
    }
}

test "Heap 18: F-11 init validates page count, rejects uninitialized allocations, and safely resumes partial init" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());

    try testing.expectError(error.InvalidInitialPageCount, heap.init(0));
    try testing.expect(!heap.initialized);
    try testing.expectEqual(@as(usize, 0), fake.map_calls);
    try testing.expect(heap.allocate(64, 16) == null);

    try testing.expectError(error.CapacityExceeded, heap.init(9));
    try testing.expect(!heap.initialized);
    try testing.expectEqual(@as(usize, 0), fake.map_calls);
    try testing.expect(heap.allocate(64, 16) == null);

    // Total map failure on page 0
    fake.fail_after_pages = 0;
    try testing.expectError(error.ExpansionFailed, heap.init(4));
    try testing.expect(!heap.initialized);
    try testing.expectEqual(@as(usize, 0), fake.mapped_pages);
    try testing.expect(heap.allocate(64, 16) == null);

    // Partial map failure after 2 of 4 pages keeps state coherent and uninitialized.
    fake.fail_after_pages = 2;
    try testing.expectError(error.ExpansionFailed, heap.init(4));
    try testing.expect(!heap.initialized);
    try testing.expectEqual(@as(usize, 2), fake.mapped_pages);
    try testing.expectEqual(@as(u64, 2 * PAGE_SIZE), heap.mappedBytes());
    try testing.expect(heap.head_block != null);
    try testing.expect(!fake.unexpected_addr);
    try testing.expect(heap.allocate(64, 16) == null);
    try assertListInvariants(&heap);

    // Retry must map only pages 2..3 without remapping pages 0..1.
    fake.fail_after_pages = null;
    try heap.init(4);
    try testing.expect(heap.initialized);
    try testing.expect(!fake.unexpected_addr);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
    for (0..4) |i| {
        try testing.expectEqual(fake.baseVaddr() + @as(u64, i) * PAGE_SIZE, fake.mapped_addrs[i]);
    }
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(@as(u64, 4 * PAGE_SIZE - HEADER_SIZE), heap.head_block.?.size);

    const p = heap.allocate(128, 32) orelse return error.TestUnexpectedResult;
    try heap.deallocate(p);
    try assertListInvariants(&heap);
}

test "Heap 19: F-12 treats align=0 as 16-byte default and rejects invalid sizes/alignments without mutation" {
    var fake = try FakeHeapBackend.init(testing.allocator, 8);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(2);

    // Explicit F-12 compatibility contract: alignment == 0 behaves as 16-byte System V alignment.
    const p_zero = heap.allocate(64, 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p_zero) % 16);
    @memset(p_zero[0..64], 0x55);
    for (p_zero[0..64]) |byte| {
        try testing.expectEqual(@as(u8, 0x55), byte);
    }
    try heap.deallocate(p_zero);

    // Valid alignments (0, < 16 powers of two, and >= 16 powers of two) succeed with >= 16-byte alignment.
    const valid_aligns = [_]usize{ 0, 1, 2, 4, 8, 16, 32, 64, 256 };
    for (valid_aligns) |a| {
        const ptr = heap.allocate(64, a) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % @max(a, 16));
        try heap.deallocate(ptr);
    }

    const mapped_before = fake.mapped_pages;
    const calls_before = fake.map_calls;
    const alloc_before = heap.total_allocated_bytes;
    const freed_before = heap.total_freed_bytes;
    const end_before = heap.current_heap_end;
    const blocks_before = countBlocks(&heap);

    // Invalid size and nonzero non-power-of-two / oversized alignment inputs must fail with zero side effects.
    try testing.expect(heap.allocate(0, 16) == null);
    try testing.expect(heap.allocate(std.math.maxInt(usize), 16) == null);
    try testing.expect(heap.allocate(std.math.maxInt(usize) - 7, 16) == null);
    try testing.expect(heap.allocate(64, 3) == null);
    try testing.expect(heap.allocate(64, 24) == null);
    try testing.expect(heap.allocate(64, @intCast(fake.maxSize() * 2)) == null);
    try testing.expect(heap.allocate(@intCast(fake.maxSize()), 16) == null);
    try testing.expect(heap.allocate(@intCast(fake.maxSize() - HEADER_SIZE + 16), 16) == null);

    try testing.expectEqual(mapped_before, fake.mapped_pages);
    try testing.expectEqual(calls_before, fake.map_calls);
    try testing.expectEqual(alloc_before, heap.total_allocated_bytes);
    try testing.expectEqual(freed_before, heap.total_freed_bytes);
    try testing.expectEqual(end_before, heap.current_heap_end);
    try testing.expectEqual(blocks_before, countBlocks(&heap));
    try fake.expectUnmappedPoisonedFrom(2);
    try assertListInvariants(&heap);
}

test "Heap 20: exact F-11 sequence (init(4), 16320@16, 16336@64) maps 5 additional pages (9 total)" {
    var fake = try FakeHeapBackend.init(testing.allocator, 16);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(4);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);

    const p1 = heap.allocate(16320, 16) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p1) % 16);
    try testing.expectEqual(@as(usize, 4), fake.mapped_pages);
    @memset(p1[0..16320], 0x41);

    const p2 = heap.allocate(16336, 64) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p2) % 64);
    try testing.expectEqual(@as(usize, 9), fake.mapped_pages);
    try testing.expectEqual(@as(usize, 0), fake.map_failures);
    try testing.expect(!fake.unexpected_addr);
    @memset(p2[0..16336], 0x5B);

    for (p1[0..16320]) |byte| {
        try testing.expectEqual(@as(u8, 0x41), byte);
    }
    for (p2[0..16336]) |byte| {
        try testing.expectEqual(@as(u8, 0x5B), byte);
    }
    try fake.expectUnmappedPoisonedFrom(9);
    try assertListInvariants(&heap);

    try heap.deallocate(p2);
    try heap.deallocate(p1);
    try testing.expectEqual(heap.total_allocated_bytes, heap.total_freed_bytes);
    try testing.expectEqual(@as(usize, 1), countBlocks(&heap));
    try testing.expectEqual(9 * PAGE_SIZE - HEADER_SIZE, heap.head_block.?.size);
    try assertListInvariants(&heap);
}

test "Heap 21: F-12 checked split/range guards prevent mutation on corrupted metadata" {
    var fake = try FakeHeapBackend.init(testing.allocator, 2);
    defer fake.deinit();

    var heap = HeapAllocator.create(fake.baseVaddr(), fake.maxSize(), fake.pageMapper());
    try heap.init(2);

    const p1 = heap.allocate(64, 16) orelse return error.TestUnexpectedResult;
    const blk0 = try findBlockForPtr(&heap, p1);
    const free_tail = blk0.next orelse return error.TestUnexpectedResult;

    const saved_tail_size = free_tail.size;
    const saved_tail_next = free_tail.next;
    const saved_tail_prev = free_tail.prev;
    const saved_alloc_bytes = heap.total_allocated_bytes;
    const saved_freed_bytes = heap.total_freed_bytes;

    // Corrupt free block size beyond mapped heap end (triggers checked range/split bounds guard).
    free_tail.size = std.math.maxInt(usize) - 64;
    try testing.expect(heap.allocate(64, 16) == null);

    // Neither links nor accounting counters may mutate on rejected corrupted metadata.
    try testing.expectEqual(saved_tail_next, free_tail.next);
    try testing.expectEqual(saved_tail_prev, free_tail.prev);
    try testing.expectEqual(MAGIC_FREE, free_tail.magic);
    try testing.expect(free_tail.is_free);
    try testing.expectEqual(saved_alloc_bytes, heap.total_allocated_bytes);
    try testing.expectEqual(@as(usize, 2), countBlocks(&heap));

    // Corrupt used block size beyond mapped heap end -> deallocate must reject cleanly without mutation.
    free_tail.size = saved_tail_size;
    const saved_blk0_size = blk0.size;
    blk0.size = @as(usize, PAGE_SIZE) * 10;
    try testing.expectError(error.CorruptBlockHeader, heap.deallocate(p1));
    try testing.expectEqual(saved_freed_bytes, heap.total_freed_bytes);
    try testing.expect(!blk0.is_free);
    try testing.expectEqual(MAGIC_USED, blk0.magic);

    blk0.size = saved_blk0_size;
    try heap.deallocate(p1);
    try assertListInvariants(&heap);
}
