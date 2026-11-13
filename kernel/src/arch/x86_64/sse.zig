// Pure hardware-independent x86_64 SSE control register (CR0 / CR4) helpers.
// Shared between Ring 0 CPU initialization and host-side unit tests.

/// CR0.MP (bit 1): Monitor Coprocessor.
pub const CR0_MP_BIT: u64 = 1 << 1;

/// CR0.EM (bit 2): Coprocessor Emulation. Must be 0 for native hardware x87/SSE.
pub const CR0_EM_BIT: u64 = 1 << 2;

/// CR0.TS (bit 3): Task Switched. Must be 0 before executing FPU/SSE instructions.
pub const CR0_TS_BIT: u64 = 1 << 3;

/// CR4.OSFXSR (bit 9): Operating System FXSAVE/FXRSTOR and SSE instruction support.
pub const CR4_OSFXSR_BIT: u64 = 1 << 9;

/// CR4.OSXMMEXCPT (bit 10): Operating System Unmasked SIMD Floating-Point Exception support.
pub const CR4_OSXMMEXCPT_BIT: u64 = 1 << 10;

/// Compute the target CR0 value for x86_64 SSE initialization.
/// Clears CR0.EM (bit 2) and CR0.TS (bit 3), sets CR0.MP (bit 1), and preserves all other bits.
pub fn computeSseCr0(cr0: u64) u64 {
    return (cr0 & ~(CR0_EM_BIT | CR0_TS_BIT)) | CR0_MP_BIT;
}

/// Compute the target CR4 value for x86_64 SSE initialization.
/// Sets CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10), preserving all other bits.
pub fn computeSseCr4(cr4: u64) u64 {
    return cr4 | CR4_OSFXSR_BIT | CR4_OSXMMEXCPT_BIT;
}

/// Return true when CR0 satisfies SSE initialization invariants:
/// CR0.EM == 0, CR0.TS == 0, and CR0.MP == 1.
pub fn isSseCr0Valid(cr0: u64) bool {
    return (cr0 & CR0_EM_BIT) == 0 and
        (cr0 & CR0_TS_BIT) == 0 and
        (cr0 & CR0_MP_BIT) != 0;
}

/// Return true when CR4 satisfies SSE initialization invariants:
/// CR4.OSFXSR == 1 and CR4.OSXMMEXCPT == 1.
pub fn isSseCr4Valid(cr4: u64) bool {
    const required = CR4_OSFXSR_BIT | CR4_OSXMMEXCPT_BIT;
    return (cr4 & required) == required;
}
