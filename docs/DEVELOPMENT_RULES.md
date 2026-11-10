# ZIG-OS Development & Engineering Rules

## 1. Core Principles

This project develops an independent operating system from scratch. It is **NOT** a tutorial or a toy project. Every line of code is treated with production rigor.

1. **Modular Architecture**
   - Kernel subsystems (memory, drivers, scheduling, process management) must remain strictly decoupled.
   - Code must communicate across well-defined interfaces and data structures.

2. **Strict Architecture Isolation**
   - All architecture-dependent code belongs strictly in `kernel/src/arch/<arch>/` (e.g., `kernel/src/arch/x86_64/`).
   - Generic kernel code (such as schedulers, VFS, and drivers) must never directly execute architecture-specific inline assembly or read model-specific registers without abstraction.

3. **Zero Unverified Memory Assumptions**
   - Never assume physical addresses are identity-mapped or contiguous unless confirmed by the bootloader memory map or page tables.
   - Respect higher-half addressing contracts (`0xffffffff80000000` for kernel code, HHDM for physical memory access).

4. **No Fake Hardware Functionality**
   - Every hardware interaction must follow the hardware specification (e.g., 16550 UART datasheet, x86_64 SDM).
   - Never write mock hardware replies or simulate fake devices in production kernel paths.

5. **No Placeholder Implementations Marked Complete**
   - If a subsystem is pending future phases (e.g., paging, scheduler), it must be explicitly marked as unfulfilled. Do not mark empty functions or stub returns as "completed".

6. **Proper Compilation & Warning Hygiene**
   - Zero compiler warnings or errors allowed.
   - The build must compile cleanly under all optimization levels (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`).

7. **Document Architectural Decisions**
   - Record design rationale, memory layouts, register contracts, and protocol agreements in `docs/ARCHITECTURE.md`.

8. **Pin All External Dependencies**
   - External tools (such as Limine 12.9.6) must be pinned to exact versions. Protocol headers and binary assets must match the exact version tag.

9. **Deterministic, Reproducible Builds**
   - The build system must produce consistent binaries from a clean checkout. No hidden global host state or unversioned toolchains.

10. **Automated Verification Before Commit**
    - Every change must pass automated smoke testing (`./scripts/test-boot.sh`).
    - Never claim a milestone has passed without test logs and empirical evidence.

---

## 2. Zig Systems Programming Rules

- **Use Zig 0.17.1 Idioms**: Do not copy legacy Zig snippets (0.11 or older). Verify all declarations against the installed 0.17.1 compiler.
- **Hardware Protocols**: Use `extern struct` for protocol layouts (such as Limine requests and responses) to guarantee C-compatible memory ordering.
- **Register Bitfields**: Use `packed struct` for hardware registers, MSR bitfields, and page table entries where bit alignment is required.
- **Pointers & Volatile**: Use `volatile` when accessing memory-mapped I/O or structures altered asynchronously by hardware or the bootloader.
- **Red Zone**: Always disable the 128-byte red zone (`-mno-red-zone`) for kernel code so interrupt handlers do not corrupt stack frames.
- **Inline Assembly**: Keep assembly blocks as short as possible. Use typed operand constraints.
