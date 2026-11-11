---
trigger: model_decision
description: "Security architecture, privilege separation (Ring 0 / Ring 3), input validation, fault isolation, memory boundary defense, and canary integrity."
---

# 07 - Security Architecture & Safety Guidelines

## 1. Privilege Separation & Hardware Rings
- **Ring Separation**: Kernel runs strictly in Ring 0; userland applications run strictly in Ring 3.
- **Page Table Protections**:
  - Kernel pages must have the `User/Supervisor` bit (bit 2) set to 0. Any userland access will trigger an immediate `#PF`.
  - Enforce W^X (Write XOR Execute) memory policies: Kernel `.text` is mapped RX (Read+Execute, No-Write); `.rodata` is mapped R (Read-Only, NX); `.data`, `.bss`, and heap are mapped RW (Read+Write, NX).
  - Enable the No-Execute (NX) bit via `EFER.NXE` (bit 11).

## 2. Memory Boundary Defense & Pointer Validation
- **User Pointer Sanitization**: Kernel code must never blindly dereference a pointer passed from user space or untrusted hardware.
- **Canonical Address Validation**: Verify that user pointers reside strictly below the canonical userland limit (`0x00007fffffffffff`).
- **Zero-Allocation Policy**: Physical memory allocated by PMM or heap must be cleared to zero to prevent sensitive kernel data leakage between processes.
- **Heap Integrity Canaries**: Dynamic heap blocks must embed active canary words (`0xCAFEBABE`). Any canary alteration upon deallocation must immediately abort execution.
- **Arithmetic Overflow**: All address calculations, page counts, and buffer offsets must employ overflow-checked arithmetic (`@addWithOverflow`, `std.math.add`).

## 3. Fault Isolation & Crash Resilience
- **User Exception Containment**: An unhandled exception originating in Ring 3 (e.g. user segfault) must terminate only the offending thread or process. It must never panic the kernel.
- **Hardware Error Isolation**: System bus errors, PCI errors, or invalid I/O responses must be logged and handled without compromising core scheduling or memory state.
- **No Fake Security**: Never implement placeholder security routines or dummy permission checks that silently return success. Unimplemented security features must fail closed with an explicit error.
