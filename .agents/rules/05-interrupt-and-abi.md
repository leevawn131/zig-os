---
trigger: glob
globs: "**/kernel/src/arch/x86_64/idt/**, **/kernel/src/arch/x86_64/interrupts/**, **/kernel/src/arch/x86_64/gdt/**, **/*.s, **/kernel/src/main.zig"
---

# 05 - Interrupt Subsystem & ABI Safety

## 1. IDT & Descriptor Format
- **Table Capacity**: The IDT must contain 256 gates (`0..255`).
- **Gate Attributes**: Gates must be configured as 64-bit Interrupt Gates (type `0x8E`: Present, DPL 0, Interrupt Gate) so interrupts are automatically disabled on entry.
- **IDTR Register Layout**: The x86_64 `lidt` instruction requires a 10-byte (80-bit) structure with 16-bit limit at offset 0 and 64-bit base at offset 2. In Zig, this **MUST** be defined as `packed struct(u80)`. Defining it as `extern struct` introduces 6 bytes of padding that corrupts the loaded base address.

## 2. Kernel-Owned GDT, TSS & Segment Selectors (ADR-0005)
- **BSP Selector Layout**:
  - `0x28` (`KERNEL_CODE_SELECTOR`): 64-bit Kernel Code Segment (DPL=0; `0x9B` Accessed=1 on silicon/KVM or `0x9A` under QEMU TCG `lretq`).
  - `0x30` (`KERNEL_DATA_SELECTOR`): 64-bit Kernel Data/Stack Segment (DPL=0, accessed `0x93` post-load).
  - `0x48` (`TSS_SELECTOR`): 16-byte 64-bit TSS System Descriptor (Available `0x89` pre-`ltr`, Busy `0x8B` post-`ltr`).
  - `0x08..0x20` and `0x38..0x40`: Reserved (`0`, Not-Present) throughout Phase 1 (no Ring 3 descriptors).
- **Hardware Type Separation (`gdt_model.zig`)**: Separate the 10-byte `GDTR` memory operand (`GdtDescriptor`, `extern struct { limit: u16, base: u64 align(1) }`), the 16-byte `TssDescriptor16`, and the 104-byte `Tss64` structure (`iomap_base = 104`).
- **One-Shot Initialization & IST Stacks**: `gdt.init()` executes strictly once on the BSP (never clearing a Busy TSS bit), configures disjoint 16 KiB `.bss` emergency stacks `IST1` (Vector 8 `#DF`), `IST2` (Vector 2 `#NMI`), and `IST3` (Vector 18 `#MC` under policy `MCE-2`), reloads segments cleanly, and executes `cpu.ltr(0x48)` in a separate call after `lretq`.
- **Early IDT & Ordered IST Activation**: `_start()` installs `idt.initEarly()` (`ist = 0` on all 256 gates) immediately after `cpu.cli()`. After `gdt.init()` and `idt.testIstStackSwitch()`, `idt.enableIstGates()` activates `IST1`/`IST2`/`IST3` via ordered per-entry IDT writes while `RFLAGS.IF = 0` (noting `CLI` does not mask `#NMI` or `#MC`, so both early `ist = 0` and activated IST paths remain valid across the transition).
- **No Hardcoded Legacy `0x08` Selectors**: IDT descriptors verify `gdt.getCs() == 0x28`.

## 3. Assembly ISR Vector Stubs
- **Error Code Mismatch Prevention**:
  - Vectors **8, 10, 11, 12, 13, 14, 17, 21, 29, 30** push a CPU hardware error code.
  - All other vectors push a dummy `0` error code.
  - Failure to normalize error codes will misalign the stack and cause a fatal crash or triple fault on `iretq`.
- **Exception Vector Reservation & Software `INT n` Policy (`interrupts/vectors.zig`)**:
  - Vectors **0–31** are reserved exclusively for CPU architectural exceptions (`FIRST_EXTERNAL_VECTOR = 32`). External IRQs, APIC/IOAPIC/LAPIC, MSI/MSI-X, IPIs, and general software interrupts must use vectors **>= 32**.
  - Issuing software `INT n` targeting error-code vectors or non-breakpoint reserved exceptions (`0..31` other than controlled `#BP` vector `3`) in kernel source is strictly prohibited and statically verified by `tests/vector_policy_test.zig`.
  - All IDT gates configured for kernel exceptions must pass `idt.validateExceptionGates()` (Present `0x80`, DPL `0`, 64-bit Interrupt Gate `0x0E` -> `0x8E`, expected IST index via `vectors.expectedIstForVector` [`8->1`, `2->2`, `18->3`, others `0`], current kernel CS selector `0x28`, cleared reserved fields, distinct per-vector stub offsets).
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
- **Safe Halting & Bounded Emergency Logging**: Unhandled exceptions must skip serial output and enter `cpu.haltLoop()` if `!serial.initialized`; otherwise they log diagnostic register states using bounded UART spin polling (`MAX_TX_POLL_SPINS`) in both `handlers.logException()` and `panic.panicFn()` and enter `cpu.haltLoop()` (`cli; hlt; jmp`). Double Fault (`#DF`, Vector 8) and Phase 1 Machine Check (`#MC`, Vector 18) never execute `IRETQ` or recovery hooks. Never spin in an unbounded busy loop.
- **Legacy 8259 PIC Isolation (`interrupts/pic.zig`)**: Before activating the IDT, early boot must call `pic.remapAndMask()` (with `IF=0`) to remap master/slave 8259 PIC vectors from BIOS default `0x08..0x0F` / `0x70..0x77` to `0x20..0x2F` (`0x20`/`0x28`) and mask all 16 legacy IRQs (`0xFF`/`0xFF`), verified by IMR readback.
- **Interrupt Enablement**: Hardware interrupts must not be enabled (`sti`) until the IDT, ISR stubs, and PIC/APIC controllers are fully initialized.
