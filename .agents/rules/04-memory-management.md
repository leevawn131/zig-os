---
trigger: glob
globs: "**/kernel/src/mm/**, **/kernel/src/limine.zig, **/kernel/src/main.zig"
---

# 04 - Memory Management Principles

## 1. Physical Memory Management (PMM)
- **Memory Map Sourcing**: The PMM must exclusively derive physical memory layout from the Limine bootloader memory map (`limine_memmap_request`).
- **Physical Memory Access (HHDM)**: Physical memory is never directly accessible at its numeric physical address. All access to physical frames (such as page tables and bitmap storage) must add the Limine Higher Half Direct Map offset: `physToVirt(phys) = phys + hhdm_offset`.
- **Protected Regions**:
  - Memory below 1 MiB (`0x0` to `0x100000`) must remain reserved.
  - Non-USABLE regions (reserved, ACPI, bad memory, kernel image) must be marked USED.
  - The PMM bitmap's own memory footprint must be marked USED immediately upon bitmap placement to prevent self-overwrite.
- **Bootloader Reclaimable Memory**: Memory marked `bootloader_reclaimable` must remain strictly reserved during early boot and must never be reclaimed while Limine structures or boot data are being read.
- **Double-Free & Integrity**: PMM must track frame states and trigger a fatal panic if a frame is freed twice.
- **Zeroing Policy**: Newly allocated physical frames must be zeroed before being exposed to callers to prevent data leaks.

## 2. Virtual Memory Management (VMM)
- **4-Level Paging**: Standard 48-bit x86_64 paging: PML4 (L4) -> PDPT (L3) -> PD (L2) -> PT (L1).
- **Intermediate Table Allocation**: Intermediate page tables must be dynamically allocated from the PMM, cleared to zero, and linked into the hierarchy.
- **TLB Consistency**: Any modification to a present page table entry or unmapping (`unmapPage`) must invalidate the translation lookaside buffer using `cpu.invlpg(vaddr)`.
- **Preservation of Kernel Mappings**: Active page tables must never be replaced without preserving all kernel code/data mappings and the Limine HHDM range.
- **Huge Pages**: 2 MiB and 1 GiB mappings must be handled explicitly with appropriate alignment checks and bitflags (bit 7 `PS`).

## 3. Kernel Heap Allocator
- **Architecture**: Segregated / coalescing dynamic heap allocator mapped in dedicated higher-half space (`0xffff900000000000`).
- **Block Canaries**: Every allocated heap chunk must feature a 32-byte header containing an integrity canary (`0xCAFEBABE`) and state magic (`0x55534544` / `0x46524545`).
- **Bounds Checking & Invalid Free**: The heap allocator must assert header integrity, verify alignment, detect double-frees, and abort on invalid pointers.
- **On-Demand Expansion**: The heap dynamically requests frames from the PMM and maps them into virtual address space via the VMM when capacity is exhausted.
- **Standard Interface**: The allocator must expose a compliant Zig `std.mem.Allocator` vtable.
