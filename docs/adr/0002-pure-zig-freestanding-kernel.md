# ADR-0002: Pure Zig Freestanding Kernel (No C/C++)

## Status
ACCEPTED
Date: 2026-11-10
Author: Principal OS Architect

## Context
Traditional operating systems rely heavily on C and C++, which lack compile-time memory safety, explicit error tracking, and modern build tooling. To create a modern, reliable, and type-safe operating system, a clean systems language is required.

## Decision
1. All kernel modules, drivers, protocol bindings, and data structures must be authored in pure Zig 0.17.1 targeting `x86_64-freestanding-none`.
2. Zero C or C++ source code is permitted in kernel directories.
3. Assembly language is restricted to low-level CPU operations and interrupt stubs where Zig cannot represent specific instructions (e.g., `iretq`, `lidt`, `invlpg`, `pushfq`/`popfq`).
4. External C libraries and runtimes are forbidden in kernel space.

## Alternatives Considered
- **C99 / C11**: Rejected due to lack of type safety, undefined behavior traps, and build system fragility.
- **Rust**: Rejected for this project to maintain a minimal, uniform build toolchain (Zig compiler acting as its own build system and linker) without complex cargo/cross-compilation dependencies.

## Consequences
### Positive
- Compile-time metaprogramming (`comptime`) replaces macros.
- Explicit error handling unions eliminate unhandled error codes.
- Deterministic struct layouts (`extern struct` and `packed struct`) eliminate endianness and alignment bugs.
### Negative / Trade-offs
- Zig standard library freestanding subset requires custom data structures for complex kernel collections.

## Security Implications
Eliminates whole classes of C memory corruption bugs, buffer overflows from implicit string handling, and uninitialized variable vulnerabilities.

## Testing & Verification Implications
Enforces zero compiler warnings. Verified by compiling kernel with `zig build` and validating all tests with `zig build test`.
