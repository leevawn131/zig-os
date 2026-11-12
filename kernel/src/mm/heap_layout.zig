// Hardware-independent kernel heap block header layout definition
// Shared between kernel heap allocator and host unit tests.

pub const BlockHeader = extern struct {
    magic: u32,
    canary: u32,
    size: usize, // Usable payload size in bytes
    is_free: bool,
    padding: [7]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0 },
    next: ?*BlockHeader,
    prev: ?*BlockHeader,
};

pub const HEADER_SIZE: usize = @sizeOf(BlockHeader);
