---
trigger: glob
globs: "**/*.zig, **/*.zon"
---

# 02 - Zig Kernel Development Standards

## 1. Toolchain & API Verification
- **Target Compiler**: Zig 0.17.1 only.
- **Zero Legacy Idioms**: Never copy syntax from Zig 0.11 or older without validating against the installed 0.17.1 compiler.
- **Compiler Hygiene**: Code must compile cleanly with zero warnings or errors under `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`.

## 2. Freestanding Kernel Constraints
- **Target Triple**: `x86_64-freestanding-none`.
- **No Host Library Imports**: The kernel operates without libc. Standard library `@import("std")` is restricted to freestanding constructs (e.g., `std.mem.Allocator`, `std.fmt`, `std.math`, alignment and bitwise operations).
- **Code Model**: Must use `-mcmodel=kernel` to support higher-half 64-bit addressing (`0xffffffff80000000`).
- **Red Zone**: The 128-byte red zone must remain disabled (`-mno-red-zone`). Interrupt handlers preempt execution asynchronously and will corrupt the red zone.
- **No Implicit Allocation**: Dynamic memory must always be explicit via a visible allocator.

## 3. Type System & Hardware Representation
- **Hardware & Bootloader Protocols**: Use `extern struct` for all external ABI contracts (e.g. Limine requests/responses) to ensure deterministic, C-compatible member ordering without Zig struct reordering.
- **Hardware Registers & Bitfields**: Use `packed struct` for hardware registers, MSR bitfields, and page table entries where exact bit widths and bit positions are architecturally required.
- **Packed Struct Alignment Warning**: Be cautious of multi-word structs. Use `packed struct(u80)` or exact integer backing types for architectural register descriptors (such as IDTR/GDTR).
- **Volatile Operations**: Accesses to memory-mapped I/O (MMIO), serial ports, and structures modified asynchronously by hardware or the bootloader must use `volatile` pointers or explicit volatile read/write semantics.

## 4. Error Handling & Safety
- **Explicit Errors**: Functions must return Zig error unions (`!T`) or error sets rather than sentinel return codes (-1 or null).
- **No Silent Suppression**: Never catch errors with empty `catch {}` or discard error results with `_ = expr catch {};`.
- **Undefined Behavior**: Never use `@ptrFromInt` on unverified physical addresses. Always validate pointer bounds before dereference.
- **Panic Integration**: Unrecoverable kernel states must invoke the kernel panic handler with clear diagnostic context, register states, and source line information.
