# ADR-0001: Higher-Half Kernel Memory Layout & HHDM Access

## Status
ACCEPTED
Date: 2026-11-10
Author: Principal OS Architect

## Context
Operating systems on x86_64 require virtual memory separation between user applications and the operating system kernel. Placing the kernel in the lower half of the 64-bit address space would create address collision when user processes are loaded at low virtual addresses. Furthermore, physical memory must be accessible to kernel page table walkers without remapping individual frames on each allocation.

## Decision
1. The kernel executable is linked and loaded into the top 2 GiB of the 64-bit address space at base `0xffffffff80000000` (`-2 GiB`) using `-mcmodel=kernel`.
2. Physical memory is accessed via the Limine Higher Half Direct Map (HHDM), which maps all physical RAM linearly into a dedicated higher-half virtual address window: `physToVirt(paddr) = paddr + hhdm_offset`.
3. Lower-half memory (`0x0000000000000000` to `0x00007fffffffffff`) is reserved exclusively for future userland task address spaces.

## Alternatives Considered
- **Identity Mapping (1:1)**: Rejected because it exposes low memory, limits user address space, and prevents clean privilege separation.
- **Dynamic Recursive Paging**: Rejected due to 5-level paging incompatibilities, TLB invalidation complexities, and maintenance burden compared to HHDM.

## Consequences
### Positive
- Strict separation of kernel code and userland virtual address ranges.
- Direct, deterministic O(1) translation between physical frames and kernel virtual addresses via HHDM.
- Compatibility with standard x86_64 kernel code model.
### Negative / Trade-offs
- Kernel code cannot use 32-bit absolute addressing pointers; must use RIP-relative or 64-bit sign-extended addressing.

## Security Implications
Prevents userland access to kernel physical frame tables by enforcing page table Supervisor-only bits. Memory below 1 MiB is locked against allocation.

## Testing & Verification Implications
Validated via Limine HHDM response inspection, PMM bitmap placement, and VMM page table walking tests during QEMU boot.
