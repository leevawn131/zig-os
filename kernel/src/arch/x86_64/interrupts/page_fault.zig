// Hardware-independent x86_64 #PF (Page Fault, Vector 14) error code decoder
// Shared between kernel exception handlers and host unit tests.

pub const PageFaultCause = struct {
    protection_violation: bool,
    write: bool,
    user_mode: bool,
    reserved_bit: bool,
    instruction_fetch: bool,

    pub fn decode(error_code: u64) PageFaultCause {
        return .{
            .protection_violation = (error_code & (1 << 0)) != 0,
            .write = (error_code & (1 << 1)) != 0,
            .user_mode = (error_code & (1 << 2)) != 0,
            .reserved_bit = (error_code & (1 << 3)) != 0,
            .instruction_fetch = (error_code & (1 << 4)) != 0,
        };
    }
};
