# ADR-0003: Limine GDT Preservation in Phase 1

## Status
SUPERSEDED by [ADR-0005](0005-kernel-owned-gdt-tss-ist-phase1.md) (2026-11-18)
Date: 2026-11-10
Author: Principal OS Architect

> **Superseding Notice (2026-11-18):** This ADR has been superseded by [ADR-0005: Kernel-Owned 64-Bit GDT, TSS, and IST Exception Stacks in Phase 1](0005-kernel-owned-gdt-tss-ist-phase1.md), which establishes a kernel-owned 64-bit GDT (preserving selectors `0x28` and `0x30` with TSS selector `0x48`), a 104-byte 64-bit TSS, and dedicated `IST1` (`#DF`), `IST2` (`#NMI`), and `IST3` (`#MC`) emergency stacks on the Bootstrap Processor during Phase 1 hardening while keeping Ring 3 deferred to Phase 2.

## Context
Limine 12.9.6 sets up a valid 64-bit flat Global Descriptor Table (GDT) prior to handing execution to the kernel entry point. The Code Segment (CS) selector is initialized to `0x28` (40) and Data/Stack Segments (DS, SS) to `0x30` (48). Replacing the GDT prematurely during Phase 1 adds unnecessary risk and can cause segmentation faults or triple faults if selector attributes or registers fall out of synchronization.

## Decision
1. Retain and preserve Limine's GDT for all Phase 1 kernel mode execution.
2. Provide dynamic inspection helper `gdt.getCs()` to query the active code selector and populate IDT gate descriptors dynamically, avoiding brittle hardcoded assumptions.
3. Defer custom GDT reloading until Phase 2, when a Task State Segment (TSS) and Ring 3 user segment descriptors are strictly required for userland transitions.

## Alternatives Considered
- **Immediate Early GDT Reload**: Reloading a custom GDT during early Phase 1 boot. Rejected because Limine's GDT is already valid and compliant; reloading without TSS provides zero architectural benefit and increases early boot failure risk.
- **Hardcoding Selector 0x08**: Assuming standard selector offsets. Rejected because Limine 12.9.6 uses `0x28`; hardcoding `0x08` immediately causes a `#GP` fault upon first interrupt dispatch.

## Consequences
### Positive
- Zero disruption to bootloader execution environment.
- Safe dynamic extraction of active code selector.
- Clean separation between kernel-only execution (Phase 1) and userland scheduling (Phase 2).
### Negative / Trade-offs
- Task State Segment (TSS) is not active in Phase 1, meaning hardware interrupt stack switching (IST) is deferred to Phase 2.

## Security Implications
Kernel code runs exclusively in Ring 0 during Phase 1. Complete privilege transition architecture will be established when the custom GDT with TSS is introduced in Phase 2.

## Testing & Verification Implications
Verified by executing software interrupts (`int $3`) and page fault tests without triggering `#GP` selector faults.
