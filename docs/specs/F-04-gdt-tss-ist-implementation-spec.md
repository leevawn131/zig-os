# ZIG-OS — F-04 Implementation Specification: Kernel-Owned 64-Bit GDT, TSS, and IST1–IST3 Stacks

> - **Governing ADR:** [ADR-0005: Kernel-Owned 64-Bit GDT, TSS, and IST Exception Stacks in Phase 1](../adr/0005-kernel-owned-gdt-tss-ist-phase1.md) (Supersedes [ADR-0003](../adr/0003-limine-gdt-preservation-phase1.md))
> - **Original Author:** Gemini 4 Argon | **Revision Provenance:** Gemini 4 Neon (`2026-11-19` Final Correction Pass; `2026-11-20` Owner Option A CS Accessed-Bit Policy & Implementation Status Update)
> - **Target Finding:** `F-04` (`VERIFIED` / `MEDIUM` / `P1` in [VERIFIED_FINDING_REGISTER.md](../audit/VERIFIED_FINDING_REGISTER.md))
> - **Processor Scope:** Single **Bootstrap Processor (BSP)** only (Phase 1 Hardening)
> - **Phase Gates:** Phase 1 = F-04 implementation completed, pending independent review and Project Owner acceptance (`Pending Human Review`) | Phase 2 = `NOT AUTHORIZED`
> - **Implementation Status:** `IMPLEMENTED BY GEMINI 4 HYDROGEN — AWAITING INDEPENDENT GPT-6 REVIEW & PROJECT OWNER ACCEPTANCE`
> - **Verification Status (2026-11-20):**
>   - **Implementation:** Completed by Gemini 4 Hydrogen against ADR-0005 and this specification.
>   - **Build / Unit / QEMU Results (Reported by Gemini 4 Hydrogen):** Four-mode builds (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`), host unit tests (`zig build test`), production QEMU `test-boot`, and standalone isolated QEMU 10.2.1 QMP `test-df` were executed and reported passing by Gemini 4 Hydrogen (agent-reported; not yet independently signed off).
>   - **Independent GPT-6 Review:** **Pending** (awaiting independent technical review and Project Owner acceptance).
>   - **Bare-Metal Hardware Verification:** **Not completed** (`NOT HARDWARE VERIFIED`). Final acceptance and `PRODUCTION READY` status are **not** claimed.

---

## 1. Preserved Architectural Decisions & Non-Negotiable Constraints

1. **Approved Architecture Decisions (`ADR-0005`):**
   - `KERNEL_CODE_SELECTOR = 0x28`, `KERNEL_DATA_SELECTOR = 0x30`, `TSS_SELECTOR = 0x48`.
   - Reserved (`0`, Not-Present) GDT slots at `0x08..0x20` (indices `1..4`) and `0x38..0x40` (indices `7..8`).
   - 104-byte 64-bit `Tss64` with `iomap_base = 104`.
   - Three disjoint 16 KiB (`16384` B, `align(16)`) `.bss` IST stacks on the BSP: `IST1` (Vector 8 `#DF`), `IST2` (Vector 2 `#NMI`), `IST3` (Vector 18 `#MC`).
   - `MCE-2` policy: preserve Limine's `CR4.MCE` bit (neither set nor clear it); always provision `IST3` for Vector 18; apply **Phase 1 Kernel Policy** (no recovery, no `IRETQ`, bounded serial log, safe `cpu.haltLoop()`).
   - Single **Bootstrap Processor (BSP)** scope.
2. **Strict Phase 1 Boundaries:**
   - Do **not** implement Ring 3, `SYSCALL`/`SYSRET`, or task scheduling.
   - Do **not** reclaim `.bootloader_reclaimable` memory in PMM.
   - Maintain `RFLAGS.IF = 0` throughout Phase 1.
   - Preserve all existing self-tests (`cpu.testSseCr0Init`, `pic.remapAndMask`, `idt.testPageFaultHandling`, `pmm.testPmm`, `vmm.testVmm`, `heap.testHeap`, and all 67 existing host unit tests including `vector_policy_test`).
   - Preserve the exact boot smoke-test marker `[IDT] 256 interrupt gates configured and verified.` required by [scripts/lib/qemu-runner.sh:141](../../scripts/lib/qemu-runner.sh#L141) and preserve all `F-14` fresh-build and 3-way SHA-256 provenance guarantees across both production and isolated DF-test artifacts.
   - Do **not** edit `docs/audit/VERIFIED_FINDING_REGISTER.md` during code implementation (audit register updates occur only after independent source/diff review).

---

## 2. Explicit Separation of Hardware Structures & Pure Model Module (`N-04`, `N-06`, `ITR-3`, `ITR-4`)

### 2.1. Hardware-Independent Module: `kernel/src/arch/x86_64/gdt/gdt_model.zig` (NEW FILE)
Because Zig 0.17.1's default self-hosted x86_64 backend (used by host `zig build test` in [build.zig:124-230](../../build.zig#L124-L230)) rejects `sgdt` (`error: invalid mnemonic: 'sgdt'`), whereas the freestanding kernel executables use `.use_llvm = true` ([build.zig:55](../../build.zig#L55)), all pure GDT/TSS types, constants, descriptor encoders, and validation helpers **MUST** reside in `kernel/src/arch/x86_64/gdt/gdt_model.zig` with **zero privileged inline assembly**:

1. **Exact 10-Byte `GDTR` Memory Operand (`lgdt`/`sgdt` — `ITR-4`):**
   ```zig
   /// Architectural 10-byte (80-bit) GDTR pseudo-descriptor operand for `lgdt` and `sgdt`.
   /// Distinct from the 16-byte 64-bit TSS System Descriptor inside the GDT.
   pub const GdtDescriptor = extern struct {
       limit: u16,
       base: u64 align(1),
   };
   ```
   - Mandatory `comptime` assertions:
     - `@sizeOf(GdtDescriptor) == 10`
     - `@offsetOf(GdtDescriptor, "limit") == 0`
     - `@offsetOf(GdtDescriptor, "base") == 2`
2. **Exact 104-Byte `Tss64` Structure (Intel SDM Vol. 3A Fig. 8-11):**
   ```zig
   pub const Tss64 = extern struct {
       reserved0: u32 = 0,
       rsp0: u64 align(1) = 0,
       rsp1: u64 align(1) = 0,
       rsp2: u64 align(1) = 0,
       reserved1: u64 align(1) = 0,
       ist1: u64 align(1) = 0,
       ist2: u64 align(1) = 0,
       ist3: u64 align(1) = 0,
       ist4: u64 align(1) = 0,
       ist5: u64 align(1) = 0,
       ist6: u64 align(1) = 0,
       ist7: u64 align(1) = 0,
       reserved2: u64 align(1) = 0,
       reserved3: u16 = 0,
       iomap_base: u16 = @sizeOf(Tss64),
   };
   ```
   - Mandatory `comptime` assertions:
     - `@sizeOf(Tss64) == 104` (`0x68`)
     - `@offsetOf(Tss64, "rsp0") == 0x04`
     - `@offsetOf(Tss64, "ist1") == 0x24`
     - `@offsetOf(Tss64, "ist2") == 0x2C`
     - `@offsetOf(Tss64, "ist3") == 0x34`
     - `@offsetOf(Tss64, "iomap_base") == 0x66`
3. **Exact 16-Byte 64-Bit TSS System Descriptor (`TssDescriptor16` — `ITR-4`):**
   ```zig
   /// Architectural 16-byte (128-bit) 64-bit TSS System Descriptor occupying GDT indices 9 and 10 (0x48..0x57).
   /// Distinct from the 10-byte GDTR memory operand (`GdtDescriptor`).
   pub const TssDescriptor16 = extern struct {
       low: u64,
       high: u64,
   };
   ```
   - Mandatory `comptime` assertion: `@sizeOf(TssDescriptor16) == 16`.
   - Constants:
     - `GDT_ENTRY_COUNT: usize = 11` (`88` bytes total; `GDT_LIMIT: u16 = 87` [`0x57`]).
     - `KERNEL_CODE_SELECTOR: u16 = 0x28` (Index `5`).
     - `KERNEL_DATA_SELECTOR: u16 = 0x30` (Index `6`).
     - `TSS_SELECTOR: u16 = 0x48` (Indices `9..10`).
     - `KERNEL_CODE_DESCRIPTOR: u64 = 0x0020_9A00_0000_0000` (`P=1, DPL=0, S=1, Type=0xA, L=1, D=0`).
     - `KERNEL_DATA_DESCRIPTOR: u64 = 0x0000_9200_0000_0000` (`P=1, DPL=0, S=1, Type=0x2`).
     - `DESCRIPTOR_ACCESSED_BIT: u64 = @as(u64, 1) << 40` (Bit 40 of segment descriptors: `0x9A` [Accessed clear] vs. `0x9B` [Accessed set] for CS; `0x92` vs. `0x93` for `DS`/`SS`. While x86-64 hardware typically sets bit 40 upon loading segment selectors, observed **QEMU TCG 10.2.1** `lretq` did not write back CS bit 40 [`0x9A`]; this specification does **not** claim that all physical CPUs or hypervisors exhibit QEMU TCG behavior).
     - `TSS_ACCESS_AVAILABLE: u8 = 0x89` (`P=1, DPL=0, S=0, Type=0b1001`).
     - `TSS_ACCESS_BUSY: u8 = 0x8B` (`P=1, DPL=0, S=0, Type=0b1011`).
     - `TSS_MIN_LIMIT: u20 = @sizeOf(Tss64) - 1` (`103` / `0x0067`).
   - Pure Functions:
     - `encodeTssDescriptor(base: u64, limit: u20) TssDescriptor16`: encodes `Limit[15:0]`, `Base[31:0]`, `Access = 0x89`, `Limit[19:16]`, `Flags = 0x0` in `low`, and `Base[63:32]` in `high[31:0]` with `high[63:32] == 0`.
     - `tssAccessByte(tss_low: u64) u8`: extracts `@truncate((tss_low >> 40) & 0xFF)`.
     - `isCodeDescriptorValidPostLoad(entry: u64) bool` (**Owner-Approved Option A Policy**): verifies `(entry & ~DESCRIPTOR_ACCESSED_BIT) == KERNEL_CODE_DESCRIPTOR`. Accepts both `0x9A` (Accessed bit clear) and `0x9B` (Accessed bit set), ignoring **only** bit 40 (`DESCRIPTOR_ACCESSED_BIT`) during structural comparison while requiring every other descriptor bit to match `KERNEL_CODE_DESCRIPTOR` (`0x0020_9A00_0000_0000`) exactly. This accommodates observed **QEMU TCG 10.2.1** behavior where `lretq` did not write back the Accessed bit, without claiming that all physical CPUs or hypervisors exhibit QEMU TCG behavior. The `Accessed` bit is **not** used as a security or privilege invariant in this Phase 1 validator.
     - `isDataDescriptorValidPostLoad(entry: u64) bool`: verifies `(entry & ~DESCRIPTOR_ACCESSED_BIT) == KERNEL_DATA_DESCRIPTOR` and `(entry & DESCRIPTOR_ACCESSED_BIT) != 0` (**strict `0x93` requirement preserved**; not weakened by Option A).
     - `isTssDescriptorBusyValid(low: u64, high: u64, expected_base: u64, expected_limit: u20) bool`: compares against `encodeTssDescriptor(expected_base, expected_limit)` with `Access` transitioned from `0x89` to `0x8B` (`low == (expected.low | (@as(u64, 1) << 41))` and `high == expected.high`; **strict `0x8B` Busy TSS requirement preserved**; not weakened by Option A).
     - `areRangesDisjoint(a_base: u64, a_top: u64, b_base: u64, b_top: u64) bool`: verifies `a_base < a_top`, `b_base < b_top`, and `(a_top <= b_base or b_top <= a_base)` without any wrapping address additions.

### 2.2. One-Shot BSP GDT/TSS Runtime Adapter: `kernel/src/arch/x86_64/gdt/gdt.zig`
- Re-exports `gdt_model` types/constants (`KERNEL_CODE_SELECTOR`, `KERNEL_DATA_SELECTOR`, `TSS_SELECTOR`, `GdtDescriptor`, `Tss64`, etc.) and preserves `getCs()`, `getDs()`, `getSs()`.
- Static writable `.data`/`.bss` storage (BSP-only):
  - `pub var gdt_table: [gdt_model.GDT_ENTRY_COUNT]u64 align(16)` initialized with `0` at indices `0..4, 7..10`, `KERNEL_CODE_DESCRIPTOR` at index `5`, and `KERNEL_DATA_DESCRIPTOR` at index `6`.
  - `pub var gdtr: gdt_model.GdtDescriptor` (`10` bytes).
  - `pub var kernel_tss: gdt_model.Tss64 align(16) = .{};` (placed in permanently mapped `.bss`; `align(16)` is a kernel design choice).
  - `pub var ist1_stack: [16384]u8 align(16) = undefined;` (`IST1` -> Vector 8 `#DF`).
  - `pub var ist2_stack: [16384]u8 align(16) = undefined;` (`IST2` -> Vector 2 `#NMI`).
  - `pub var ist3_stack: [16384]u8 align(16) = undefined;` (`IST3` -> Vector 18 `#MC`).
  - `var initialized: bool = false;`
- Stack top computation (`ist1Top()`, `ist2Top()`, `ist3Top()`) uses checked arithmetic (`std.math.add(u64, @intFromPtr(&istN_stack), istN_stack.len) catch @panic("GDT: IST stack address overflow")`) so `istNBase() < istNTop()` and `(istNTop() - istNBase()) == 16384` are guaranteed without wrap-around.
- **Strict One-Shot `gdt.init()` Contract (`ITR-3`, `N-04`):**
  1. Enforce one-shot invariant:
     ```zig
     if (initialized) {
         @panic("GDT: gdt.init() is one-shot on BSP and must not be called twice");
     }
     ```
     **Never** clear an already-Busy bit (`0x8B -> 0x89`) to simulate idempotency.
  2. Populate `kernel_tss` with `ist1 = ist1Top()`, `ist2 = ist2Top()`, `ist3 = ist3Top()`, and `iomap_base = @sizeOf(gdt_model.Tss64)` (`104`), leaving all other fields `0`.
  3. Encode the 16-byte Available TSS descriptor (`Access = 0x89`) via `gdt_model.encodeTssDescriptor(@intFromPtr(&kernel_tss), gdt_model.TSS_MIN_LIMIT)` and store into `gdt_table[9]` (`low`) and `gdt_table[10]` (`high`).
  4. Verify `gdt_model.tssAccessByte(gdt_table[9]) == gdt_model.TSS_ACCESS_AVAILABLE` (`0x89`).
  5. Initialize `gdtr = .{ .limit = gdt_model.GDT_LIMIT, .base = @intFromPtr(&gdt_table) }`.
  6. Load `GDTR` and reload all segment registers atomically inside a private helper `loadGdtAndReloadKernelSegments(&gdtr)` in `gdt.zig` (guarded by `comptime` assertions that `gdt_model.KERNEL_CODE_SELECTOR == 0x28` and `gdt_model.KERNEL_DATA_SELECTOR == 0x30`, keeping `lgdt` and `lretq` in the same inline assembly block so the compiler cannot emit instructions between `lgdt` and segment reload):
     ```zig
     asm volatile (
         \\ lgdt (%[gdtr])
         \\ pushq $0x28
         \\ leaq 1f(%%rip), %%rax
         \\ pushq %%rax
         \\ lretq
         \\ 1:
         \\ movw $0x30, %%ax
         \\ movw %%ax, %%ds
         \\ movw %%ax, %%es
         \\ movw %%ax, %%ss
         \\ movw $0x00, %%ax
         \\ movw %%ax, %%fs
         \\ movw %%ax, %%gs
         :
         : [gdtr] "r" (&gdtr),
         : .{ .rax = true, .memory = true }
     );
     ```
     *(Using `movw $0x00, %%ax` avoids modifying `RFLAGS`; `lgdt (%[gdtr])` reads `[gdtr]` before `%rax` is overwritten. Per AMD64 APM Vol. 2 §4.5.3 vs. Intel SDM Vol. 3A §3.4.4, loading null selector `0x00` into `FS`/`GS` is vendor-dependent with respect to `FS.base`/`GS.base` and is never used as a portable base-clearing mechanism; Limine hands off `FS.base = GS.base = 0`.)*
  7. **Separately** invoke `cpu.ltr(gdt_model.TSS_SELECTOR);` (`0x48`) after `lretq` has restored `%rsp` and exited the inline assembly block (preventing any register-allocator aliasing between `[tss_sel]` and `%rax`).
  8. Set `initialized = true;`.
- **`gdt.testGdtAndTss() bool` Verification:**
  - Confirm `initialized == true`.
  - Execute `cpu.sgdt(&live_gdtr)` and verify `live_gdtr.limit == gdt_model.GDT_LIMIT` (`87`) and `live_gdtr.base == @intFromPtr(&gdt_table)`.
  - Verify `getCs() == 0x28`, `getDs() == 0x30`, `getSs() == 0x30`.
  - Verify `gdt_model.isCodeDescriptorValidPostLoad(gdt_table[5])` (Option A: accepts `0x9A` or `0x9B`, ignoring only bit 40 while matching every other bit of `KERNEL_CODE_DESCRIPTOR` exactly) and `gdt_model.isDataDescriptorValidPostLoad(gdt_table[6])` (strict `0x93`), and verify reserved slots `0..4, 7..8` are `0`.
  - Execute `cpu.str()` and verify `cpu.str() == gdt_model.TSS_SELECTOR` (`0x48`).
  - Verify `gdt_model.isTssDescriptorBusyValid(gdt_table[9], gdt_table[10], @intFromPtr(&kernel_tss), gdt_model.TSS_MIN_LIMIT)` (confirming hardware transitioned `0x89 -> 0x8B`).
  - Verify `kernel_tss.iomap_base == 104`, `kernel_tss.ist1 == ist1Top()`, `kernel_tss.ist2 == ist2Top()`, `kernel_tss.ist3 == ist3Top()`, all 3 tops are 16-byte aligned, and the three `[base, top)` intervals are pairwise disjoint via `gdt_model.areRangesDisjoint`.

---

## 3. CPU Primitives, Pre-SSE Early Path, and Bounded Serial / Panic Logging (`N-03`)

### 3.1. `kernel/src/arch/x86_64/cpu.zig`
Add privileged Ring 0 helpers (with `.{ .memory = true }` clobbers on `lgdt`, `sgdt`, `ltr`):
- `pub inline fn lgdt(desc_ptr: *const anyopaque) void`
- `pub inline fn sgdt(desc_ptr: *anyopaque) void`
- `pub inline fn ltr(selector: u16) void`
- `pub inline fn str() u16`

### 3.2. Bounded UART Emergency Logging: `kernel/src/drivers/serial/serial.zig` & `kernel/src/panic.zig`
1. In `kernel/src/drivers/serial/serial.zig`:
   - Add `pub const MAX_TX_POLL_SPINS: u32 = 100_000;`.
   - Add a pure, host-testable polling helper (`pub fn waitForTxReady(ctx: anytype, comptime readyFn: fn (@TypeOf(ctx)) bool, max_spins: u32) bool`) in `serial.zig` (zero `cpu` / I/O port references in its body, so Zig's lazy declaration analysis compiles it cleanly on host `zig build test`) to verify bounded spin exhaustion when `LSR.THRE` stays `0`.
   - Add bounded emergency output routines that **NEVER call `init()` when `!initialized`** and abort cleanly returning `false` on spin timeout:
     - `pub fn tryWriteByteBounded(byte: u8, max_spins: u32) bool`
     - `pub fn tryWriteStringBounded(str: []const u8, max_spins: u32) bool`
     - `pub fn tryWriteHexBounded(val: u64, max_spins: u32) bool`
     - `pub fn tryWriteDecBounded(val: u64, max_spins: u32) bool`
   - Behavior: If `!initialized`, return `false` immediately. For `'\n'`, poll `isTransmitEmpty()` at most `max_spins` times before writing `'\r'`, then poll at most `max_spins` times before writing `byte`. If either poll loop exhausts `max_spins`, return `false` without issuing `outb`.
2. In `kernel/src/panic.zig` (`N-03` fix):
   - Replace `_ = serial.init();` + unbounded `serial.writeString`/`writeHex` with:
     - `if (!serial.initialized) { if (!serial.init()) cpu.haltLoop(); }` (attempts `serial.init()` at most once if uninitialized; if COM1 is absent/faulty, halts immediately without busy-waiting).
     - Emit all panic lines via `serial.tryWriteStringBounded(..., serial.MAX_TX_POLL_SPINS)` and `serial.tryWriteHexBounded(..., serial.MAX_TX_POLL_SPINS)`; if any bounded write returns `false`, abort remaining logging immediately and call `cpu.haltLoop()`.
3. In `kernel/src/arch/x86_64/idt/handlers.zig`:
   - Immediately upon entering the unhandled-exception path in `x86_64_interrupt_dispatch()`:
     ```zig
     if (!serial.initialized) {
         cpu.haltLoop();
     }
     ```
   - `logException(frame)` uses bounded serial output (`tryWriteStringBounded`/`tryWriteHexBounded`/`tryWriteDecBounded`); if any write returns `false`, `logException()` returns immediately so `x86_64_interrupt_dispatch()` enters `cpu.haltLoop()` in bounded time.
   - **Pre-SSE Safety Proof:** Because [build.zig:9-19](../../build.zig#L9-L19) disables `.x87`/`.mmx`/`.sse`/`.sse2`/`.avx`/`.avx2` and enables `.soft_float` (`F-01`), and `stubs.s` uses only GPR instructions, an exception between Step 2 (`idt.initEarly()`) and Step 3 (`cpu.enableSse()`) hits `if (!serial.initialized) cpu.haltLoop();` with zero SIMD/x87 instructions.

---

## 4. Eight-Step `_start()` Sequence & Reordered Step 7 (`N-05`, `N-08`)

Exact runtime sequence in `kernel/src/main.zig` (`RFLAGS.IF = 0` throughout):

1. **Step 1:** `cpu.cli()`
2. **Step 2:** `idt.initEarly()` — Populates all 256 IDT gates (`0x8E`, `selector = gdt.getCs() == 0x28`, **`ist = 0`**) and runs `cpu.lidt(&idtr)` immediately after `cpu.cli()`.
3. **Step 3:** `cpu.enableSse()` — Clears `CR0.EM`/`CR0.TS`, sets `CR0.MP`/`CR4.OSFXSR`/`CR4.OSXMMEXCPT`, preserving Limine's `CR4.MCE` bit (`MCE-2`).
4. **Step 4:** `serial.init()` — Initializes COM1 UART and sets `serial.initialized = true` (or halts in `cpu.haltLoop()`).
5. **Step 5:** Limine Base Revision 3 check, boot banner, `cpu.testSseCr0Init()`, `limine.memmap_request` check, and `pic.remapAndMask()`.
6. **Step 6:** `gdt.init()` (one-shot) & `gdt.testGdtAndTss()` — Halts on failure; emits `[GDT] Kernel GDT, 64-bit TSS, and IST1-IST3 stacks initialized and verified.`.
7. **Step 7 (`N-05` reordered internals):**
   - **7.1:** `idt.testExceptionDispatch()` (`int $3`, `ist = 0`, `test_skip_instruction_len == 0`).
   - **7.2:** `idt.testIstStackSwitch()` (tests `idt_table[3].ist = 1, 2, 3` via `int $3` and restores `0`, executed **before** `idt.enableIstGates()` while `TR` is live and `idt_table[2/8/18].ist == 0` so asynchronous `#NMI` cannot overwrite `IST2` during `test_ist == 2`).
   - **7.3:** `idt.enableIstGates()` — Activates `IST1`, `IST2`, and `IST3` through **ordered per-entry IDT updates** (not a single atomic multi-entry transaction) while `RFLAGS.IF = 0`: `idt_table[8].ist = 1` (`#DF`), `idt_table[2].ist = 2` (`#NMI`), `idt_table[18].ist = 3` (`#MC`), leaving all other 253 gates at `ist = 0`. Prerequisite: `kernel_tss` and all three IST stacks must already be fully provisioned and loaded (`Step 6`) before modifying any IDT entry. Because `CLI` masks maskable interrupts but does **not** mask `#NMI` or `#MC`, an `#NMI` or `#MC` arriving during the transition window may observe either the prior valid (`ist = 0`) gate or the newly activated IST gate for its vector; both the early handling path and the activated IST handling path must remain valid throughout the transition window.
   - **7.4:** `idt.validateExceptionGates()` — Validates all 256 gates against `vectors.expectedIstForVector(@intCast(i))` (confirming `8->1`, `2->2`, `18->3`, `3->0`, all others `0`).
   - **7.5:** `idt.testPageFaultHandling()` (unchanged `#PF` Fault test with `test_skip_instruction_len = 2`).
   - Emit exact marker (`N-08`): `[IDT] 256 interrupt gates configured and verified.`.
8. **Step 8:**
   - **8.1:** `pmm.init()` & `pmm.testPmm()`.
   - **8.2:** `vmm.testVmm()`.
   - **8.3:** `heap.init(4)` & `heap.testHeap()`.
   - **8.4:**
     - In production build (`build_options.test_double_fault == false`, built into `zig-out/bin/kernel.elf`): emit `[STATUS] Kernel initialization complete.` and `zig-os:~$ `, then `cpu.haltLoop()`.
     - In isolated DF-test build (`build_options.test_double_fault == true`, built exclusively via `zig build iso-df-test` / `zig build test-df` into `zig-out/df-test/kernel-df-test.elf`): invoke `idt.runStandaloneDoubleFaultTest()` (`noreturn`).

---

## 5. `INT $3` Trap Test, Overflow-Safe Range Validation, & Atomic CAS Double Fault Test (`N-01`, `N-02`, `N-07`, `ITR-1`, `ITR-2`)

### 5.1. Overflow-Safe Stack/Frame Containment Helpers (`kernel/src/arch/x86_64/interrupts/vectors.zig`)
All frame-inside-stack and frame-disjoint-from-stack checks across **both** `#DF` forensic validation and `testExceptionDispatch()`/`testIstStackSwitch()` **MUST** use pure, host-testable fail-closed helpers using checked arithmetic (`std.math.add`) or bounded subtraction, rejecting empty frames (`frame_size == 0`) and `u64` range overflows (never unchecked `frame_addr + @sizeOf(InterruptFrame) <= stack_top`):

```zig
/// Overflow-safe verification that non-empty contiguous `[frame_addr, frame_addr + frame_size)`
/// lies strictly within half-open `[stack_base, stack_top)`.
/// Rejects invalid stack bounds (`stack_base > stack_top`) and empty frames (`frame_size == 0`,
/// including when `frame_addr == stack_top`). Performs zero wrapping address additions.
pub fn isFrameWithinStack(
    frame_addr: u64,
    frame_size: u64,
    stack_base: u64,
    stack_top: u64,
) bool {
    if (stack_base > stack_top or frame_size == 0) return false;
    if (frame_addr < stack_base) return false;
    if (frame_addr > stack_top) return false;
    const remaining: u64 = stack_top - frame_addr;
    return frame_size <= remaining;
}

/// Overflow-safe verification that non-empty contiguous `[frame_addr, frame_addr + frame_size)`
/// is a valid non-overflowing range with zero byte overlap against `[stack_base, stack_top)`.
/// Fails closed (returns `false`) if `stack_base > stack_top`, `frame_size == 0`, or
/// `frame_addr + frame_size` overflows `u64`.
pub fn isFrameDisjointFromStack(
    frame_addr: u64,
    frame_size: u64,
    stack_base: u64,
    stack_top: u64,
) bool {
    if (stack_base > stack_top or frame_size == 0) return false;

    const frame_end = std.math.add(
        u64,
        frame_addr,
        frame_size,
    ) catch return false;

    return frame_end <= stack_base or frame_addr >= stack_top;
}
```
- **Mandatory Host Boundary Unit Tests for `isFrameWithinStack` and `isFrameDisjointFromStack`:**
  1. `frame_addr = 0` (against high canonical stack and low stack).
  2. `frame_addr = std.math.maxInt(u64), frame_size = 1`: `isFrameDisjointFromStack` **MUST return `false`** because `[frame_addr, frame_addr + frame_size)` overflows `u64`; `isFrameWithinStack` **MUST return `false`** (both for normal stacks and `stack_top = std.math.maxInt(u64)`).
  3. Any frame range whose end overflows `u64` (e.g., `frame_addr = std.math.maxInt(u64) - 16, frame_size = 176`): both `isFrameDisjointFromStack` and `isFrameWithinStack` **MUST return `false`**.
  4. `frame_addr = stack_top, frame_size = 0`: `isFrameWithinStack` **MUST return `false`** (empty frame rejected).
  5. `frame_size = 0` (at any address, e.g., `0`, `stack_base`, `stack_top`): `isFrameDisjointFromStack` **MUST return `false`** (empty frame rejected).
  6. Frame starts before stack (`frame_addr = stack_base - 1`, non-zero `frame_size`).
  7. Frame starts after stack (`frame_addr = stack_top` and `frame_addr = stack_top + 1`, non-overflowing `frame_size`).
  8. Frame flush at stack bottom (`frame_addr = stack_base`, `frame_size <= stack_top - stack_base` -> `isFrameWithinStack == true`).
  9. Frame flush at stack top (`frame_addr = stack_top - frame_size` -> `isFrameWithinStack == true`).
  10. Frame exceeds stack top by exactly 1 byte (`frame_addr = stack_top - frame_size + 1` -> `isFrameWithinStack == false`).
  11. Invalid stack range (`stack_base > stack_top` -> both `isFrameWithinStack` and `isFrameDisjointFromStack` return `false`).

### 5.2. `INT $3` Trap Verification (`idt.testExceptionDispatch()` & `idt.testIstStackSwitch()`)
- In `handlers.zig`, `frame.rip += test_skip_instruction_len` is executed **ONLY when `frame.vector == vectors.PAGE_FAULT_VECTOR` (`14`)**, never for Vector 3 (`#BP` Trap, whose hardware-pushed `RIP` already points to the instruction immediately following `int $3`).
- Vectors `8` (`#DF`) and `18` (`#MC`) are explicitly rejected from the recoverable `test_expected_vector` hook (never return / never `IRETQ`).
- Both `testExceptionDispatch()` (`ist = 0`) and `testIstStackSwitch()` (`test_ist` in `{ 1, 2, 3 }`) execute:
  ```zig
  asm volatile (
      \\ movq %%rsp, %[pre_rsp]
      \\ leaq 1f(%%rip), %[expected_rip]
      \\ int $3
      \\ 1:
      \\ movq $0x5A5A5A5AA5A5A5A5, %[marker]
      \\ movq %%rsp, %[post_rsp]
      : [pre_rsp] "=&r" (pre_rsp),
        [post_rsp] "=&r" (post_rsp),
        [expected_rip] "=&r" (expected_resume_rip),
        [marker] "=&r" (resume_marker),
      :
      : .{ .memory = true }
  );
  ```
- Assert all 6 invariants after restoring `idt_table[3].ist = 0`:
  1. `test_occurred == true`
  2. `test_observed_rip == expected_resume_rip`
  3. `resume_marker == 0x5A5A5A5AA5A5A5A5`
  4. `test_observed_rsp == pre_rsp` and `post_rsp == pre_rsp`
  5. `test_observed_cs == 0x28` and `test_observed_ss == 0x30`
  6. Overflow-safe frame location:
     - When `ist == 0`: `vectors.isFrameDisjointFromStack(test_observed_frame_addr, @sizeOf(InterruptFrame), istN_base, istN_top)` is `true` for all `N` in `{ 1, 2, 3 }`.
     - When `test_ist == N`: `vectors.isFrameWithinStack(test_observed_frame_addr, @sizeOf(InterruptFrame), istN_base, istN_top)` is `true`.
- *(Documentation & code comment rule: Exercising `IST3` via `int $3` validates hardware `TSS.IST3` stack switching only and must never be claimed to trigger a real hardware Machine Check Exception).*

### 5.3. Verified VMM APIs (No Changes to `virtual.zig` or `virtual_core.zig`)
Directly verified in [kernel/src/mm/virtual.zig](../../kernel/src/mm/virtual.zig#L8-L71) and [kernel/src/mm/virtual_core.zig](../../kernel/src/mm/virtual_core.zig#L16-L285):
- `vmm.PAGE_SIZE: u64` (`4096`), `vmm.Flags.WRITABLE: u64` (`1 << 1`), `vmm.PageTable`, `vmm.MapError`, `vmm.UnmapError`
- `vmm.isCanonical(virt: u64) bool`
- `vmm.getActivePml4() *vmm.PageTable`
- `vmm.mapPage(pml4: *vmm.PageTable, virt: u64, phys: u64, flags: u64) vmm.MapError!void`
- `vmm.unmapPage(pml4: *vmm.PageTable, virt: u64) vmm.UnmapError!void`
- `vmm.virtToPhys(pml4: *vmm.PageTable, virt: u64) ?u64` (checks 4 KiB, 2 MiB `HUGE`, and 1 GiB `HUGE`)
- `vmm.isMapped(pml4: *vmm.PageTable, virt: u64) bool`
- From [kernel/src/mm/physical.zig](../../kernel/src/mm/physical.zig#L144-L161): `pmm.allocPage() ?u64`, `pmm.freePage(paddr: u64) void`.

### 5.4. Standalone Assembly Trigger: `kernel/src/arch/x86_64/idt/df_trigger.s` (NEW FILE, DF-Test Subgraph Only)
```asm
.intel_syntax noprefix
.text
.global x86_64_trigger_df_unmapped_stack
.type x86_64_trigger_df_unmapped_stack, @function
x86_64_trigger_df_unmapped_stack:
    mov rsp, rdi
    push 0
.global x86_64_trigger_df_ud2_sentinel
x86_64_trigger_df_ud2_sentinel:
    ud2
```
- Linked **exclusively** into `df_kernel_mod` in `build.zig` (`df_kernel_mod.addAssemblyFile(b.path("kernel/src/arch/x86_64/idt/df_trigger.s"));`), **never** into production `kernel_mod`.
- Declared inside a `comptime`-guarded struct in `idt.zig` (analyzed only when `build_options.test_double_fault == true`):
  ```zig
  extern fn x86_64_trigger_df_unmapped_stack(unmapped_rsp: u64) callconv(.{ .x86_64_sysv = .{} }) noreturn;
  extern const x86_64_trigger_df_ud2_sentinel: u8;
  ```
- Under x86-64 SysV ABI, `unmapped_rsp` is passed in `%rdi`. Zero prologue/epilogue before `mov rsp, rdi` (must be verified via `objdump -d` on `zig-out/df-test/kernel-df-test.elf`, and absence of all `x86_64_trigger_df_*` symbols must be verified via `nm` on `zig-out/bin/kernel.elf`).

### 5.5. Atomic CAS `DfTestState` Machine, Fail-Closed Frame Release (`ITR-1`), & Two-Phase `N-02` PASS (`N-01`, `N-02`, `ITR-2`)

1. **Dedicated Single 4 KiB Test Page:**
   - `DF_TEST_UNMAPPED_PAGE: u64 = 0x0000_0042_0001_0000` (distinct from `vmm.testVmm()`'s `0x0000_0042_0000_0000`).
   - `DF_TEST_UNMAPPED_RSP: u64 = DF_TEST_UNMAPPED_PAGE + 0x800` (`0x0000_0042_0001_0800`, 16-byte aligned). Both the 8-byte `push 0` access (`[+0x7F8..+0x800)`) and the 48-byte `#PF` #1 hardware frame push (`[+0x7D0..+0x800)`) lie strictly inside this single 4 KiB page (`2000` B above base, `2048` B below top).

2. **Atomic CAS State Machine (`kernel/src/arch/x86_64/interrupts/vectors.zig`, Zig 0.17.1-verified syntax):**
   Every state change **MUST** execute through an atomic strong compare-and-exchange (`std.atomic.Value(DfTestState).cmpxchgStrong(expected, next, .seq_cst, .seq_cst)`), never via non-atomic assignment or unguarded load-then-store. Terminal states (`.passed_halting`, `.failed`, `.aborted_async`, `.nested_fault`) are strictly immutable and cannot be overwritten:
   ```zig
   const std = @import("std");

   pub const DfTestState = enum(u8) {
       inactive = 0,
       preparing = 1,
       armed = 2,
       handling_df = 3,
       passed_halting = 4,
       failed = 5,
       aborted_async = 6,
       nested_fault = 7,

       pub fn isTerminal(self: DfTestState) bool {
           return switch (self) {
               .passed_halting, .failed, .aborted_async, .nested_fault => true,
               .inactive, .preparing, .armed, .handling_df => false,
           };
       }
   };

   pub const DfDispatchAction = enum(u8) {
       normal_kernel_dispatch,
       verify_df_forensics,
       log_fail_and_halt,
       log_nested_fail_and_halt,
       log_inconclusive_and_halt,
       halt_silent,
   };

   pub fn isValidDfTransition(from: DfTestState, to: DfTestState) bool {
       return switch (from) {
           .inactive => to == .preparing,
           .preparing => to == .armed or to == .failed or to == .aborted_async,
           .armed => to == .handling_df or to == .failed or to == .aborted_async,
           .handling_df => to == .passed_halting or to == .failed or to == .aborted_async or to == .nested_fault,
           .passed_halting, .failed, .aborted_async, .nested_fault => false,
       };
   }

   pub const DfStateMachine = struct {
       state: std.atomic.Value(DfTestState) = std.atomic.Value(DfTestState).init(.inactive),

       pub fn load(self: *const DfStateMachine) DfTestState {
           return self.state.load(.seq_cst);
       }

       /// Conditional atomic transition via strong CAS (.seq_cst).
       /// Returns true strictly if prior state equaled `expected` and was replaced with `next`.
       /// Never overwrites any terminal state.
       pub fn tryTransition(self: *DfStateMachine, expected: DfTestState, next: DfTestState) bool {
           if (expected.isTerminal() or !isValidDfTransition(expected, next)) return false;
           return self.state.cmpxchgStrong(expected, next, .seq_cst, .seq_cst) == null;
       }

       /// Dispatcher entry decision using conditional atomic CAS.
       /// Once in any terminal state, refuses state mutation and stops further exception processing.
       pub fn onException(self: *DfStateMachine, vector: u8) DfDispatchAction {
           const cur = self.load();
           const is_async = (vector == NMI_VECTOR or vector == MACHINE_CHECK_VECTOR);
           return switch (cur) {
               .inactive => .normal_kernel_dispatch,
               .passed_halting, .failed, .aborted_async, .nested_fault => .halt_silent,
               .preparing => if (is_async)
                   (if (self.tryTransition(.preparing, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
               else
                   (if (self.tryTransition(.preparing, .failed)) .log_fail_and_halt else .halt_silent),
               .armed => if (vector == DOUBLE_FAULT_VECTOR)
                   (if (self.tryTransition(.armed, .handling_df)) .verify_df_forensics else .halt_silent)
               else if (is_async)
                   (if (self.tryTransition(.armed, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
               else
                   (if (self.tryTransition(.armed, .failed)) .log_fail_and_halt else .halt_silent),
               .handling_df => if (is_async)
                   (if (self.tryTransition(.handling_df, .aborted_async)) .log_inconclusive_and_halt else .halt_silent)
               else
                   (if (self.tryTransition(.handling_df, .nested_fault)) .log_nested_fail_and_halt else .halt_silent),
           };
       }

       /// Final PASS transition via atomic CAS (.handling_df -> .passed_halting).
       /// Caller MUST emit PASS strictly only when this returns true.
       pub fn completeDfPass(self: *DfStateMachine) bool {
           return self.tryTransition(.handling_df, .passed_halting);
       }

       /// Final FAIL transition when hardware forensics fail (.handling_df -> .failed).
       pub fn completeDfFail(self: *DfStateMachine) bool {
           return self.tryTransition(.handling_df, .failed);
       }
   };
   ```

3. **Normative `DfTestState` Exception Transition Table (Matches `ADR-0005` Verbatim):**

   | Current State | New Exception | CAS Transition | New State | Dispatcher Handling |
   |---|---|---|---|---|
   | `.inactive` | Any | *(none)* | `.inactive` | Normal Phase 1 kernel exception dispatch |
   | `.preparing` | `#NMI` (`2`), `#MC` (`18`) | `.preparing -> .aborted_async` | `.aborted_async` | Emit bounded `[DF-TEST] INCONCLUSIVE:` + `logException`, halt |
   | `.preparing` | Any synchronous exception | `.preparing -> .failed` | `.failed` | Emit bounded `[DF-TEST] FAIL:` + `logException`, halt |
   | `.armed` | `#DF` (`8`) | `.armed -> .handling_df` | `.handling_df` | If CAS succeeds: begin 6-factor overflow-safe hardware forensic verification; if CAS fails: halt silently |
   | `.armed` | `#NMI` (`2`), `#MC` (`18`) | `.armed -> .aborted_async` | `.aborted_async` | Emit bounded `[DF-TEST] INCONCLUSIVE:` + `logException`, halt |
   | `.armed` | `#UD` (`6`), `#PF` (`14`), other sync | `.armed -> .failed` | `.failed` | Emit bounded `[DF-TEST] FAIL:` (distinguishing `x86_64_trigger_df_ud2_sentinel`) + `logException`, halt |
   | `.handling_df` | `#NMI` (`2`), `#MC` (`18`) | `.handling_df -> .aborted_async` | `.aborted_async` | Emit bounded `[DF-TEST] INCONCLUSIVE: Asynchronous hardware event interrupted #DF verification.` (**NEVER `FAIL`**), halt |
   | `.handling_df` | Other synchronous exception | `.handling_df -> .nested_fault` | `.nested_fault` | Emit bounded `[DF-TEST] FAIL: Nested synchronous exception during #DF verification.`, halt |
   | `.handling_df` | Nested `#DF` (`8`) | `.handling_df -> .nested_fault` | `.nested_fault` | Emit bounded `[DF-TEST] FAIL: Nested #DF during #DF verification.`, halt |
   | `.passed_halting` | **Any exception** | *(forbidden — terminal)* | **Unchanged** | Immediately `cpu.haltLoop()` silently (never overwrite, never emit `FAIL`/`INCONCLUSIVE`, never continue dispatcher) |
   | `.failed` | **Any exception** | *(forbidden — terminal)* | **Unchanged** | Immediately `cpu.haltLoop()` silently |
   | `.aborted_async` | **Any exception** | *(forbidden — terminal)* | **Unchanged** | Immediately `cpu.haltLoop()` silently |
   | `.nested_fault` | **Any exception** | *(forbidden — terminal)* | **Unchanged** | Immediately `cpu.haltLoop()` silently |

4. **Strict Preparation & Fail-Closed Frame Release (`idt.runStandaloneDoubleFaultTest() noreturn`, `ITR-1`):**
   1. Execute `if (!df_state.tryTransition(.inactive, .preparing)) cpu.haltLoop();`.
   2. Verify `vmm.isCanonical(DF_TEST_UNMAPPED_PAGE)` and `vmm.isCanonical(DF_TEST_UNMAPPED_RSP)`. On failure: CAS `.preparing -> .failed`, log bounded `[DF-TEST] FAIL: Non-canonical DF test address.`, halt.
   3. Check `const pml4 = vmm.getActivePml4();`. If `vmm.isMapped(pml4, DF_TEST_UNMAPPED_PAGE)` or `vmm.virtToPhys(pml4, DF_TEST_UNMAPPED_PAGE) != null`: **NEVER call `vmm.unmapPage()`**; CAS `.preparing -> .failed`, emit bounded `[DF-TEST] FAIL: Unexpected pre-existing mapping at test page; refusing to unmap.`, and call `cpu.haltLoop()`.
   4. Allocate test frame: `const phys = pmm.allocPage() orelse { _ = df_state.tryTransition(.preparing, .failed); log "[DF-TEST] FAIL: PMM allocPage failed"; cpu.haltLoop(); };`.
   5. Map test-owned page: `vmm.mapPage(pml4, DF_TEST_UNMAPPED_PAGE, phys, vmm.Flags.WRITABLE) catch { ... }` — on error, **only** call `pmm.freePage(phys)` if `!vmm.isMapped(pml4, DF_TEST_UNMAPPED_PAGE) and vmm.virtToPhys(pml4, DF_TEST_UNMAPPED_PAGE) == null` (`ITR-1`); CAS `.preparing -> .failed`, log `[DF-TEST] FAIL: VMM mapPage failed`, and halt.
   6. Confirm test mapping succeeded: verify `vmm.virtToPhys(pml4, DF_TEST_UNMAPPED_PAGE) == phys`. If not, **do NOT call `pmm.freePage(phys)`**; CAS `.preparing -> .failed`, log `[DF-TEST] FAIL: Test mapping verification failed`, and halt.
   7. Unmap test-owned page: `vmm.unmapPage(pml4, DF_TEST_UNMAPPED_PAGE) catch { ... }` — on error, **do NOT call `pmm.freePage(phys)`** (`ITR-1`); CAS `.preparing -> .failed`, log `[DF-TEST] FAIL: VMM unmapPage failed; refusing to free mapped frame`, and halt.
   8. **Verify mapping removal BEFORE freeing physical frame (`ITR-1`):**
      - Check `!vmm.isMapped(pml4, DF_TEST_UNMAPPED_PAGE) and vmm.virtToPhys(pml4, DF_TEST_UNMAPPED_PAGE) == null`.
      - If either check fails: **do NOT call `pmm.freePage(phys)`**; CAS `.preparing -> .failed`, log `[DF-TEST] FAIL: Residual mapping present after unmapPage; refusing to free frame`, and halt.
      - Only after removal is verified: call `pmm.freePage(phys)`.
   9. Verify IDT/TSS preconditions: `idt_table[14].ist == 0`, `idt_table[8].ist == 1`, `gdt.kernel_tss.ist1 == gdt.ist1Top()`. On failure: CAS `.preparing -> .failed`, log `[DF-TEST] FAIL: IDT/TSS precondition failed`, and halt.
   10. Execute `if (!df_state.tryTransition(.preparing, .armed)) cpu.haltLoop();` and invoke `x86_64_trigger_df_unmapped_stack(DF_TEST_UNMAPPED_RSP)`.

5. **Two-Phase CAS `#DF` Forensic Verification & `PASS` Sequence (`N-02`, `ITR-2`):**
   1. Dispatcher calls `df_state.onException(frame.vector)`. For Vector 8 (`#DF`), this performs atomic CAS `.armed -> .handling_df`.
   2. **Only if that CAS succeeds** (`action == .verify_df_forensics`) is `#DF` confirmed to have occurred while `.armed`.
   3. Call pure, host-testable `vectors.validateDfForensics(evidence)` checking all 6 hardware invariants without integer overflow/underflow:
      - `evidence.vector == vectors.DOUBLE_FAULT_VECTOR` (`8`)
      - `evidence.error_code == 0`
      - `vectors.isFrameWithinStack(evidence.frame_addr, evidence.frame_size, evidence.ist1_base, evidence.ist1_top) == true`
      - `evidence.cs == 0x28` and `evidence.ss == 0x30`
      - `evidence.unmapped_rsp >= 0x30` (underflow guard)
      - `evidence.frame_rsp >= evidence.unmapped_rsp - 0x30 and evidence.frame_rsp <= evidence.unmapped_rsp`
      - `evidence.cr2 >= evidence.unmapped_rsp - 0x30 and evidence.cr2 < evidence.unmapped_rsp`
   4. If `validateDfForensics` returns `true`:
      - Execute atomic CAS `.handling_df -> .passed_halting` via `df_state.completeDfPass()`.
      - **Strictly only if `completeDfPass()` returns `true`**: emit bounded `[DF-TEST] PASS: Double Fault caught on IST1 stack.` + bounded `CR2` line + bounded `logException(frame)`, then enter permanent `cpu.haltLoop()` (**never `IRETQ`**).
      - **If `completeDfPass()` returns `false`** (e.g., `#NMI`/`#MC` won `.handling_df -> .aborted_async`): **strictly DO NOT emit `PASS`**; immediately enter `cpu.haltLoop()`.
   5. If `validateDfForensics` returns `false`:
      - Execute `df_state.completeDfFail()` (CAS `.handling_df -> .failed`).
      - Only if `true`: emit bounded `[DF-TEST] FAIL: Vector 8 (#DF) forensic verification failed.` + bounded `CR2` + bounded `logException(frame)`; then enter `cpu.haltLoop()`.

---

## 6. Complete Build Artifact Isolation, Dependency Graph, & QMP `HLT` Verification (`N-07`, `N-08`)

### 6.1. Disjoint Artifact & Temporary Resource Table (Zero Production Overwrite)

| Resource | Production (`prod`, default) | Standalone DF-Test (`df-test`, isolated) |
|---|---|---|
| Zig Root Module | `kernel_mod` (`test_double_fault = false`, `stubs.s` only) | `df_kernel_mod` (`test_double_fault = true`, `stubs.s` + `df_trigger.s`) |
| Kernel ELF | `zig-out/bin/kernel.elf` | `zig-out/df-test/kernel-df-test.elf` |
| ISO Staging Root | `build/iso_root` (`build/iso_root/boot/kernel.elf`) | `build/df-test/iso_root` (`build/df-test/iso_root/boot/kernel.elf`) |
| Bootable Hybrid ISO | `build/zig-os.iso` | `build/zig-os-df-test.iso` |
| Packaging Temp Dir | `mktemp -d "${TMPDIR:-/tmp}/zig-os-pkg-prod-XXXXXX"` | `mktemp -d "${TMPDIR:-/tmp}/zig-os-pkg-df-test-XXXXXX"` |
| Provenance Temp Dir | `mktemp -d "${TMPDIR:-/tmp}/zig-os-provenance-prod-XXXXXX"` | `mktemp -d "${TMPDIR:-/tmp}/zig-os-provenance-df-test-XXXXXX"` |
| QEMU Serial Log | `mktemp "${TMPDIR:-/tmp}/zig-os-boot-XXXXXX.log"` | `mktemp "${TMPDIR:-/tmp}/zig-os-df-test-XXXXXX.log"` |
| QEMU QMP Socket Dir | *(not required for `test-boot`)* | `mktemp -d "${TMPDIR:-/tmp}/zig-os-df-qmp-XXXXXX"` (`qmp.sock`) |
| `F-14` 3-Way SHA-256 Triad | `zig-out/bin/kernel.elf` == `build/iso_root/boot/kernel.elf` == `build/zig-os.iso:/boot/kernel.elf` | `zig-out/df-test/kernel-df-test.elf` == `build/df-test/iso_root/boot/kernel.elf` == `build/zig-os-df-test.iso:/boot/kernel.elf` |

### 6.2. Explicit Zig 0.17.1 Build Dependency Graph (`build.zig`)
Rather than mutating the production `kernel_mod` with a global CLI option that could overwrite `zig-out/bin/kernel.elf` or `build/zig-os.iso`, `build.zig` defines **two structurally independent compile/install/ISO subgraphs** (using Zig 0.17.1-verified `std.Build.Step.InstallArtifact.Options` `.dest_dir = .{ .override = .{ .custom = "df-test" } }`):

```text
[Production Subgraph — default `zig build`, `iso`, `run`, `debug`, `test-boot`]
  prod_options (test_double_fault = false)
    -> kernel_mod (kernel/src/main.zig + stubs.s ONLY — NEVER df_trigger.s)
      -> kernel (`kernel.elf`, .use_llvm = true, .use_lld = true, kernel/linker.ld)
        -> install_kernel (default .bin -> zig-out/bin/kernel.elf)
          -> b.getInstallStep()  [+ log_optimize]
            -> iso_cmd (`bash scripts/package-iso.sh --profile prod --optimize <mode>`)
              -> iso_step (`iso`)
                -> run_cmd (`bash scripts/lib/qemu-runner.sh run --optimize <mode>`) -> run_step (`run`)
                -> debug_cmd (`bash scripts/lib/qemu-runner.sh debug --optimize <mode>`) -> debug_step (`debug`)
                -> test_cmd (`bash scripts/lib/qemu-runner.sh test-boot --optimize <mode>`) -> boot_test_step (`test-boot`)

[Isolated DF-Test Subgraph — ONLY `zig build iso-df-test` or `zig build test-df`]
  df_options (test_double_fault = true)
    -> df_kernel_mod (kernel/src/main.zig + stubs.s + df_trigger.s)
      -> df_kernel (`kernel-df-test.elf`, .use_llvm = true, .use_lld = true, kernel/linker.ld)
        -> install_df_kernel (.dest_dir = .{ .override = .{ .custom = "df-test" } } -> zig-out/df-test/kernel-df-test.elf)
           [CRITICAL: NOT attached to b.getInstallStep()!]
          -> df_iso_cmd (`bash scripts/package-iso.sh --profile df-test --optimize <mode>`)
             [depends strictly on &install_df_kernel.step — NEVER on b.getInstallStep() or install_kernel!]
            -> df_iso_step (`iso-df-test`)
              -> test_df_cmd (`bash scripts/lib/qemu-runner.sh test-df --optimize <mode>`)
                -> test_df_step (`test-df`)

[Host Unit Test Subgraph — `zig build test`]
  unit_tests (+ gdt_model, vectors, serial.waitForTxReady), pmm_tests, vmm_tests, heap_tests, vector_policy_tests
    -> unit_test_step (`test`) [uses Zig 0.17.1 host backend, zero `.use_llvm = true`]
```

- **Packaging & Provenance Script Changes (Preserving `F-14` & Backward Compatibility):**
  - `scripts/package-iso.sh`: Accept optional `--profile <prod|df-test>` (default `prod`) parsed before passing remaining args to `resolve_optimize_from_args`. Select disjoint `KERNEL_BIN`, `ISO_ROOT`, `OUTPUT_ISO`, and `PKG_TMP` strictly from an explicit `case "${PROFILE}"` allowlist; retain exact path-safety guard before `rm -rf "${ISO_ROOT}"` (`${BUILD_DIR}/iso_root` for `prod`, `${BUILD_DIR}/df-test/iso_root` for `df-test`); copy `${KERNEL_BIN}` to `${ISO_ROOT}/boot/kernel.elf` (compatible with unchanged `boot/limine/limine.conf` `kernel_path: boot():/boot/kernel.elf`); invoke `verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}" "${PROFILE}"`.
  - `scripts/lib/provenance.sh`: Add optional 3rd argument `profile="${3:-prod}"` to `verify_and_log_provenance` (100% backward-compatible with existing 2-argument callers). Resolve the exact 3-way artifact triad and isolated `prov_tmp` prefix per profile (`prod` vs `df-test`), rejecting any unknown profile value fail-closed. Preserve identical 3-way SHA-256 verification and Git metadata logging for both profiles.

### 6.3. QEMU Runner (`scripts/lib/qemu-runner.sh`) & Separated QMP `HLT` Verification
- **`run`, `debug`, `test-boot` modes (production profile):**
  - Continue using `build/zig-os.iso`, `zig-out/bin/kernel.elf`, and `verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}" "prod"`.
  - `test-boot`: **retain exact** `[IDT] 256 interrupt gates configured and verified.` check ([L141](../../scripts/lib/qemu-runner.sh#L141)) and add `[GDT] Kernel GDT, 64-bit TSS, and IST1-IST3 stacks initialized and verified.`.
- **`test-df` mode (isolated DF-test profile + QMP guest `HLT` verification):**
  1. Uses `ISO="${PROJECT_ROOT}/build/zig-os-df-test.iso"`, `KERNEL_BIN="${PROJECT_ROOT}/zig-out/df-test/kernel-df-test.elf"`, and runs `verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}" "df-test"` immediately prior to launching QEMU.
  2. Launches headless QEMU with `-no-reboot`, isolated serial log `${LOG_FILE}`, and an isolated UNIX-domain QMP monitor socket:
     ```bash
     qemu-system-x86_64 \
         -M q35 \
         -m 256M \
         -cdrom "${ISO}" \
         -serial "file:${LOG_FILE}" \
         -qmp "unix:${QMP_SOCK},server=on,wait=off" \
         -display none \
         -no-reboot &
     ```
     *(Both `${LOG_FILE}` and `${QMP_DIR}` are created via `mktemp` with `zig-os-df-*` prefixes and cleaned up in the `EXIT` trap.)*
  3. **Explicitly Separate Three Distinct Post-Trigger Verifications (Never Conflate Process State, VM Runstate, and Guest HLT):**
     - **Assertion A — `QEMU process alive`:**
       - Verify `kill -0 "${QEMU_PID}"` (confirms only that the host QEMU OS process did not terminate under `-no-reboot`; proves neither VM runstate nor guest `HLT`).
     - **Assertion B — `QEMU VM runstate`:**
       - Connect to `${QMP_SOCK}` via `python3` stdlib (`socket` + `json`), read the QMP greeting (`QMP.version.qemu.{major,minor,micro}`), complete `qmp_capabilities` handshake, execute `query-status` -> assert `return.running == true` and `return.status == "running"` (not `"shutdown"`, `"guest-panicked"`, or `"internal-error"`), and execute `query-cpus-fast` -> assert BSP entry `cpu-index == 0`, `target == "x86_64"`.
     - **Assertion C — `Guest BSP vCPU halted in expected state` (Version-Validated Multi-Line `CPU#0` Block Parser):**
       - *(QEMU 10.2.1 compatibility fact, inspected directly on host `qemu-system-x86_64 10.2.1` schema: legacy `query-cpus` was removed and `query-cpus-fast` does **not** expose a `"halted"` boolean field; however, QMP `human-monitor-command` with `"info registers"` outputs `CPU#0` registers and flags across multiple lines, including `CPL=` and `HLT=` on the `RIP`/`EFL` line and `TR =` on a separate segment-register line.)*
       - **Supported QEMU Version Policy (Exact Allowlist — No `10.x` Blanket Compatibility Claim):** Because HMP `info registers` is a human-readable monitor dump rather than a stability-guaranteed machine-readable QMP schema, `test-df` MUST validate `QMP.version.qemu` from the QMP greeting strictly against the exact verified version allowlist (**QEMU `10.2.1` only**):
         ```python
         assert major == 10
         assert minor == 2
         assert micro == 1
         ```
         Do **not** claim compatibility with all of QEMU `10.x` or any unverified QEMU release. Any QEMU version other than `10.2.1` MUST **fail closed** immediately rather than reporting a false `PASS`. To support any additional QEMU version in the future, the HMP `info registers` parser MUST first be empirically verified on that exact version before expanding the allowlist.
       - **Multi-Line `CPU#0` Block Parsing Contract:** Poll via QMP `{"execute": "human-monitor-command", "arguments": {"command-line": "info registers"}}` (bounded retry window after `[DF-TEST] PASS` appears in serial log). The parser MUST:
         1. Locate the `CPU#0` heading (exact heading line matching `^\s*CPU#0\s*$`) and reject missing or duplicate `CPU#0` headings.
         2. Slice the **entire `CPU#0` block** from its heading until the next CPU heading (`^\s*CPU#\d+\s*$`) or end of output, ensuring tokens from any other CPU block can never be accepted.
         3. Extract and validate `HLT`, `CPL`, and `TR` independently across all lines inside the `CPU#0` block (never assuming `HLT`, `CPL`, and `TR` appear on the same line): require `\bHLT=1\b` (with no conflicting `HLT=0`), `\bCPL=0\b`, and a segment line matching `^\s*TR\s*=\s*0048\b` (case-insensitive hex).
         4. **Fail closed** if the `CPU#0` block is missing, empty, incomplete, malformed, unrecognized in format, or missing any of the expected `HLT=1`, `CPL=0`, or `TR=0048` values.
       - **Fail-Closed Reporting Separation Policy:** Always log all three verdicts on distinct lines:
         - `[DF-TEST CHECK] QEMU process alive (kill -0): PASS/FAIL`
         - `[DF-TEST CHECK] QEMU VM runstate (QMP query-status=running, BSP cpu-index=0): PASS/FAIL`
         - `[DF-TEST CHECK] Guest BSP vCPU halted in expected state (QEMU 10.2.1 HMP CPU#0 block: HLT=1, CPL=0, TR=0048): PASS/FAIL`
         If QMP fails, QEMU version is unsupported, or the `CPU#0` block cannot be validated within the timeout, report Assertion C as `FAIL` distinctly and exit non-zero — **never** report `guest BSP halted` based on `kill -0` or `query-status` alone.
  4. **Serial Output Assertions:**
     - Require presence of: `[DF-TEST] PASS: Double Fault caught on IST1 stack.`, `[EXCEPTION] Vector: 8 (#DF: Double Fault)`, `Error Code: 0x0000000000000000`, and `CR2` / `RSP` in `[0x00000042000107d0..0x0000004200010800]`.
     - Require **absence** of: `[DF-TEST] FAIL:`, `[DF-TEST] INCONCLUSIVE:`, `[FATAL]`, `#UD`, and `#PF` after `[DF-TEST]`.
  - *(Verification honesty note [2026-11-20]: Live QEMU 10.2.1 QMP `HLT=1`, `CPL=0`, and `TR=0048` verification against the F-04 DF-test kernel in `Debug` and `ReleaseSafe` has been executed and **reported passing by Gemini 4 Hydrogen**, and is **pending independent GPT-6 review and Project Owner acceptance**. Bare-metal hardware verification has **not** been completed.)*

---

## 7. Findings Disposition Table (`N-01`–`N-08` & `ITR-1`–`ITR-4`)

| ID | Source | Severity / Type | Resolution Summary | Documented In |
|---|---|---|---|---|
| **`N-01`** | Neon Audit | HIGH | Replaced boolean `df_test_armed` with atomic CAS `DfStateMachine` (`std.atomic.Value(DfTestState).cmpxchgStrong(..., .seq_cst, .seq_cst)`) across 8 states: `#NMI`/`#MC` in `.preparing`/`.armed`/`.handling_df` transitions to `.aborted_async` (`INCONCLUSIVE`, never `FAIL`); synchronous or nested `#DF` in `.handling_df` transitions to `.nested_fault` (`FAIL`); all 4 terminal states (`.passed_halting`, `.failed`, `.aborted_async`, `.nested_fault`) are strictly immutable and halt silently on any subsequent exception; exported `x86_64_trigger_df_ud2_sentinel`. | `ADR-0005` (`Testing` #4–5), `Spec §5.4–5.5` |
| **`N-02`** | Neon Audit | HIGH | Eliminated `.armed` vs `.handling_df` contradiction via two-phase CAS protocol: (1) dispatcher executes CAS `.armed -> .handling_df` on Vector 8 (`#DF`) to confirm `.armed` origin; (2) only if CAS succeeds, runs pure overflow-safe `validateDfForensics` verifying all 6 hardware invariants (`vector == 8`, `error_code == 0`, `isFrameWithinStack`, `CS==0x28`/`SS==0x30`, `frame.rsp` & `CR2` window); (3) executes CAS `.handling_df -> .passed_halting`; (4) emits `PASS` strictly only if final CAS succeeds. | `ADR-0005` (`Testing` #5), `Spec §5.1`, `Spec §5.5` |
| **`N-03`** | Neon Audit | MEDIUM | Added `kernel/src/panic.zig` to allowed file list; specified bounded polling (`MAX_TX_POLL_SPINS`) and single guarded `serial.init()` check in `panicFn()` so neither `logException()` nor `panicFn()` can spin infinitely on dead UART. | `ADR-0005` (`Decision.4`), `Spec §3.2`, `Spec §8` |
| **`N-04`** | Neon Audit + Owner Option A (`2026-11-20`) | MEDIUM | Formalized Owner-approved Option A CS Accessed-bit policy in `gdt.testGdtAndTss()` / `isCodeDescriptorValidPostLoad` (accepts `0x9A` and `0x9B`, ignoring only bit 40 to accommodate observed QEMU TCG 10.2.1 `lretq` behavior while requiring exact match on every other bit; `Accessed` bit is not a security/privilege invariant in Phase 1) while keeping `DS`/`SS` `0x93` and Busy TSS `0x8B` strict; separated `cpu.ltr(0x48)` from `lgdt`/`lretq` asm block to prevent `%rax` aliasing; used `movw $0x00, %%ax` instead of `xorw`. | `ADR-0005` (`Decision.2`, `Decision.3.Step 6`, `Security`), `Spec §2.1–2.2` |
| **`N-05`** | Neon Audit | MEDIUM | Reordered Step 7 internals so `idt.testExceptionDispatch()` and `idt.testIstStackSwitch()` run **before** `idt.enableIstGates()` (while `TR` is loaded and `idt_table[2/8/18].ist == 0`), followed by `idt.enableIstGates()`, `idt.validateExceptionGates()`, and `idt.testPageFaultHandling()`. | `ADR-0005` (`Decision.3.Step 7`), `Spec §4` |
| **`N-06`** | Neon Audit | MEDIUM | Separated pure GDT/TSS types, constants, and encoders into `kernel/src/arch/x86_64/gdt/gdt_model.zig` (zero privileged inline asm) so Zig 0.17.1 self-hosted host `zig build test` never hits `invalid mnemonic: 'sgdt'`. | `ADR-0005` (`Decision.1`), `Spec §2.1`, `Spec §8` |
| **`N-07`** | Neon Audit | LOW | Specified fail-closed error handling for `pmm.allocPage()`/`vmm.mapPage()`/`vmm.unmapPage()` in `#DF` preparation; fully isolated `test-df` build subgraph, ELF (`zig-out/df-test/kernel-df-test.elf`), ISO staging (`build/df-test/iso_root`), ISO (`build/zig-os-df-test.iso`), temp paths, and `F-14` provenance from production artifacts; added three-way separated QEMU verification (`process alive`, `VM runstate`, and version-validated multi-line `CPU#0` HMP parser for `HLT=1`, `CPL=0`, `TR=0048`). | `ADR-0005` (`Decision.3.Step 8`, `Testing` #1 & #6), `Spec §5.5`, `Spec §6` |
| **`N-08`** | Neon Audit | INFO | Preserved exact marker `[IDT] 256 interrupt gates configured and verified.` (`scripts/lib/qemu-runner.sh:141`) and added `[GDT]` marker verification; noted `.agents/rules/03-x86_64-architecture.md:20` sync as optional hygiene. | `ADR-0005` (`Decision.3.Step 7`, `Testing`), `Spec §1`, `Spec §4`, `Spec §6` |
| **`ITR-1`** | Independent Reviewer | Mandatory | **Never free `phys` until `!vmm.isMapped` and `vmm.virtToPhys == null` are verified first**; if `unmapPage` fails or mapping remains present, refuse to call `pmm.freePage(phys)`, transition via CAS to `.failed`, log, and halt. | `ADR-0005` (`Testing` #3), `Spec §5.5` |
| **`ITR-2`** | Independent Reviewer | Mandatory | Execute atomic CAS `.handling_df -> .passed_halting` **strictly BEFORE** emitting `[DF-TEST] PASS: Double Fault caught on IST1 stack.`; if final CAS fails, strictly do NOT emit `PASS`; late `#NMI` after `.passed_halting` halts silently without overwriting terminal state or printing `FAIL`. | `ADR-0005` (`Testing` #5), `Spec §5.5` |
| **`ITR-3`** | Independent Reviewer | Mandatory | Designed `gdt.init()` as strict **one-shot** on BSP (`if (initialized) @panic(...)`); explicitly prohibited resetting the hardware Busy bit (`0x8B -> 0x89`) to fake idempotency. | `ADR-0005` (`Decision.3.Step 6`, `Alternatives` #4), `Spec §2.2` |
| **`ITR-4`** | Independent Reviewer | Mandatory | Explicitly separated the **10-byte `GDTR` memory operand** (`GdtDescriptor = extern struct { limit: u16, base: u64 align(1) }`, `@sizeOf == 10`) from the **16-byte 64-bit TSS System Descriptor** (`TssDescriptor16`, `2 x u64`) and the **104-byte `Tss64` structure**. | `ADR-0005` (`Decision.2`), `Spec §2.1` |

---

## 8. Allowed File List & Concrete Task Breakdown for Gemini 4 Hydrogen (Implementation Completed — Pending Independent Review)

| File Path | Action | Concrete Task for Hydrogen |
|---|---|---|
| `kernel/src/arch/x86_64/gdt/gdt_model.zig` | **Create** | Pure 10-byte `GdtDescriptor`, 104-byte `Tss64` (`align(1)` `u64` fields), 16-byte `TssDescriptor16`, selector/descriptor constants, `encodeTssDescriptor`, post-load validators (Option A CS `0x9A`/`0x9B` ignoring only bit 40 while matching all other bits exactly, strict `DS`/`SS` `0x93`, strict Busy TSS `0x8B`), and overflow-safe `areRangesDisjoint`. Zero inline asm. |
| `kernel/src/arch/x86_64/gdt/gdt.zig` | **Modify** | One-shot BSP `gdt.init()` (`initialized` guard, no Busy-bit reset), static writable `gdt_table`, `gdtr`, `kernel_tss`, `ist1_stack`/`ist2_stack`/`ist3_stack` (`16 KiB` each), checked `istNTop()`, `loadGdtAndReloadKernelSegments` (`movw $0x00, %ax`) + separate `cpu.ltr(0x48)`, `gdt.testGdtAndTss()`. |
| `kernel/src/arch/x86_64/cpu.zig` | **Modify** | Add `lgdt`, `sgdt`, `ltr`, `str` inline asm helpers with `.memory = true` clobbers where required. |
| `kernel/src/arch/x86_64/interrupts/vectors.zig` | **Modify** | Add vector/IST constants (`2/3/8/14/18`, `0..3`), `expectedIstForVector(u8) u8`, update `isValidKernelInterruptGate` (`ist == expected_ist`), add overflow-safe `isFrameWithinStack` & `isFrameDisjointFromStack`, pure `DfTestState` + atomic CAS `DfStateMachine` (`std.atomic.Value(DfTestState).cmpxchgStrong(..., .seq_cst, .seq_cst)`), and pure `validateDfForensics`. |
| `kernel/src/arch/x86_64/idt/df_trigger.s` | **Create** | Standalone `.intel_syntax noprefix` assembly routine `x86_64_trigger_df_unmapped_stack` (`mov rsp, rdi; push 0;`) + exported `x86_64_trigger_df_ud2_sentinel: ud2`. Linked **exclusively** into `df_kernel_mod`. |
| `kernel/src/arch/x86_64/idt/idt.zig` | **Modify** | Split `initEarly()` (`ist = 0`) and `enableIstGates()` (ordered per-entry updates `8->1, 2->2, 18->3` while `RFLAGS.IF = 0` after TSS/IST setup); update `validateExceptionGates()`; update `testExceptionDispatch()` & add `testIstStackSwitch()` (`int $3`, `test_skip_instruction_len == 0`, next-instruction marker, `post_rsp == pre_rsp`, checked `isFrameWithinStack`/`isFrameDisjointFromStack`); preserve `testPageFaultHandling()`; add `runStandaloneDoubleFaultTest() noreturn` implementing `ITR-1` and CAS `DfStateMachine`. |
| `kernel/src/arch/x86_64/idt/handlers.zig` | **Modify** | Pre-serial guard (`if (!serial.initialized) cpu.haltLoop()`); restrict `frame.rip += test_skip_instruction_len` strictly to Vector 14 (`#PF`); forbid recovery/`IRETQ` on Vector 8 (`#DF`) and Vector 18 (`#MC`); bounded `logException()`; atomic CAS `DfStateMachine` dispatch handling (`onException`, two-phase CAS `.armed -> .handling_df` -> `validateDfForensics` -> `completeDfPass()` strictly BEFORE emitting `[DF-TEST] PASS`, `#NMI`/`#MC` during `.handling_df` -> `.aborted_async` `INCONCLUSIVE`, immutable terminal states). |
| `kernel/src/drivers/serial/serial.zig` | **Modify** | Add `MAX_TX_POLL_SPINS`, pure host-testable `waitForTxReady`, and `tryWrite{Byte,String,Hex,Dec}Bounded` that never call `init()` when `!initialized` and return `false` on timeout. |
| `kernel/src/panic.zig` | **Modify** | Guard single `serial.init()` attempt if `!serial.initialized`, switch panic output to bounded serial functions, halt immediately on failure (`N-03`). |
| `kernel/src/main.zig` | **Modify** | Implement exact 8-step `_start()` order (`Step 7.1–7.5` with `testIstStackSwitch()` before `enableIstGates()`; `Step 8.1–8.4` branching on `build_options.test_double_fault`), preserving exact `[IDT]` marker and adding `[GDT]` marker. |
| `build.zig` | **Modify** | Construct two independent subgraphs: production (`kernel_mod`, `test_double_fault = false`, `zig-out/bin/kernel.elf`, `build/zig-os.iso`) and isolated DF-test (`df_kernel_mod`, `test_double_fault = true`, `df_trigger.s`, `.dest_dir = .{ .override = .{ .custom = "df-test" } }` -> `zig-out/df-test/kernel-df-test.elf`, `iso-df-test`, `test-df`, NEVER attached to `b.getInstallStep()`); wire `gdt_model`, `vectors`, and `serial` into `zig build test`. |
| `scripts/package-iso.sh` | **Modify** | Support optional `--profile <prod|df-test>` (default `prod`) using strictly disjoint `KERNEL_BIN`, `ISO_ROOT`, `OUTPUT_ISO`, and `PKG_TMP` paths with strict path allowlist guards before `rm -rf`, calling `verify_and_log_provenance` with `${PROFILE}`. |
| `scripts/lib/provenance.sh` | **Modify** | Add backward-compatible optional 3rd parameter `profile="${3:-prod}"` to `verify_and_log_provenance`, verifying the exact 3-way SHA-256 triad (`F-14`) and isolated temp dir for `prod` (`zig-out/bin/kernel.elf`, `build/iso_root`, `build/zig-os.iso`) or `df-test` (`zig-out/df-test/kernel-df-test.elf`, `build/df-test/iso_root`, `build/zig-os-df-test.iso`). |
| `scripts/lib/qemu-runner.sh` | **Modify** | Keep exact `[IDT]` check + add `[GDT]` check in `test-boot`; add `test-df` mode using isolated DF-test ISO/ELF + `df-test` provenance, launching QEMU with isolated QMP socket, verifying serial `[DF-TEST] PASS` + Vector 8 `#DF` + `Error Code: 0` + absence of `FAIL`/`INCONCLUSIVE`/`#UD`/`#PF`, and checking three assertions separately: (a) `QEMU process alive` (`kill -0`), (b) `QEMU VM runstate` (QMP `query-status` / `query-cpus-fast`), and (c) `Guest BSP vCPU halted in expected state` via exact QEMU `10.2.1` (`major == 10`, `minor == 2`, `micro == 1`) version-validated multi-line `CPU#0` block parser over QMP `human-monitor-command` `"info registers"` (`HLT=1`, `CPL=0`, `TR=0048`), failing closed on any other QEMU version or unrecognized/malformed block. |
| `tests/unit_test.zig`, `tests/vector_policy_test.zig` | **Modify** | Add host unit tests for: `gdt_model` (`10`-B `GdtDescriptor`, `104`-B `Tss64`, `16`-B `TssDescriptor16`, **explicit Option A CS validator cases** confirming `0x9A` is accepted, `0x9B` is accepted, and any mismatch in bits other than bit 40 is rejected, **strict `DS`/`SS` `0x93` requirement** rejecting `0x92`, **strict Busy TSS `0x8B` requirement** rejecting `0x89`, and `areRangesDisjoint`), `expectedIstForVector`, `serial.waitForTxReady`, **all `DfStateMachine` CAS tests** (every valid transition, invalid transitions, `#NMI`/`#MC` in `.handling_df`, late `#NMI` after `.passed_halting`, terminal immutability across all 4 terminal states, competing/failed CAS), **all `isFrameWithinStack`/`isFrameDisjointFromStack` overflow & boundary cases** (`frame_addr = 0`, `maxInt(u64)` + `frame_size = 1` returning `false`, end-overflowing range returning `false`, `frame_addr = stack_top` with `frame_size = 0` returning `false`, `frame_size = 0` disjoint returning `false`, before/after/flush-base/flush-top/1-byte-over/`base > top`), and `validateDfForensics`; verify `vector_policy_test` passes with `0` hits across `kernel/` including `df_trigger.s`. |
| `.agents/rules/05-interrupt-and-abi.md`, `docs/ARCHITECTURE.md`, `docs/TESTING_POLICY.md`, `docs/ROADMAP.md` | **Modify** | Synchronize docs with implemented F-04 code in the implementation commit (do NOT edit `VERIFIED_FINDING_REGISTER.md`). |
| `kernel/src/mm/virtual.zig`, `kernel/src/mm/virtual_core.zig`, `kernel/src/arch/x86_64/interrupts/stubs.s`, `boot/limine/limine.conf` | **Do NOT modify** | Verified unchanged: VMM already exports all required APIs; 256 ISR stubs and Limine boot path remain untouched. |

---

## 9. Required Verification Matrix & Current Status

> **Current Verification Status (2026-11-20):**
> - **Implementation Status:** **Completed by Gemini 4 Hydrogen** across the Section 8 file allowlist.
> - **Build / Unit / QEMU Results (Reported by Gemini 4 Hydrogen):** Tier 1 (4-mode builds, `F-01` zero-SIMD, DF-test ELF audit, production artifact isolation), Tier 2 (host unit tests across all 4 modes on Zig 0.17.1 self-hosted backend), Tier 3/4 (production QEMU `test-boot` in `Debug` and `ReleaseSafe`), and Tier 4 (standalone isolated QEMU 10.2.1 QMP `test-df` in `Debug` and `ReleaseSafe`) have been executed and **reported passing by Gemini 4 Hydrogen** (`BUILD VERIFIED`, `UNIT TEST VERIFIED`, and `QEMU VERIFIED` as agent-reported; not yet independently signed off).
> - **Independent GPT-6 Review:** **Pending** (awaiting independent technical review and Project Owner acceptance).
> - **Bare-Metal Hardware Verification:** **Not completed** (`NOT HARDWARE VERIFIED`).
> - **Governance Disclaimer:** Neither final acceptance nor `PRODUCTION READY` status is claimed. Phase 1 = F-04 implementation completed, pending independent review and Project Owner acceptance (`Pending Human Review`); Phase 2 = `NOT AUTHORIZED`.

| Tier | Check | Command / Verification | Acceptance Criteria |
|---|---|---|---|
| **Tier 1 (Build, Binary, & Artifact Isolation Audit)** | 4-mode production builds, `F-01` zero-SIMD check, DF-test ELF audit, production non-overwrite check | `zig build -Doptimize=<mode>` (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`); `zig build iso-df-test -Doptimize=<mode>`; `objdump -d`, `nm`, `sha256sum` | Zero warnings/errors; `0` SIMD/x87 matches; `nm zig-out/bin/kernel.elf` has **0** `x86_64_trigger_df_*` symbols; `objdump -d zig-out/df-test/kernel-df-test.elf` shows `x86_64_trigger_df_unmapped_stack` starts directly with `mov rsp, rdi; push 0; ud2`; `sha256sum` of `zig-out/bin/kernel.elf` and `build/zig-os.iso` is **bit-identical** before and after running `zig build test-df`. |
| **Tier 2 (Host Unit Tests)** | Pure model (including Option A CS Accessed-bit policy), vector policy, scanner, bounded serial, CAS `DfStateMachine`, overflow-safe stack/frame & `#DF` forensic validators | `zig build test -Doptimize=<mode> --cache-dir <tmp> --summary all` across all 4 modes | `100%` pass (all 67 existing tests + all new F-04 tests including Option A CS validator [`0x9A` accepted, `0x9B` accepted, any mismatch in bits other than bit 40 rejected, strict `DS`/`SS` `0x93` and strict Busy TSS `0x8B` preserved], all `DfStateMachine` CAS/terminal/race cases, and all 11 `isFrameWithinStack`/`isFrameDisjointFromStack` overflow, empty-frame, & boundary cases) on Zig 0.17.1 self-hosted backend; `0` live `kernel/` `INT` scanner hits (including `df_trigger.s`). |
| **Tier 3 & 4 (QEMU `test-boot`, Production Artifacts)** | Production boot in `Debug` and `ReleaseSafe` | `bash scripts/test-boot.sh --optimize Debug` & `python3 tests/test_boot.py --optimize ReleaseSafe` | Production 3-way ELF SHA-256 provenance pass (`F-14`); `[GDT]` + exact `[IDT] 256 interrupt gates configured and verified.` + `[PMM]` + `[VMM]` + `[HEAP]` + `[STATUS]` + `zig-os:~$`; QEMU process alive under `-no-reboot`. |
| **Tier 4 (Standalone QEMU `test-df`, Isolated Artifacts + QMP)** | Isolated real `#DF` stack-overflow test in `Debug` and `ReleaseSafe` | `zig build -Doptimize=<mode> test-df` | Isolated `df-test` 3-way ELF SHA-256 provenance pass (`F-14`); `[DF-TEST] PASS: Double Fault caught on IST1 stack.`, `[EXCEPTION] Vector: 8 (#DF: Double Fault)`, `Error Code: 0x0000000000000000`, `CR2` & `RSP` in `[0x0000_0042_0001_07D0..0x0000_0042_0001_0800]`; **zero** `[DF-TEST] FAIL`, `[DF-TEST] INCONCLUSIVE`, `#UD`, `#PF`; all three QEMU checks pass separately: (a) `QEMU process alive` (`kill -0`), (b) `QEMU VM runstate` (QMP `query-status=running`, `cpu-index=0`), and (c) `Guest BSP vCPU halted in expected state` (exact QEMU `10.2.1` allowlist + multi-line `CPU#0` block parser over QMP `"info registers"` verifying `HLT=1`, `CPL=0`, `TR=0048`); zero `IRETQ` from Vector 8. |
