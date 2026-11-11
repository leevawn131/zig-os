---
trigger: glob
globs: "**/kernel/src/arch/**, **/*.s, **/*.S, **/kernel/linker.ld"
---

# 03 - x86_64 Architectural Invariants

## 1. Virtual Address Space Layout
The 64-bit kernel relies on a higher-half virtual address space:
- **Higher-Half Kernel Base**: `0xffffffff80000000` (-2 GiB). Kernel `.text`, `.rodata`, `.data`, and `.bss` sections are linked and loaded here.
- **Linker Script (`kernel/linker.ld`)**:
  - All sections must be 4 KiB (`0x1000`) page-aligned.
  - PHDRS must enforce page-level W^X permissions:
    - `.text`: `PT_LOAD FLAGS(5)` (Read + Execute).
    - `.rodata`: `PT_LOAD FLAGS(4)` (Read Only).
    - `.data` and `.bss`: `PT_LOAD FLAGS(6)` (Read + Write).
- **Canonical Address Invariant**: Virtual addresses in 48-bit sign-extended paging must have bits 48..63 set to all 0s (user space) or all 1s (kernel space). Non-canonical addresses cause General Protection Faults (`#GP`).

## 2. Control Registers & SIMD Environment
- **FPU & SSE Enablement**: LLVM-generated x86_64 freestanding code regularly emits SSE instructions (`movaps`, `movups`, `xorps`) for struct copying and math formatting.
- **Boot Precondition**: `cpu.enableSse()` must execute at early boot before any formatted serial printing:
  - `CR0.EM` (bit 2) must be cleared to 0 (allow coprocessor instructions).
  - `CR0.MP` (bit 1) must be set to 1 (monitor coprocessor).
  - `CR4.OSFXSR` (bit 9) must be set to 1 (enable FXSAVE/FXRSTOR and SSE instructions).
  - `CR4.OSXMMEXCPT` (bit 10) must be set to 1 (enable unmasked SSE exceptions).

## 3. System V Calling Convention & Stack Alignment
- **Parameter Registers**: First 6 integer/pointer arguments are passed in `%rdi`, `%rsi`, `%rdx`, `%rcx`, `%r8`, `%r9`.
- **Callee-Saved Registers**: `%rbx`, `%rbp`, `%r12`, `%r13`, `%r14`, `%r15`. These must be preserved across function calls.
- **Caller-Saved Registers**: `%rax`, `%rcx`, `%rdx`, `%rsi`, `%rdi`, `%r8`, `%r9`, `%r10`, `%r11`.
- **Direction Flag**: The Direction Flag (`DF`) in `RFLAGS` must be cleared (`cld`) upon entry to any ISR or function according to the SysV ABI.
- **16-Byte Stack Alignment**: `%rsp + 8` must be a multiple of 16 immediately before a `call` instruction. Assembly stubs must account for this alignment.
