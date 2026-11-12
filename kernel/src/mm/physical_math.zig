// Pure physical memory and frame allocator indexing calculations
// Hardware-independent pure logic module shared between kernel and host unit tests.

pub const PAGE_SIZE: u64 = 4096;

/// Calculates total page frames required to span a given byte length/address ceiling.
pub inline fn totalPagesFromBytes(bytes: u64) usize {
    return @intCast((bytes + PAGE_SIZE - 1) / PAGE_SIZE);
}

/// Calculates required allocation bitmap size in bytes for a given frame count.
pub inline fn bitmapSizeBytes(frame_count: usize) usize {
    return (frame_count + 7) / 8;
}

/// Converts a physical byte address to its 4 KiB physical page frame index.
pub inline fn physToFrame(paddr: u64) usize {
    return @intCast(paddr / PAGE_SIZE);
}

/// Converts a frame index to its corresponding byte offset within the allocation bitmap.
pub inline fn frameToByteIndex(frame: usize) usize {
    return frame / 8;
}

/// Converts a frame index to its bit offset (0..7) within its bitmap byte.
pub inline fn frameToBitIndex(frame: usize) u3 {
    return @truncate(frame % 8);
}
