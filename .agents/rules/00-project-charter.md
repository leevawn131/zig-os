---
trigger: always_on
---

# 00 - Project Charter & Inviolable Invariants

## 1. Mission and Identity
- **Project**: ZIG-OS
- **Goal**: Develop an independent, production-oriented x86_64 operating system from scratch using Zig as the primary language.
- **Scope**: Production systems engineering, strictly avoiding toy, tutorial, or mock implementations.

## 2. Inviolable Technical Stack
The following components and versions are permanently pinned. No AI agent may change, upgrade, or downgrade these without explicit human approval and an accepted ADR:
- **Host OS**: Ubuntu 26.04 LTS (x86_64)
- **Kernel Language**: Zig 0.17.1
- **Target Architecture**: x86_64 (AMD64)
- **Target Triple**: `x86_64-freestanding-none`
- **Bootloader**: Limine 12.9.6
- **Emulator**: QEMU (`qemu-system-x86_64`)
- **Debugger**: GDB
- **Linker**: LLVM LLD (`use_lld = true`)

## 3. Core Architectural Rules
1. **Zero C/C++ in Kernel**: All kernel modules, drivers, protocol bindings, and data structures must be written in pure Zig.
2. **Minimal Assembly**: Assembly is restricted to low-level architecture stubs (`stubs.s`, context switches) and privileged CPU instructions where Zig primitives do not exist.
3. **Strict Architecture Isolation**: All x86_64-specific assembly, register operations, and segment structures belong exclusively in `kernel/src/arch/x86_64/`. Generic subsystems must remain architecture-agnostic.
4. **No Mock or Placeholder Implementations**: Stubs or empty functions must not be marked as complete. Any incomplete functionality must be explicitly documented with a compilation or runtime error preventing silent misbehavior.
5. **Phase Milestone Gating**: No agent may begin work on an unauthorized phase. All phase completions require independent verification, empirical evidence, and explicit human sign-off.
