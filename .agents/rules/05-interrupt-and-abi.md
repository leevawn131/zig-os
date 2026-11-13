---
trigger: glob
globs: "**/kernel/src/arch/x86_64/idt/**, **/kernel/src/arch/x86_64/interrupts/**, **/kernel/src/arch/x86_64/gdt/**, **/*.s, **/kernel/src/main.zig"
---

# 05 - Interrupt Subsystem & ABI Safety

## 1. IDT & Descriptor Format
- **Table Capacity**: The IDT must contain 256 gates (`0..255`).
- **Gate Attributes**: Gates must be configured as 64-bit Interrupt Gates (type `0x8E`: Present, DPL 0, Interrupt Gate) so interrupts are automatically disabled on entry.
- **IDTR Register Layout**: The x86_64 `lidt` instruction requires a 10-byte (80-bit) structure with 16-bit limit at offset 0 and 64-bit base at offset 2. In Zig, this **MUST** be defined as `packed struct(u80)`. Defining it as `extern struct` introduces 6 bytes of padding that corrupts the loaded base address.

## 2. GDT & Segment Selectors
- **Limine GDT Retention**: Limine 12.9.6 sets the Code Segment selector to `0x28` (40) and Data/Stack selectors to `0x30` (48).
- **No Hardcoded Selectors**: IDT descriptors must dynamically query the active code selector via `gdt.getCs()` rather than assuming `0x08`. Hardcoded `0x08` will trigger a General Protection Fault (`#GP`, error code `0x32`).
- **GDT Replacement Restrictions**: Do not reload or replace Limine's GDT without an explicit technical requirement (e.g. Phase 2 TSS and Ring 3 user segment descriptors).

## 3. Assembly ISR Vector Stubs
- **Error Code Mismatch Prevention**:
  - Vectors **8, 10, 11, 12, 13, 14, 17, 21, 29, 30** push a CPU hardware error code.
  - All other vectors push a dummy `0` error code.
  - Failure to normalize error codes will misalign the stack and cause a fatal crash or triple fault on `iretq`.
- **Exception Vector Reservation & Software `INT n` Policy (`interrupts/vectors.zig`)**:
  - Vectors **0–31** are reserved exclusively for CPU architectural exceptions (`FIRST_EXTERNAL_VECTOR = 32`). External IRQs, APIC/IOAPIC/LAPIC, MSI/MSI-X, IPIs, and general software interrupts must use vectors **>= 32**.
  - Issuing software `INT n` targeting error-code vectors or non-breakpoint reserved exceptions (`0..31` other than controlled `#BP` vector `3`) in kernel source is strictly prohibited and statically verified by `tests/vector_policy_test.zig`.
  - All IDT gates configured for kernel exceptions must pass `idt.validateExceptionGates()` (Present `0x80`, DPL `0`, 64-bit Interrupt Gate `0x0E` -> `0x8E`, current kernel CS selector, cleared reserved fields, distinct per-vector stub offsets).
- **Register Preservation**: All 15 general-purpose registers (`%r15` through `%rax`) must be pushed in the stub and restored before `iretq`.
- **Stack Alignment & Calling Convention**:
  - Hardware pushes SS, RSP, RFLAGS, CS, RIP (5 quadwords).
  - Vector stub pushes dummy/error code and vector number (2 quadwords).
  - Common stub pushes 15 GPRs (15 quadwords).
  - Total stack push = 22 quadwords (an even number), leaving `%rsp` 16-byte aligned before `call x86_64_interrupt_dispatch`.
  - Issue `cld` to clear the Direction Flag prior to entering any Zig handler.
  - Pass the pointer to the `InterruptFrame` in `%rdi`.

## 4. Exception Handling & Diagnostics
- **Page Fault (#PF, Vector 14)**: Handlers must read `CR2` immediately and decode the error code bitfield:
  - Bit 0 (`P`): 0 = non-present page, 1 = page-protection violation.
  - Bit 1 (`W/R`): 0 = read, 1 = write.
  - Bit 2 (`U/S`): 0 = supervisor/kernel, 1 = user mode.
  - Bit 3 (`RSVD`): 1 = reserved bit violation.
  - Bit 4 (`I/D`): 1 = instruction fetch violation (NX).
- **Safe Halting**: Unhandled exceptions must log diagnostic register states and enter a safe `hltLoop` (`cli; hlt; jmp`). Never spin in a busy loop without `hlt`.
- **Legacy 8259 PIC Isolation (`interrupts/pic.zig`)**: Before activating the IDT, early boot must call `pic.remapAndMask()` (with `IF=0`) to remap master/slave 8259 PIC vectors from BIOS default `0x08..0x0F` / `0x70..0x77` to `0x20..0x2F` (`0x20`/`0x28`) and mask all 16 legacy IRQs (`0xFF`/`0xFF`), verified by IMR readback.
- **Interrupt Enablement**: Hardware interrupts must not be enabled (`sti`) until the IDT, ISR stubs, and PIC/APIC controllers are fully initialized.
