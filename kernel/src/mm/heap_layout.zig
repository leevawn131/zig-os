// Hardware-independent kernel heap block header layout definition
// Shared between kernel heap allocator and host unit tests.

pub const BlockHeader = extern struct {
    magic: u32,
    canary: u32,
    size: usize, // Usable payload size in bytes
    is_free: bool,
    padding: [3]u8 = [_]u8{ 0, 0, 0 },
    align_offset: u32 = 0, // Byte offset from payload_start to the exact returned allocation pointer
    next: ?*BlockHeader,
    prev: ?*BlockHeader,
};

pub const HEADER_SIZE: usize = @sizeOf(BlockHeader);

comptime {
    if (@sizeOf(BlockHeader) != 40) @compileError("BlockHeader must remain 40 bytes");
    if (@alignOf(BlockHeader) != 8) @compileError("BlockHeader must remain 8-byte aligned");
    if (@offsetOf(BlockHeader, "align_offset") != 20) @compileError("Unexpected BlockHeader align_offset offset");
    if (@offsetOf(BlockHeader, "next") != 24) @compileError("Unexpected BlockHeader next offset");
}
