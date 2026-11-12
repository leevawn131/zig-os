# ZIG-OS — Verified Finding Register & Phase 1 Hardening Plan

> **Document Authority:** Principal Kernel Auditor & Documentation Architect (Gemini 4 Argon)  
> **Original Audit Baseline:** `c10c05f1f37aacfda5046480a314f29d940b67ef` (`main`)  
> **Current Implementation Snapshot:** `771146810e41854f2b9e754f2a048f142ab633a8` (`main`)  
> **Audit Date:** 2026-11-11 (Updated: 2026-11-13)  
> **Scope:** Independent source, build-pipeline, and ELF binary verification for Phase 1 hardening.

---

## Revision History

| Revision | Date | Author | Summary of Changes |
|---|---|---|---|
| **v1.0** | 2026-11-11 | Gemini 4 Argon | Initial Verified Finding Register (`F-01`–`F-17`, `R-01`–`R-07`) for snapshot `c10c05f1f37aacfda5046480a314f29d940b67ef`. |
| **v1.1** | 2026-11-11 | Gemini 4 Argon | First corrective audit pass: recalibrated `F-01` (`CRITICAL` $\to$ `HIGH`), split `F-02`/`F-03`, `F-16`/`F-17`, and `F-19`/`F-20`, updated `F-04`, `F-08`, `F-10`, `F-14`, `F-18`. |
| **v1.2** | 2026-11-11 | Gemini 4 Argon | Second corrective architecture audit: (1) restored the authoritative x86-64 long-mode interrupt frame specification per Intel SDM Vol. 3A §6.14.2 and AMD64 APM Vol. 2 §8.9.3 (in 64-bit mode, the CPU unconditionally aligns `%rsp` to 16 bytes and pushes `SS`, `RSP`, `RFLAGS`, `CS`, `RIP` = `5` qwords even for same-CPL interrupts with `IST = 0`); (2) reclassified `F-02` as `REJECTED` (`R-09`) because valid interrupt/exception paths push `22` qwords (`176` bytes) below the CPU's 16-byte-aligned frame base, satisfying `%rsp % 16 == 0` before `call x86_64_interrupt_dispatch`; (3) updated `F-03` (`VERIFIED`, `MEDIUM`, `P1`) with the exact `5 + 1 + 15 = 21` qword (`168`-byte) calculation for software `INT n` targeting error-code vectors, verified zero current-source `INT n` calls to error-code vectors, and documented Limine's masked PIC handoff state; (4) reclassified `F-05` as `REJECTED` (`R-08`) because `frame.rsp` and `frame.ss` are unconditionally pushed in 64-bit mode, while preserving runtime regression test requirements under `F-04`; and (5) reconciled all finding counts (`17 VERIFIED`, `1 LIKELY`, `0 NEEDS_RUNTIME_VERIFICATION`, `9 REJECTED`), severities (`0 CRITICAL`, `6 HIGH`, `6 MEDIUM`, `4 LOW`, `2 INFORMATIONAL`), and priorities (`P0: 3`, `P1: 9`, `P2: 3`, `P3: 3`). |
| **v1.3** | 2026-11-11 | Gemini 4 Argon | Final audit corrections: (1) refined `F-03` to state exact Limine Base Revision 3 interrupt-masking guarantees (all 8259 PIC lines masked, IOAPIC Fixed and Lowest Priority redirection entries masked, `RFLAGS.IF = 0`, whereas IOAPIC NMI/ExtINT masking is only guaranteed from Base Revision 5+), distinguished legacy 8259 PIC IRQ0–IRQ7 overlap (`0x08–0x0F`, intersecting error-code vectors `8, 10..14` only) from misconfigured APIC routes on vectors `17, 21, 29, 30`, separated the current binary's immediate `#GP(0)` failure (`movaps` faulting into a valid 22-qword `#GP` path that logs and halts) from the shifted `InterruptFrame` / broken `add rsp, 16; iretq` return contract, and clarified that dynamic stack alignment (`and rsp, -16`) alone is NOT a complete fix for `F-03`; (2) reassessed `F-15` (`CR0.TS` not cleared in `cpu.enableSse()`) from `LOW` / `P2` to `MEDIUM` / `P1` because Limine only guarantees all unspecified `CR0` bits are zeroed starting at Base Revision 5+, while ZIG-OS requests Base Revision 3; (3) added explicit `FXSAVE64`/`FXRSTOR64` coverage limitations to `F-01` (preserves x87/MMX/SSE `XMM0–XMM15`, does not preserve upper `YMM` or extended AVX/AVX-512 state requiring `XSAVE`/`XRSTOR`); and (4) reconciled all severity (`0 CRITICAL`, `6 HIGH`, `7 MEDIUM`, `3 LOW`, `2 INFORMATIONAL`) and priority (`P0: 3`, `P1: 10`, `P2: 2`, `P3: 3`) tables. |
| **v1.3.1** | 2026-11-11 | Gemini 4 Argon | Refined `F-15`: (1) marked the initial `CR0.TS` register state at QEMU/Limine handoff as `UNVERIFIED` by direct GDB/runtime register capture (inferred only indirectly from absence of `#NM` during `./scripts/test-boot.sh`); (2) replaced the insufficient post-hoc `CR0` read check with a rigorous in-kernel QEMU regression test that deliberately sets `CR0.TS = 1` immediately before calling `cpu.enableSse()` with zero intervening FPU/SSE instructions and verifies both `CR0.TS` and `CR0.EM` are cleared afterward; and (3) distinguished host-testable pure `CR0` bit-mask logic from privileged Ring 0 runtime verification under QEMU. |
| **v1.4** | 2026-11-12 | Gemini 3.8 Flash | Implemented and verified resolution for `F-01`: updated `build.zig` target configuration with `cpu_features_sub` (subtracting `.x87`, `.mmx`, `.sse`, `.sse2`, `.avx`, `.avx2`) and `cpu_features_add` (adding `.soft_float`); confirmed zero prohibited instructions in both `Debug` and `ReleaseSafe` kernel ELFs via `objdump -d`; verified clean QEMU boot and passing in-kernel self-tests on freshly built hybrid ISOs; marked `F-01` as `FIXED`. Reconciled all finding registers and priority distributions (`16 VERIFIED`, `1 LIKELY`, `1 FIXED`, `9 REJECTED`; `17` active findings; `P0`: `2`). |
| **v1.5** | 2026-11-12 | Gemini 4 Argon | Updated register for implementation snapshot `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (`F-10A` pure-module extraction): (1) recorded current implementation snapshot `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` alongside historical original audit baseline `c10c05f1f37aacfda5046480a314f29d940b67ef`; (2) documented `F-10A` completion (`paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` shared between production kernel modules and `tests/unit_test.zig`), explicitly distinguishing independently reviewed source structure from agent-reported build (`Debug`/`ReleaseSafe`), host unit test (`7/7` passing), and fresh ISO/QEMU boot evidence; (3) updated `F-10` evidence to replace the obsolete claim that `tests/unit_test.zig` duplicates all helpers with zero production imports, while keeping `F-10` `OPEN` / `VERIFIED` / `P0` because `F-10B` (stateful PMM, VMM, and Heap core testability) remains pending; and (4) preserved `F-14` as `OPEN` / `VERIFIED` / `P0` and retained all finding counts (`16 VERIFIED`, `1 LIKELY`, `1 FIXED`, `9 REJECTED`; `17` active findings; active `P0`: `F-10`, `F-14`). |
| **v1.6** | 2026-11-13 | Gemini 4 Argon | Independently audited `F-14` implementation at commit `771146810e41854f2b9e754f2a048f142ab633a8` and updated register: (1) inspected `build.zig`, `scripts/build.sh`, `scripts/package-iso.sh`, `scripts/lib/common.sh`, `scripts/lib/provenance.sh`, `scripts/lib/qemu-runner.sh`, `scripts/test-boot.sh`, `scripts/run.sh`, `scripts/debug.sh`, and `tests/test_boot.py` against all nine `F-14` resolution criteria; (2) marked `F-14` as `FIXED` while preserving a strict boundary between independently reviewed source/artifact evidence and implementation-agent-reported build, QEMU smoke-test, and `E.1`–`E.7` regression outputs, and recorded a non-blocking implementation note that `mv -f` from `${TMPDIR:-/tmp}` (`tmpfs`) to `build/zig-os.iso` (`ext4`) performs a cross-filesystem copy-and-unlink when `TMPDIR` is unset; (3) corrected Section 1.1 branch wording (`main` first-parent ancestor on `origin/main` rather than `origin/dev baseline`); (4) retained `F-10` as `VERIFIED` / `OPEN` / `P0` (`F-10B` pending); and (5) reconciled all status (`15 VERIFIED`, `1 LIKELY`, `2 FIXED`, `9 REJECTED`; `16` active findings), severity (`5 HIGH`, `6 MEDIUM`, `3 LOW`, `2 INFORMATIONAL`), and priority (`P0: 1`, `P1: 10`, `P2: 2`, `P3: 3`) tables. |

---

## 1. Audited Snapshot & Workspace Identification

### 1.1 Git Snapshot Identity

| Attribute | Original Audit Baseline (`v1.0`–`v1.3.1`) | Current Implementation Snapshot (`v1.6`) | Match Status |
|---|---|---|---|
| **Repository** | `leevawn131/zig-os` | `leevawn131/zig-os` | **MATCH** |
| **Branch** | `main` (`origin/main` first-parent ancestor; `origin/dev` ref also points to `c10c05f1`) | `main` (`origin/main`) | **MATCH** |
| **HEAD Commit SHA** | `c10c05f1f37aacfda5046480a314f29d940b67ef` | `771146810e41854f2b9e754f2a048f142ab633a8` | **EXACT MATCH** |
| **Commit Subject** | `feat(kernel): implement Phase 1 core kernel infrastructure` | `fix(build,scripts): enforce fresh builds, provenance checks, and ReleaseSafe default (F-14)` | **EXACT MATCH** |
| **Commit Timestamp** | `2026-11-10T14:10:11+07:00` | `2026-11-13T00:56:01+07:00` | **EXACT MATCH** |
| **Intervening Source Commits** | — | `515aa91becaf772f3f5b9243f92c1c0828f5d0bc` (`F-01` fix), `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (`F-10A` refactor), `771146810e41854f2b9e754f2a048f142ab633a8` (`F-14` fix) | **VERIFIED** |

### 1.2 Working Tree & Build Artifact Status (`git status --short`)

At current snapshot `771146810e41854f2b9e754f2a048f142ab633a8`:
```text
 M zig.zip
?? docs/md.zip
?? graphify-out/
```

- **Kernel, Linker, Build, and Test Source Integrity (`7711468`):** Zero tracked source files under [`kernel/`](file:///home/leevawn/Projects/zig-os/kernel), [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`scripts/`](file:///home/leevawn/Projects/zig-os/scripts), or [`tests/`](file:///home/leevawn/Projects/zig-os/tests) have uncommitted modifications. All tracked code and scripts match commit `771146810e41854f2b9e754f2a048f142ab633a8` byte-for-byte.
- **Untouched Working-Tree Artifacts:** `zig.zip`, `docs/md.zip`, and `graphify-out/` remain untouched in the local workspace per governance safety rules (causing `git status --porcelain` in `scripts/lib/common.sh` to report `tree=dirty` during local builds).
- **On-Disk Build Artifacts at `7711468` (Independently Inspected via `sha256sum`; `ReleaseSafe` Default Build):**
  ```text
  7b1ac542917334d3b222100f80f86bcab164134d51243340ef15db49d8d3b861  zig-out/bin/kernel.elf
  7b1ac542917334d3b222100f80f86bcab164134d51243340ef15db49d8d3b861  build/iso_root/boot/kernel.elf
  c819a34806abfc810a0e4faec179eeb8e9da3732639e210828d0e8fbce44ace4  build/zig-os.iso
  ```
- **Agent-Reported Build Artifacts for `F-10A` (`9df21f8`, `Debug` Kernel ELF):**
  ```text
  0704203edb046d847ad73bb8df3b5ef7d13118ee40a3204d1f6d96e33d47e964  zig-out/bin/kernel.elf
  0335e152875e8cdc4b75cd33ea937cdbc1c9e639495dce8b55cb5a0b67d6e78b  build/zig-os.iso
  ```
- **Historical Baseline Build Artifacts (`c10c05f`, Inspected in `v1.0`–`v1.3.1`):**
  ```text
  $ xorriso -osirrox on -indev build/zig-os.iso -extract /boot/kernel.elf /tmp/iso_extracted_kernel.elf
  $ sha256sum zig-out/bin/kernel.elf build/iso_root/boot/kernel.elf /tmp/iso_extracted_kernel.elf
  19e69d105af7bc95ffd07e9c2e00109797440c1ce92a82318c89a9defc1586d3  zig-out/bin/kernel.elf
  19e69d105af7bc95ffd07e9c2e00109797440c1ce92a82318c89a9defc1586d3  build/iso_root/boot/kernel.elf
  19e69d105af7bc95ffd07e9c2e00109797440c1ce92a82318c89a9defc1586d3  /tmp/iso_extracted_kernel.elf
  ```

---

## 2. Verification Methodology & Executed Evidence Matrix

Every claim in this register is classified strictly by the verification method actually performed and its provenance:

| Verification Tier | Executed / Provenance | Command / Method | Empirical Result & Provenance |
|---|---|---|---|
| **Static Source Inspection (`c10c05f`, `9df21f8`, & `7711468`)** | **YES (Independently Audited)** | Direct line-by-line review of all files in `kernel/`, `build.zig`, `scripts/`, `tests/`, `docs/`, and `/opt/zig/current/lib/std/Target/x86.zig` | Completed across 100% of kernel and build sources at baseline `c10c05f1f37aacfda5046480a314f29d940b67ef`, re-verified at `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (`F-10A` shared modules `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, `heap_layout.zig`), and independently audited at `771146810e41854f2b9e754f2a048f142ab633a8` across all 10 `F-14` build/script/test files (`build.zig`, `scripts/build.sh`, `scripts/package-iso.sh`, `scripts/lib/common.sh`, `scripts/lib/provenance.sh`, `scripts/lib/qemu-runner.sh`, `scripts/test-boot.sh`, `scripts/run.sh`, `scripts/debug.sh`, `tests/test_boot.py`). |
| **ELF & ISO Binary Inspection (`c10c05f`, `515aa91`, & `7711468`)** | **YES (Baseline & On-Disk Hashes Audited / `F-01` Disassembly Agent-Reported)** | `sha256sum`, `xorriso -extract`, `readelf -h -l -S -d`, `nm -n`, `objdump -d -M intel`, `df -T` | At `c10c05f`, confirmed `/boot/kernel.elf` inside `build/zig-os.iso` matched `zig-out/bin/kernel.elf` (`19e69d10...`), 3 `PT_LOAD` segments (`R E`, `R`, `RW`), orphan `.got` section, Limine request ordering, and 6,904 `xmm` / 2,274 `movaps` instructions. At `515aa91` (`F-01`), implementation agent reported `0` prohibited SIMD/x87 instructions in `Debug` and `ReleaseSafe` ELFs. At `7711468` (`F-14`), auditor verified on-disk `zig-out/bin/kernel.elf` and `build/iso_root/boot/kernel.elf` SHA-256 (`7b1ac542...`) and filesystem mount topology (`/tmp` on `tmpfs` vs. `build/` on `ext4`). |
| **Host Unit Tests (`c10c05f` vs. `9df21f8` & `7711468`)** | **Baseline Audited / `9df21f8` & `7711468` Source Reviewed & Agent-Reported** | `zig build test --summary all` and direct `zig test` with `--dep` module flags | At `c10c05f`, `5/5` tests passed against local duplicate functions in `tests/unit_test.zig`. At `9df21f8` (`F-10A`) and `7711468` (`F-14`), static review confirms `tests/unit_test.zig` imports the 4 shared production modules (`paging_math`, `physical_math`, `page_fault`, `heap_layout`) with zero local duplicates; implementation agent reported `7/7` tests passing (`3/3 steps succeeded`). Stateful PMM/VMM/Heap logic remains untested on host (`F-10B`). |
| **Build, Provenance, & QEMU Boot Verification (`c10c05f` vs. `9df21f8` & `7711468`)** | **Baseline Audited / `9df21f8` & `7711468` Source Audited & Execution Agent-Reported** | `zig build -Doptimize=Debug iso`, `zig build -Doptimize=ReleaseSafe iso`, `zig build test-boot`, `./scripts/test-boot.sh`, `python3 tests/test_boot.py`, `verify_f14_regressions.sh` (`E.1`–`E.7`) | At `7711468` (`F-14`), independent source review confirms every public entrypoint builds fresh artifacts, defaults to `ReleaseSafe`, uses a non-recursive Zig build graph, and enforces 3-way kernel ELF SHA-256 provenance before QEMU launch. Implementation agent reported passing `Debug` (`0704203e...`) and `ReleaseSafe` (`7b1ac542...`) ISO builds, passing headless QEMU smoke tests across `zig build test-boot`, `./scripts/test-boot.sh`, and `python3 tests/test_boot.py`, and passing regression checks `E.1`–`E.7` (with `E.2a`–`E.2c` and `E.7a`–`E.7d` using a `PATH`-stubbed `qemu-system-x86_64`). No build or QEMU run was re-executed by the auditor during the `v1.6` documentation review. |

---

## 3. Summary of Findings

### 3.1 Count by Verification Status

| Status Category | Count | Finding IDs |
|---|---:|---|
| **VERIFIED** | **15** | `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-09`, `F-10`, `F-11`, `F-12`, `F-13`, `F-15`, `F-16`, `F-17`, `F-18`, `F-20` |
| **LIKELY** | **1** | `F-19` |
| **NEEDS_RUNTIME_VERIFICATION** | **0** | None |
| **REJECTED** | **9** | `R-01`, `R-02`, `R-03`, `R-04`, `R-05`, `R-06`, `R-07`, `R-08` (formerly `F-05`), `R-09` (formerly `F-02`) |
| **FIXED** | **2** | `F-01` (at `515aa91`: `cpu_features_sub`/`cpu_features_add` in `build.zig`), `F-14` (at `7711468`: unconditional fresh build, non-recursive graph, `ReleaseSafe` default, and 3-way ELF SHA-256 provenance verification) |

### 3.2 Severity Distribution (Active Findings: 16 Total)

| Severity | Count | Finding IDs |
|---|---:|---|
| **CRITICAL** | **0** | None |
| **HIGH** | **5** | `F-06`, `F-07`, `F-08`, `F-09`, `F-10` |
| **MEDIUM** | **6** | `F-03`, `F-04`, `F-11`, `F-12`, `F-13`, `F-15` |
| **LOW** | **3** | `F-16`, `F-18`, `F-19` |
| **INFORMATIONAL** | **2** | `F-17`, `F-20` |

### 3.3 Priority Distribution (`P0`–`P3`: 16 Active Findings)

| Priority | Count | Finding IDs |
|---|---:|---|
| **P0 — Must fix before further kernel development** | **1** | `F-10` (`F-10B` pending; `F-01` and `F-14` are `FIXED`) |
| **P1 — Must fix before Phase 2 authorization** | **10** | `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-09`, `F-11`, `F-12`, `F-13`, `F-15` |
| **P2 — Important hardening that can follow** | **2** | `F-16`, `F-19` |
| **P3 — Future improvements** | **3** | `F-17`, `F-18`, `F-20` |

---

## 4. Finding Register (`F-01`–`F-20`)

> **Source Version Note:** Findings were originally audited at baseline commit `c10c05f1f37aacfda5046480a314f29d940b67ef` (`2026-11-10`) and updated through current implementation snapshot `771146810e41854f2b9e754f2a048f142ab633a8` (`2026-11-13`, incorporating `515aa91` for `F-01`, `9df21f8` for `F-10A`, and `7711468` for `F-14`). Historical IDs `F-02` and `F-05` are retained in place with `Status: REJECTED` and cross-referenced to `R-09` and `R-08` in Section 5 to preserve full audit traceability.

---

### [F-01] Unsaved SIMD/SSE (`xmm0`–`xmm15`) register state across interrupt dispatch and compiler-generated SIMD instructions in kernel code

**Status:** FIXED (Build Verified & QEMU Verified)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Build target configuration ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig)), ISR common assembly stub ([`kernel/src/arch/x86_64/interrupts/stubs.s`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s)), and interrupt dispatcher ([`kernel/src/arch/x86_64/idt/handlers.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig)).

**Source location:**  
- [`build.zig:4-22`](file:///home/leevawn/Projects/zig-os/build.zig#L4-L22)
- [`kernel/src/arch/x86_64/interrupts/stubs.s:1533-1571`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s#L1533-L1571)
- [`kernel/src/arch/x86_64/idt/handlers.zig:77-96`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L77-L96)
- [`kernel/src/main.zig:13-19`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L13-L19)

**Resolution & Empirical Verification (v1.4):**  
Resolved via **Approach 1** by configuring the freestanding kernel target in [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig#L4-L22) to subtract `.x87`, `.mmx`, `.sse`, `.sse2`, `.avx`, `.avx2` and add `.soft_float`:
```zig
const x86 = std.Target.x86;
const target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_features_sub = x86.featureSet(&[_]x86.Feature{
        .x87,
        .mmx,
        .sse,
        .sse2,
        .avx,
        .avx2,
    }),
    .cpu_features_add = x86.featureSet(&[_]x86.Feature{
        .soft_float,
    }),
});
```
- **Disassembly Verification:** Automated opcode audit across the resulting `kernel.elf` confirmed a 100% reduction in prohibited instructions:
  - `Debug`: dropped from **8,536** prohibited instructions to **0** (zero `xmm`, `ymm`, `zmm`, `mm`, `movaps`, `movups`, `xorps`, `fxsave`, or x87 instructions).
  - `ReleaseSafe`: dropped from **61** prohibited instructions to **0**.
- **Runtime Verification:** Fresh bootable ISOs generated from both `Debug` and `ReleaseSafe` builds booted cleanly under QEMU and passed all in-kernel self-tests (`idt.testExceptionDispatch()`, `idt.testPageFaultHandling()`, `pmm.testPmm()`, `vmm.testVmm()`, `heap.testHeap()`) to `zig-os:~$`.

**Historical Evidence (Baseline Commit `c10c05f1`):**  
1. **Target configuration:** Baseline `build.zig` used `b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none })`, which enabled `.mmx`, `.sse2` (implying `.sse`), `.fxsr`, and `.x87` by default.
2. **Compiler-generated SIMD instructions:** Disassembly of baseline `kernel.elf` confirmed 6,904 instructions referencing `xmm` registers and 2,274 `movaps` instructions, plus x87 `fld`/`fstp` instructions at `0xffffffff800046ea..0xffffffff800046ef`.
3. **SIMD usage inside [`x86_64_interrupt_dispatch`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L77-L80):** `movups xmm0, [rip+0x31c91]` and `movaps [rbp-0x20], xmm0`.
4. **Missing SIMD context preservation:** `isr_common` saved only GPRs (`rax`..`r15`).

**Technical explanation:**  
Four distinct technical aspects:
1. **Compiler-generated SIMD instructions:** With SSE/SSE2 enabled in the target, LLVM emits `xmm` loads/stores (`movups`, `movaps`) throughout the kernel for 16-byte struct, slice, and optional copies (including `test_expected_vector: ?u64` in `x86_64_interrupt_dispatch`), as well as 16-byte alignment-checked `movaps` stack spills.
2. **SIMD register state preservation across interrupts:** Because `xmm0`..`xmm15` are caller-saved under the System V AMD64 ABI, `x86_64_interrupt_dispatch` (and any function it calls) is permitted by the ABI to overwrite `xmm0`..`xmm15` without restoring them. Because `isr_common` only saves GPRs, every returning interrupt or exception silently clobbered `xmm0` in the interrupted code context.
3. **CPU FPU/SSE initialization:** `_start()` calls [`cpu.enableSse()`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L18) before `idt.init()`. Retained to ensure hardware control registers are properly initialized for upcoming user-space execution.
4. **Why `.soft_float` alone is insufficient:** `Feature.soft_float` (`-msoft-float`) only switches scalar floating-point operations to software library routines; it does **not** disable vector registers or memory vectorization unless `.mmx`, `.sse`, `.sse2`, `.avx`, and `.avx2` are explicitly subtracted.

**Impact Prior to Fix:**  
Silent corruption of `xmm0` across returning interrupts or exceptions, plus `#GP(0)` faults inside `x86_64_interrupt_dispatch` if an anomalous entry path (`F-03`) misaligned the stack by 8 bytes.

**Regression tests:**  
1. Compile `kernel.elf` in both `Debug` and `ReleaseSafe` modes and run `objdump -d -M intel zig-out/bin/kernel.elf | grep -E "xmm|ymm|zmm|movaps|movups|fld|fstp"` to verify zero compiler-emitted SIMD/x87 instructions.
2. Run `./scripts/test-boot.sh` on fresh ISO images and verify successful boot to `zig-os:~$`.

**Dependencies:**  
Interacts with `F-03` and `F-15`.

---

### [F-02] (REJECTED — Moved to `R-09`) Missing dynamic 16-byte stack alignment (`and rsp, -16`) before calling Zig interrupt dispatcher in `isr_common`

**Status:** REJECTED (See [`R-09`](#5-rejected-findings-register))

**Severity:** N/A (Rejected)

**Confidence:** HIGH

**Affected component:**  
Common ISR assembly stub ([`kernel/src/arch/x86_64/interrupts/stubs.s`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s)).

**Source location:**  
[`kernel/src/arch/x86_64/interrupts/stubs.s:1533-1572`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s#L1533-L1572).

**Evidence & Rejection Summary:**  
Per **Intel SDM Vol. 3A, Section 6.14.2 ("64-Bit Mode Stack Frame")** and **AMD64 APM Vol. 2, Section 8.9.3 ("Interrupt Stack Frame")**, in 64-bit long mode the processor unconditionally aligns `%rsp` downward to a 16-byte boundary (`RSP_aligned = RSP_old & ~0xF`) before pushing the 5-qword hardware frame (`SS`, `RSP`, `RFLAGS`, `CS`, `RIP` = `40` bytes), including on same-privilege (`CPL 0 -> CPL 0`) interrupts with `IST = 0`.
- **Valid path without hardware error code:** `5` qwords (CPU) + `2` qwords (stub: dummy `0` + `vector`) + `15` qwords (`isr_common`: `rax..r15`) = **`22` qwords = `176` bytes (`0xB0`)**.
- **Valid path with hardware error code:** `6` qwords (CPU: `SS`, `RSP`, `RFLAGS`, `CS`, `RIP`, `error_code`) + `1` qword (stub: `vector`) + `15` qwords (`isr_common`: `rax..r15`) = **`22` qwords = `176` bytes (`0xB0`)**.

Because `176 = 11 * 16`, `%rsp` immediately before `call x86_64_interrupt_dispatch` is `RSP_aligned - 176`, which is **already 16-byte aligned (`%rsp % 16 == 0`)** on all valid interrupt and hardware exception paths. Absence of `and rsp, -16` is therefore **not** a defect on valid paths (see `R-09`). The only path that produces an odd qword count (`21` qwords = `168` bytes) is software `INT n` (or an external interrupt routed to an exception vector) targeting an error-code vector, which is tracked separately under `F-03`.

---

### [F-03] Error-code frame mismatch when software `INT n` or an external interrupt invokes a vector whose stub expects a hardware error code

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Error-code ISR stubs ([`kernel/src/arch/x86_64/interrupts/stubs.s`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s)) and [`InterruptFrame`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34).

**Source location:**  
[`kernel/src/arch/x86_64/interrupts/stubs.s:53-180`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s#L53-L180) and [`kernel/src/arch/x86_64/idt/handlers.zig:6-34`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34).

**Evidence:**  
The stubs for vectors `8` (`#DF`), `10` (`#TS`), `11` (`#NP`), `12` (`#SS`), `13` (`#GP`), `14` (`#PF`), `17` (`#AC`), `21` (`#CP`), `29` (`#VC`), and `30` (`#SX`) push only the vector number (`1` qword) because they assume the processor pushed a hardware error code:
```asm
.global isr_stub_14
isr_stub_14:
    push 14
    jmp isr_common
```

**Technical explanation:**  
Per Intel SDM Vol. 3A §6.13 ("Error Code") and §6.14.2:
1. **Exact long-mode qword calculation (`21` qwords = `168` bytes):**
   When software executes `INT n` targeting an error-code vector (`8, 10, 11, 12, 13, 14, 17, 21, 29, 30`), or if an external hardware interrupt is delivered on one of those vectors:
   - The processor aligns `%rsp` to a 16-byte boundary (`RSP_aligned`) and pushes **`5` qwords** (`SS`, `RSP`, `RFLAGS`, `CS`, `RIP` = `40` bytes). It does **not** push an error code.
   - The error-code vector stub pushes **`1` qword** (`vector` = `8` bytes).
   - `isr_common` pushes **`15` qwords** (`rax..r15` = `120` bytes).
   - **Total pushed before `call x86_64_interrupt_dispatch`:** `5 + 1 + 15 = 21` qwords = **`168` bytes (`0xA8`)**.
   - Because `168 % 16 == 8`, the call-site `%rsp` (`RSP_aligned - 168`) is **misaligned by 8 bytes** (`%rsp % 16 == 8` instead of `0`).
2. **Distinction between the current binary's immediate failure and the malformed interrupt frame:**
   - **A. Current binary's immediate failure (`#GP(0)` followed by clean log and halt):**  
     In the current `build/iso_root/boot/kernel.elf`, `x86_64_interrupt_dispatch` contains a 16-byte alignment-checked `movaps` stack operation (`movaps XMMWORD PTR [rbp-0x20], xmm0` at `0xffffffff8001d52f`). With the 8-byte misaligned call frame (`%rbp % 16 == 8`), executing this instruction generates a hardware `#GP(0)` (Vector 13). That `#GP(0)` itself enters `isr_stub_13` through a **valid hardware error-code exception path** (`6` CPU qwords + `1` stub qword + `15` GPR qwords = `22` qwords = `176` bytes, 16-byte aligned), where the current unexpected-exception dispatcher logs the `#GP` and halts cleanly (`cpu.haltLoop()`). Thus, in the current binary, this path does **not** immediately triple-fault or reach `iretq`.
   - **B. Malformed original `InterruptFrame` and invalid `add rsp, 16; iretq` return frame:**  
     Because the 8-byte `error_code` slot was never pushed between `RIP` and `vector`, the original [`InterruptFrame`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34) fields are shifted by 8 bytes:
     - `frame.vector` (`+120`) reads `vector`.
     - `frame.error_code` (`+128`) reads the hardware-pushed `RIP`.
     - `frame.rip` (`+136`) reads the hardware-pushed `CS`.
     - `frame.cs` (`+144`) reads `RFLAGS`.
     - `frame.rflags` (`+152`) reads `RSP`.
     - `frame.rsp` (`+160`) reads `SS`.
     - `frame.ss` (`+168`) reads 8 bytes past the top of the hardware interrupt frame (`[RSP_aligned]`).
     - Any handler that does not halt (or if compiler-generated SIMD instructions are removed under `F-01` Approach 1 and a handler returns on that vector) and attempts to return through `pop r15 .. pop rax; add rsp, 16; iretq` will discard `vector` **and** the saved `RIP` during `add rsp, 16`, causing `iretq` to pop `CS` into `RIP`, `RFLAGS` into `CS`, `RSP` into `RFLAGS`, `SS` into `RSP`, and `[RSP_aligned]` into `SS`.
3. **Current source & Limine Base Revision 3 interrupt handoff state:**
   - **Current source inspection:** Searching `kernel/src/` confirms the only software interrupt instruction in the repository is `asm volatile ("int $3")` in [`idt.zig:64`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig#L64) (Vector 3 `#BP`, which is a non-error-code vector whose stub `isr_stub_3` pushes both dummy `0` and `3`). There are **zero** `INT n` calls to error-code vectors in the current source.
   - **Limine Base Revision 3 handoff guarantees:** The project currently requests **Limine Base Revision 3** ([`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12)). Per the official Limine Boot Protocol specification (*Entry / Machine State — x86_64*), under Base Revision 3:
     - All legacy 8259 PIC IRQ lines are masked.
     - IOAPIC redirection entries using **Fixed** delivery mode are masked.
     - IOAPIC redirection entries using **Lowest Priority** delivery mode are masked.
     - **NMI** and **ExtINT** IOAPIC delivery mode masking is **only guaranteed starting from Base Revision 5** (and is therefore **not** guaranteed by the protocol under Base Revision 3).
     - `RFLAGS.IF` is cleared (`0`) at x86-64 entry (and reinforced by `cpu.cli()` at [`main.zig:15`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L15)).
   - **Distinction between legacy 8259 PIC vectors (`0x08–0x0F`) and other APIC routes:**
     - Under the traditional default power-on 8259 PIC mapping, **only** master PIC `IRQ0–IRQ7` map to vectors `0x08–0x0F` (`8–15`), which overlap the error-code exception vectors `8` (`#DF`), `10` (`#TS`), `11` (`#NP`), `12` (`#SS`), `13` (`#GP`), and `14` (`#PF`) (while slave PIC `IRQ8–IRQ15` default to `0x70–0x77`). Legacy 8259 PIC IRQs do **not** naturally target error-code exception vectors `17` (`#AC`), `21` (`#CP`), `29` (`#VC`), or `30` (`#SX`).
     - Other interrupt routes (such as IOAPIC redirection entries, Local APIC LVT entries, or MSI/MSI-X vectors) would only hit error-code exception vectors (`8, 10..14, 17, 21, 29, 30`) if deliberately misconfigured by software to target architectural exception vectors `0–31`.

**Reproduction scenario:**  
Executing `asm volatile ("int $14")` or `asm volatile ("int $13")` in Ring 0 (or unmasking the legacy 8259 PIC without remapping `IRQ0–IRQ7` away from vectors `8–15`) pushes 5 CPU qwords (`40` B), 1 stub vector qword (`8` B), and 15 GPR qwords (`120` B) for `21` qwords (`168` B). In the current binary, this misaligns the call-site `%rsp` by 8 bytes (`168 % 16 == 8`), triggering a hardware `#GP(0)` on `movaps` inside `x86_64_interrupt_dispatch` (which then enters Vector 13 with a valid 22-qword hardware frame, logs `#GP`, and halts); if the handler Instead returns via `add rsp, 16; iretq`, it restores a corrupted 8-byte-shifted frame.

**Impact:**  
No exposure during current Phase 1 boot (where `IF = 0` and no Ring 0 `INT n` targets error-code vectors), but causes either a nested `#GP(0)` fault (with misaligned `InterruptFrame` fields in the original frame) or an invalid `iretq` frame restoration if Ring 0 software executes `INT n` on an error-code vector, if legacy PIC `IRQ0–IRQ7` (`0x08–0x0F`) are unmasked without remapping, or if APIC routes are misconfigured into vectors `0–31`.

**Recommended correction:**  
1. **Prohibit Ring 0 `INT n` to hardware error-code exception vectors:** Never issue software `INT n` in Ring 0 to vectors `8, 10, 11, 12, 13, 14, 17, 21, 29, 30`. Any dedicated software interrupt or system-call vector must use its own dedicated vector (`>= 32`) with a matching `ISR_NOERRCODE` stub contract (or architectural `SYSCALL`/`SYSRET`) and must **never** reuse hardware error-code exception stubs.
2. **Remap or keep masked the legacy 8259 PIC:** Before enabling interrupts (`cpu.sti()`) in Phase 2, remap the legacy 8259 PIC from `0x08–0x0F` / `0x70–0x77` to non-exception vectors `0x20–0x2F` (`32–47`) (even if kept masked in favor of IOAPIC/LAPIC, so neither unmasked PIC IRQs nor `ExtINT`/spurious PIC deliveries can land on vectors `0x08–0x0F`).
3. **Assign APIC vectors outside `0–31`:** Ensure all IOAPIC redirection entries, Local APIC LVT entries, and MSI/MSI-X vectors are assigned to vectors `>= 32`.
4. **Preserve `DPL = 0` on exception gates:** Keep `DPL = 0` (`0x8E`) on IDT exception gates `0–31` (unless an explicitly designed user breakpoint interface is enabled on Vector 3 `#BP`, which uses a non-error-code stub), ensuring any Ring 3 `INT n` targeting an error-code exception vector traps into `#GP` in hardware (pushing a real hardware error code).
5. **Note on dynamic stack alignment:** While an optional `mov rbp, rsp; and rsp, -16; call ...; mov rsp, rbp` sequence in `isr_common` can prevent call-site `movaps` alignment faults, it does **not** insert the missing CPU error-code slot, does **not** repair the shifted `InterruptFrame` layout (`error_code`..`ss`), and does **not** repair the `add rsp, 16; iretq` return sequence. Therefore, **dynamic stack alignment alone is NOT a complete fix for `F-03`**.

**Regression tests:**  
1. Verify via static scan that no kernel code executes `int` on vectors `8, 10, 11, 12, 13, 14, 17, 21, 29, 30`.
2. In Phase 2, assert legacy 8259 PIC vector offset initialization (`>= 0x20`) and IOAPIC/LAPIC vector assignment (`>= 0x20`) complete prior to `cpu.sti()`.

**Dependencies:**  
Related to `F-01`.

---

### [F-04] Absence of kernel-owned GDT, TSS, and IST stacks (`ist = 0` on all IDT gates)

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
GDT module ([`kernel/src/arch/x86_64/gdt/gdt.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/gdt/gdt.zig)) and IDT gate configuration ([`kernel/src/arch/x86_64/idt/idt.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig)).

**Source location:**  
- [`kernel/src/arch/x86_64/gdt/gdt.zig:1-38`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/gdt/gdt.zig#L1-L38)
- [`kernel/src/arch/x86_64/idt/idt.zig:44-49`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig#L44-L49)

**Evidence:**  
[`kernel/src/arch/x86_64/gdt/gdt.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/gdt/gdt.zig) defines selector constants (`0x28`, `0x30`) and segment-register readers (`getCs()`, `getDs()`, `getSs()`) without defining or loading a kernel GDT or Task State Segment (TSS). In [`kernel/src/arch/x86_64/idt/idt.zig:48`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig#L48), all 256 IDT gates are configured with `ist = 0`:
```zig
idt_table[i].setGate(handler_addr, kernel_cs, 0x8E, 0);
```

**Technical explanation:**  
Five architectural boundaries must be distinguished:
1. **Current source facts:** The kernel does not own a GDT or TSS; `lgdt` and `ltr` are not executed, and all 256 IDT entries use `ist = 0`.
2. **Limine bootloader guarantees:** Limine 12.9.6 initializes a valid 64-bit GDT (`CS = 0x28`, `DS = SS = 0x30`) and a 64 KiB stack (`stack_size_request`) in `.bootloader_reclaimable` memory prior to kernel entry. During normal Phase 1 Ring 0 execution, a triple fault is **not** inevitable; the kernel boots, runs all Phase 1 self-tests, and enters `haltLoop()` cleanly.
3. **Conditional stack-overflow scenario:** Because Vector 8 (`#DF` Double Fault) has `ist = 0`, if a kernel bug (such as unbounded recursion) ever exhausts the active kernel stack into an unmapped page, the CPU cannot push the `#PF` frame or the subsequent `#DF` frame onto the invalid `%rsp`, escalating a stack overflow into a silent Triple Fault instead of a logged `#DF` panic.
4. **Requirement before reclaiming bootloader memory:** Because the active GDT resides in `.bootloader_reclaimable` physical frames, the kernel **must** load its own GDT in kernel `.data`/`.bss` (`lgdt` + segment reload) before `.bootloader_reclaimable` frames are ever freed to the PMM.
5. **Requirement before Phase 2 (Ring 3, scheduling, and critical exception isolation):** Transitioning between Ring 3 and Ring 0 requires `TSS.RSP0` loaded via a 16-byte TSS descriptor in a kernel-owned GDT (`ltr`), and isolating `#DF` (Vector 8) and `#NMI` (Vector 2) requires dedicated `IST` stacks (`TSS.IST1`, `TSS.IST2`).

**Reproduction scenario:**  
In the current snapshot, `idt_table[8].ist` is `0`. Only if `%rsp` points to an unmapped page when an exception occurs does `#PF` $\to$ `#DF` fail to push its frame and triple-fault.

**Impact:**  
No dedicated emergency stack (`IST`) for `#DF`/`#NMI` on kernel stack exhaustion, and a hard architectural prerequisite before reclaiming `.bootloader_reclaimable` memory or enabling Ring 3 in Phase 2.

**Recommended correction:**  
Prior to Phase 2 authorization (and before any `.bootloader_reclaimable` reclamation), implement a kernel-owned GDT containing 64-bit Ring 0 code/data descriptors, Ring 3 code/data descriptors, and a 16-byte 64-bit TSS descriptor; load it via `lgdt` and `ltr`; allocate an emergency stack for `TSS.IST1`; and set `ist = 1` on `idt_table[8]` (`#DF`).

**Regression tests:**  
1. **Same-CPL interrupt without IST (`CPL 0 -> CPL 0`, `IST = 0`):** Extend `idt.testExceptionDispatch()` / `idt.testPageFaultHandling()` to assert that the hardware-pushed `frame.cs == gdt.getCs()`, `frame.ss == gdt.getSs()`, and `frame.rsp` matches the pre-interrupt Ring 0 `%rsp`.
2. **IST stack switch (`CPL 0 -> CPL 0`, `IST != 0`):** Once the kernel GDT and TSS are loaded (`sgdt`/`str` verified), trigger an exception/interrupt on an `IST1`-configured gate and assert that handler execution switches `%rsp` into the `IST1` buffer while `frame.rsp` and `frame.ss` record the interrupted kernel stack pointer and segment selector.
3. **Privilege-level transition (`CPL 3 -> CPL 0`, Phase 2+):** Once Ring 3 is implemented, trigger an interrupt from Ring 3 and assert `%rsp` switches to `TSS.RSP0` while `frame.cs`, `frame.rsp`, and `frame.ss` record the Ring 3 context.

**Dependencies:**  
Governed by [`ADR-0003`](file:///home/leevawn/Projects/zig-os/docs/adr/0003-limine-gdt-preservation-phase1.md) (must be superseded or updated when the custom GDT/TSS is introduced).

---

### [F-05] (REJECTED — Moved to `R-08`) `InterruptFrame` unconditionally defines `rsp` and `ss` and `logException()` reads them during same-privilege (`IST = 0`) exceptions

**Status:** REJECTED (See [`R-08`](#5-rejected-findings-register))

**Severity:** N/A (Rejected)

**Confidence:** HIGH

**Affected component:**  
Interrupt frame structure and exception logger ([`kernel/src/arch/x86_64/idt/handlers.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig)).

**Source location:**  
[`kernel/src/arch/x86_64/idt/handlers.zig:6-34`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34) and [`kernel/src/arch/x86_64/idt/handlers.zig:147-151`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L147-L151).

**Evidence & Rejection Summary:**  
Per **Intel SDM Vol. 3A, Section 6.14.2 ("64-Bit Mode Stack Frame")** and **AMD64 APM Vol. 2, Section 8.9.3 ("Interrupt Stack Frame")**, unlike legacy 32-bit IA-32 protected mode, 64-bit long mode **unconditionally pushes `SS` and `RSP`** onto the interrupt stack frame on every interrupt and exception — including same-privilege (`CPL 0 -> CPL 0`) interrupts with `IST = 0` — and `IRETQ` unconditionally pops `RIP`, `CS`, `RFLAGS`, `RSP`, and `SS`. Therefore, `frame.rsp` (offset `+160`) and `frame.ss` (offset `+168`) in [`InterruptFrame`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L28-L34) are always present on valid long-mode interrupt paths, and reading them in `logException()` is architecturally correct (see `R-08`). Runtime test coverage for `frame.rsp` and `frame.ss` across same-CPL (`IST = 0`), IST-switched (`IST != 0`), and `CPL 3 -> CPL 0` transitions is consolidated into `F-04`.

---

### [F-06] Heap `deallocate()` accepts interior pointers, alignment-padding pointers, and tail-slack pointers

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
[`kernel/src/mm/heap.zig:109-140`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L109-L140) and [`kernel/src/mm/heap.zig:155-190`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L155-L190).

**Evidence:**  
In [`allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L109-L140):
```zig
const payload_addr = @intFromPtr(block) + HEADER_SIZE;
const aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1);
const align_offset = aligned_payload - payload_addr;
const total_needed = aligned_size + align_offset;
...
return @ptrFromInt(aligned_payload);
```
In [`deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L165-L173):
```zig
while (curr) |block| {
    const payload_start = @intFromPtr(block) + HEADER_SIZE;
    const payload_end = payload_start + block.size;
    if (raw_addr >= payload_start and raw_addr < payload_end) {
        found_block = block;
        break;
    }
    curr = block.next;
}
```

**Technical explanation:**  
`BlockHeader` is 40 bytes (`HEADER_SIZE = 40 = 0x28`). When `block` starts at a page-aligned address such as `HEAP_START = 0xffff_9000_0000_0000`, `payload_start` is `0xffff_9000_0000_0028` (only 8-byte aligned). Even for a standard 16-byte-aligned allocation, `allocate()` rounds `aligned_payload` up to `0xffff_9000_0000_0030` (`align_offset = 8`) and returns `0xffff_9000_0000_0030`. Because `BlockHeader` does not record `aligned_payload` (or `align_offset`), `deallocate()` uses the range check `raw_addr >= payload_start and raw_addr < payload_end`, silently accepting:
1. **Alignment-padding pointers** in `[payload_start, aligned_payload)`.
2. **Interior pointers** in `(aligned_payload, aligned_payload + size)`.
3. **Unsplit tail-slack pointers** in `[aligned_payload + size, payload_end)`.

**Reproduction scenario:**  
```zig
const p = heap.allocate(64, 16).?; // returns 0xffff_9000_0000_0030 (payload_start = 0x...0028, payload_end = 0x...0070)
heap.deallocate(p + 17);           // 0xffff_9000_0000_0041 is inside [0x...0028, 0x...0070) -> silently frees `p`!
```

**Impact:**  
Silently frees active allocations when passed an interior or offset pointer, masking caller pointer-arithmetic bugs and causing use-after-free heap corruption.

**Recommended correction:**  
Store `align_offset: u32` inside [`BlockHeader`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L15-L23) (replacing 4 of the 7 `padding: [7]u8` bytes so `@sizeOf(BlockHeader)` remains 40 bytes), and require `raw_addr == payload_start + block.align_offset` in `deallocate()`, panicking if `raw_addr` does not match the exact returned payload pointer.

**Regression tests:**  
1. Unit test verifying `deallocate()` succeeds for the exact pointer `p = allocate(128, 64).?` and panics/rejects `p - 8` (alignment padding), `p + 1` (interior pointer), and `p + 128` (tail slack).

**Dependencies:**  
None.

---

### [F-07] PMM `highest_address` and bitmap size are computed across all memory map entries including reserved and MMIO regions

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
[`kernel/src/mm/physical.zig:54-83`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L54-L83).

**Evidence:**  
```zig
for (0..memmap.entry_count) |i| {
    const entry = memmap.entries[i];
    const entry_top = entry.base + entry.length;
    if (entry_top > highest_address) {
        highest_address = entry_top;
    }
    if (entry.type == .usable) {
        total_usable_bytes += entry.length;
    }
}

total_pages = @intCast((highest_address + PAGE_SIZE - 1) / PAGE_SIZE);
bitmap_size_bytes = (total_pages + 7) / 8;
```

**Technical explanation:**  
`highest_address` is computed across **all** `memmap.entries` regardless of `entry.type`, including `.reserved`, `.framebuffer`, and `.acpi_nvs` regions (while `total_usable_bytes` on line 64 is unused). Because x86_64 memory maps include `.reserved` firmware ROM / APIC MMIO regions up to `4 GiB` (`0x1_0000_0000`) and, on systems with 64-bit PCIe BARs, `.reserved` apertures at multi-terabyte physical addresses (e.g., `1 TiB`..`64 TiB`), sizing the flat bitmap to `highest_address` wastes RAM across non-RAM MMIO holes and will fail to find a contiguous `.usable` region large enough to hold `bitmap_size_bytes` on systems with high 64-bit MMIO entries, panicking at line 82.

**Reproduction scenario:**  
With 256 MiB of `.usable` RAM (`8,192` B bitmap needed) and a standard `4 GiB` `.reserved` top entry, `bitmap_size_bytes` is inflated 16x to `131,072` B (`128 KiB`). With a `.reserved` 64-bit PCIe aperture at `16 TiB` (`0x1000_0000_0000`), `bitmap_size_bytes` becomes `512 MiB` (`> 256 MiB` total RAM), causing `pmm.init()` to panic at line 82.

**Impact:**  
16x bitmap bloat on standard 256 MiB QEMU and immediate boot panic on hardware/VMs with high 64-bit PCIe MMIO apertures.

**Recommended correction:**  
Compute `highest_address` only across RAM-backed memory map types (`.usable`, `.bootloader_reclaimable`, `.acpi_reclaimable`, `.executable_and_modules`), excluding `.reserved`, `.framebuffer`, `.acpi_nvs`, and `.bad_memory` apertures.

**Regression tests:**  
1. Host unit test passing a memory map with 256 MiB `.usable` RAM and a `.reserved` entry at `0x4000_0000_0000` (`64 TiB`), asserting `total_pages` and `bitmap_size_bytes` reflect the RAM ceiling rather than the 64 TiB MMIO hole.

**Dependencies:**  
Related to `F-08` and `F-16`.

---

### [F-08] PMM `freePage()` lacks allocatable-RAM range, reserved-region, and bitmap-overlap validation

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
[`kernel/src/mm/physical.zig:87-118`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L87-L118) and [`kernel/src/mm/physical.zig:197-220`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L197-L220).

**Evidence:**  
In [`init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L87-L118), the 1-bit-per-frame bitmap sets `1` (`isBitSet(frame) == true`) for all non-free frames: allocated `.usable` frames, reserved `< 1 MiB` frames, `.reserved` MMIO frames, `.executable_and_modules` kernel frames, `.bootloader_reclaimable` frames, and the PMM bitmap's own physical frames.  
In [`freePage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L197-L214):
```zig
pub fn freePage(paddr: u64) void {
    if (paddr % PAGE_SIZE != 0) {
        @panic("PMM: Attempted to free unaligned physical address");
    }

    const frame: usize = @intCast(paddr / PAGE_SIZE);
    if (frame >= total_pages) {
        @panic("PMM: Physical address out of tracked bounds");
    }

    // Double-free prevention check
    if (!isBitSet(frame)) {
        @panic("PMM: Double-free detected on physical page");
    }

    clearBit(frame);
```

**Technical explanation:**  
A 1-bit allocation bitmap cannot prove which caller owns an allocated `.usable` frame. However, `freePage()` must still enforce static physical memory safety boundaries so that non-allocatable or permanently protected physical frames can never be injected into the free pool. Currently, because `isBitSet(frame)` is `true` for every protected/reserved frame below `highest_address`, `freePage()` accepts and marks `FREE` (`0`):
1. Protected low-memory frames (`paddr < 0x100000`, including physical page `0x0`).
2. Frames overlapping the PMM bitmap itself (`[bitmap_phys, bitmap_end_phys)`).
3. Frames outside `.usable` memory map entries (such as `.executable_and_modules` kernel frames, `.bootloader_reclaimable` page-table/stack frames, and `.reserved` MMIO holes below `highest_address`).

**Reproduction scenario:**  
Calling `pmm.freePage(0x0)` or `pmm.freePage(bitmap_phys)` passes the alignment check (`% 4096 == 0`), bounds check (`frame < total_pages`), and `isBitSet(frame)` check (`true`), clearing bit `0` or the bitmap's own frame bit so the next `allocPage()` returns and zeroes page `0x0` or the PMM bitmap itself.

**Impact:**  
Overwriting the PMM bitmap, active kernel image, or bootloader page tables if an invalid physical address in a reserved/protected range is passed to `freePage()`.

**Recommended correction:**  
While keeping the existing page-alignment (`paddr % PAGE_SIZE != 0`), bounds (`frame >= total_pages`), and double-free (`!isBitSet(frame)`) checks, add three explicit validations in `freePage()`:
1. **Protected low-memory check:** Reject `paddr < 0x100000` (`1 MiB`).
2. **Bitmap self-overlap check:** Record `bitmap_phys_start` and `bitmap_phys_end` in `pmm` globals during `init()` and reject any `paddr` overlapping `[bitmap_phys_start, bitmap_phys_end)`.
3. **Allocatable-RAM membership check:** Verify that `paddr` lies within a `.usable` region of the Limine memory map.

**Regression tests:**  
1. Unit tests verifying `freePage()` panics on `paddr = 0x0`, `paddr = 0x80000` (`< 1 MiB`), `paddr = bitmap_phys_start`, and `paddr` inside a `.reserved` or `.executable_and_modules` region, while still panicking on double-free of a valid `.usable` frame.

**Dependencies:**  
Related to `F-07` and `F-16`.

---

### [F-09] VMM `mapPage()` and `unmapPage()` do not check `Flags.HUGE`, corrupting 1 GiB / 2 MiB huge pages if traversed

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Virtual Memory Manager ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)).

**Source location:**  
[`kernel/src/mm/virtual.zig:74-90`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L74-L90) and [`kernel/src/mm/virtual.zig:108-116`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L108-L116).

**Evidence:**  
Unlike [`virtToPhys()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L133-L147) (which checks `(pdpt.entries[pdpt_i] & Flags.HUGE) != 0` and `(pd.entries[pd_i] & Flags.HUGE) != 0`), neither [`mapPage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L74-L90) nor [`unmapPage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L108-L116) checks `Flags.HUGE` (`1 << 7`) before treating `pdpt.entries[pdpt_i]` or `pd.entries[pd_i]` as the physical address of a next-level `PageTable`.

**Technical explanation:**  
When `Flags.HUGE` (`PS`, bit 7) is set on a `PDPTE` (1 GiB huge page) or `PDE` (2 MiB huge page) — as Limine uses in the HHDM — the entry's physical address points to a 1 GiB or 2 MiB data frame, not a 4 KiB child `PageTable`. Calling `mapPage()` or `unmapPage()` on an address inside a huge page dereferences that data frame as a `PageTable` and writes an 8-byte PTE or `0` directly into the mapped physical memory.

**Reproduction scenario:**  
Calling `vmm.mapPage()` or `vmm.unmapPage()` on a virtual address inside a 2 MiB huge page (`pd.entries[pd_i] = phys_base | Flags.PRESENT | Flags.WRITABLE | Flags.HUGE`) interprets `phys_base` as a `PageTable` and corrupts `(phys_base + hhdm_offset)[pt_i * 8]`.

**Impact:**  
Silent corruption of physical memory backing 1 GiB or 2 MiB huge pages if `mapPage()` or `unmapPage()` is called on a huge-page-mapped virtual address.

**Recommended correction:**  
Check `(pdpt.entries[pdpt_i] & Flags.HUGE) != 0` and `(pd.entries[pd_i] & Flags.HUGE) != 0` in both `mapPage()` and `unmapPage()` and return `error.HugePageConflict` (or `error.AlreadyMapped`) before dereferencing child tables.

**Regression tests:**  
1. Test `mapPage()` and `unmapPage()` against a `PageTable` containing a 1 GiB (`PDPTE`) and 2 MiB (`PDE`) `Flags.HUGE` entry and assert both return an error without modifying the target frame.

**Dependencies:**  
Related to `F-13`.

---

### [F-10] Host unit test suite (`tests/unit_test.zig`) lacks a testable kernel module architecture for stateful PMM, VMM, and Heap cores (`F-10A` pure-module extraction completed; `F-10B` pending)

**Status:** VERIFIED (`OPEN` — `F-10A` Pure-Module Extraction Completed at `9df21f8`; `F-10B` Stateful Core Testability Pending)

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Host unit test suite ([`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig)), build configuration ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig)), shared pure production modules ([`kernel/src/mm/paging_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig), [`kernel/src/mm/physical_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig), [`kernel/src/arch/x86_64/interrupts/page_fault.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig), [`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig)), and stateful kernel memory managers ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig), [`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig), [`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
- [`tests/unit_test.zig:1-222`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L1-L222)
- [`build.zig:123-155`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L155)
- [`kernel/src/mm/paging_math.zig:1-30`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig#L1-L30) and [`kernel/src/mm/virtual.zig:6-14, 38-155`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L6-L14)
- [`kernel/src/mm/physical_math.zig:1-29`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig#L1-L29) and [`kernel/src/mm/physical.zig:6-119, 131-243`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L6-L119)
- [`kernel/src/arch/x86_64/interrupts/page_fault.zig:1-20`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig#L1-L20) and [`kernel/src/arch/x86_64/idt/handlers.zig:5-7, 127-133`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L5-L7)
- [`kernel/src/mm/heap_layout.zig:1-14`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L1-L14) and [`kernel/src/mm/heap.zig:15-18, 34-210`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L15-L18)

**Evidence:**  
1. **Completed `F-10A` Pure-Module Extraction (Snapshot `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`):**
   - **Independently Reviewed Source Structure:** Direct source inspection of commit `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (and current snapshot `771146810e41854f2b9e754f2a048f142ab633a8`) confirms that all previously duplicated pure functions and layout structures were extracted into four hardware-independent production modules under `kernel/src/` and wired into both the freestanding kernel and [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig):
     - [`kernel/src/mm/paging_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig): Defines `PAGE_SIZE`, `pml4Index`, `pdptIndex`, `pdIndex`, `ptIndex`, and `pageOffset`, imported and re-exported by [`kernel/src/mm/virtual.zig:6-14`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L6-L14).
     - [`kernel/src/mm/physical_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig): Defines `PAGE_SIZE`, `totalPagesFromBytes`, `bitmapSizeBytes`, `physToFrame`, `frameToByteIndex`, and `frameToBitIndex`, imported and used across [`kernel/src/mm/physical.zig:6-119, 208-240`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L6-L119).
     - [`kernel/src/arch/x86_64/interrupts/page_fault.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig): Defines `PageFaultCause` and `PageFaultCause.decode()`, imported and used by [`kernel/src/arch/x86_64/idt/handlers.zig:5-7, 127-133`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L5-L7).
     - [`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig): Defines `BlockHeader` (`extern struct`, `@sizeOf(BlockHeader) == 40`, `@alignOf(BlockHeader) == 8`) and `HEADER_SIZE`, imported and re-exported by [`kernel/src/mm/heap.zig:15-18`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L15-L18).
     - [`build.zig:123-155`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L155) and [`tests/unit_test.zig:5-222`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L5-L222): `build.zig` exposes `paging_math`, `physical_math`, `page_fault`, and `heap_layout` via `test_mod.addAnonymousImport(...)`, and `tests/unit_test.zig` imports those four production modules directly with all local duplicate helper and struct definitions removed.
   - **Agent-Reported Build & Runtime Evidence (`F-10A` at `9df21f8`):** The implementation agent reported:
     - `7/7` host unit tests passing (`zig build test --summary all` and direct `zig test` execution).
     - `Debug` (`zig build -Doptimize=Debug --summary all`) and `ReleaseSafe` (`zig build -Doptimize=ReleaseSafe --summary all`) freestanding kernel builds succeeding with zero warnings or errors.
     - Fresh hybrid ISO (`build/zig-os.iso`, SHA-256 `0335e152875e8cdc4b75cd33ea937cdbc1c9e639495dce8b55cb5a0b67d6e78b`, packaging `zig-out/bin/kernel.elf` `0704203edb046d847ad73bb8df3b5ef7d13118ee40a3204d1f6d96e33d47e964`) booting cleanly under QEMU and passing all 12 checks in `./scripts/test-boot.sh`.
2. **Remaining `F-10B` Stateful Hardware-Boundary Problem (Snapshot `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`):**
   - While pure indexing and layout definitions are now shared (`F-10A`), the stateful allocation, mapping, and coalescing algorithms in [`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig), [`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig), and [`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig) remain directly coupled to Limine global responses (`limine.hhdm_request`, `limine.memmap_request`), module-level globals (`hhdm_offset`, `bitmap`, `head_block`, `current_heap_end`), higher-half virtual addresses (`HEAP_START = 0xffff_9000_0000_0000`), and privileged CPU instructions (`cpu.readCr3()`, `cpu.invlpg()`), preventing them from being imported and exercised by host unit tests.
3. **Historical Audit Evidence (Original Baseline `c10c05f1f37aacfda5046480a314f29d940b67ef`):**
   - At original baseline `c10c05f1`, `tests/unit_test.zig:6-20, 63-79, 107-115` defined standalone local copies of `pml4Index`, `pdptIndex`, `pdIndex`, `ptIndex`, `pageOffset`, `PageFaultCause`, and `BlockHeader` with zero `@import` references to `kernel/src/` (remediated in `9df21f8b` by `F-10A`).

**Technical explanation:**  
With `F-10A` complete at `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`, `zig build test` now compiles and exercises the four shared pure production modules (`paging_math.zig`, `physical_math.zig`, `page_fault.zig`, `heap_layout.zig`). However, `F-10` remains **OPEN (`VERIFIED`, `P0`)** because `F-10B` is not yet implemented: the stateful algorithms in `kernel/src/mm/physical.zig` (`init`, `allocPage`, `allocPages`, `freePage`, `freePages`), `kernel/src/mm/virtual.zig` (`mapPage`, `unmapPage`, `virtToPhys`), and `kernel/src/mm/heap.zig` (`init`, `expandHeap`, `allocate`, `deallocate`) directly access hardware control registers (`CR3`, `invlpg`), HHDM physical-to-virtual pointer offsets, and Limine bootloader globals. Without injectable/parameterized backing interfaces or separated stateful core structs (`F-10B`), `zig build test` still cannot compile or exercise `physical.zig`, `virtual.zig`, or `heap.zig` on the Linux host.

**Reproduction scenario:**  
Introducing a logic defect or syntax error inside the stateful functions of `kernel/src/mm/heap.zig` (e.g., `allocate`, `deallocate`, `expandHeap`), `kernel/src/mm/physical.zig` (e.g., `init`, `allocPage`, `freePage`), or `kernel/src/mm/virtual.zig` (e.g., `mapPage`, `unmapPage`) still does not cause `zig build test` to fail (`3/3 steps succeeded`), because `zig build test` only compiles the four extracted pure modules (`paging_math`, `physical_math`, `page_fault`, `heap_layout`).

**Impact:**  
While pure math and struct layout regressions are now caught by `zig build test` (`F-10A`), stateful PMM, VMM, and Heap invariants (`F-06`–`F-09`, `F-11`–`F-13`) still lack host unit test coverage, and [`ADR-0004:38`](file:///home/leevawn/Projects/zig-os/docs/adr/0004-segregated-heap-allocator-canaries.md#L38) continues to overstate what `tests/unit_test.zig` verifies until `F-10B` is completed.

**Recommended correction:**  
Do **not** blindly import privileged hardware-touching code into host tests. Complete the two-part testable kernel architecture:
1. **`F-10A` — Pure logic & data-structure modules (`COMPLETED` at `9df21f8`):** Extracted `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` as hardware-independent production modules imported directly by both the freestanding kernel and `tests/unit_test.zig` (expandable with additional pure helpers such as `isCanonical` or `computeSseCr0` as `F-13`/`F-15` are implemented).
2. **`F-10B` — Injectable / parameterized stateful backends (`PENDING`):** Refactor the stateful `pmm`, `vmm`, and `heap` core algorithms to operate over explicit state structs or compile-time-injected backing interfaces (accepting a caller-supplied memory map slice, simulated HHDM/backing buffer, and no-op TLB flush hook during host unit tests while binding to `limine` and `cpu.zig` in the freestanding kernel build).

**Regression tests:**  
1. **Completed (`F-10A`):** Verify `tests/unit_test.zig` contains zero duplicated kernel struct/function definitions and directly imports the shared pure production modules (`paging_math`, `physical_math`, `page_fault`, `heap_layout`).
2. **Pending (`F-10B`):** Verify that breaking a stateful production invariant in the PMM, VMM, or Heap core causes `zig build test` to fail.

**Dependencies:**  
Foundational `P0` requirement (`F-10B`) to enable host unit testing of stateful memory-management findings `F-06`–`F-09` and `F-11`–`F-13`.

---

### [F-11] Heap `allocate()` omits alignment padding in `pages_needed` and ignores partial expansion progress in `expandHeap()`

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
[`kernel/src/mm/heap.zig:46-97`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L46-L97) and [`kernel/src/mm/heap.zig:146-152`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L146-L152).

**Evidence:**  
```zig
// Need more memory: expand heap by required pages
const pages_needed = (aligned_size + HEADER_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
if (expandHeap(@max(pages_needed, 4))) {
    return allocate(size, alignment);
}

return null; // Out of memory
```

**Technical explanation:**  
1. **Missing alignment padding in `pages_needed`:** Inside the search loop (line 112), the required block payload is `total_needed = aligned_size + align_offset`, where `align_offset` is `8` bytes for `align_val == 16` on a page-aligned block (`HEADER_SIZE = 40`) and up to `align_val - 8` bytes for larger alignments. Line 147 omits `align_offset` when computing `pages_needed`, so `expandHeap()` can map a block that is still smaller than `total_needed`, triggering a second recursive `expandHeap()` call.
2. **False allocation failure on partial expansion (no memory leak):** In `expandHeap(page_count)`, each mapped page is immediately initialized as a `FREE` `BlockHeader`, linked into `head_block`, and coalesced with `curr` if `curr.is_free`. Thus, partial expansion does **not** leak physical frames or virtual pages (`R-06`). However, because `allocate()` passes `@max(pages_needed, 4)` and only retries if `expandHeap()` returns `true` for all requested pages (and ignores any pre-existing free capacity in a `FREE` tail block), `allocate()` falsely returns `null` if `expandHeap()` stops after mapping `k < @max(pages_needed, 4)` pages even when those `k` pages (plus any coalesced free tail block) are large enough to satisfy the request.
3. **Unchecked `init()` expansion:** `heap.init()` (`line 41`) ignores the return value of `_ = expandHeap(initial_pages);` and sets `initialized = true`.

**Reproduction scenario:**  
1. **Under-expansion:** After `heap.init(4)` and `b1 = heap.allocate(16320, 16)` (which marks the initial 4-page block `USED` without splitting), calling `heap.allocate(16336, 64)` computes `pages_needed = (16336 + 40 + 4095) / 4096 = 4`. `expandHeap(4)` creates a 4-page free block at `0xffff_9000_0000_4000` with `size = 16344`. On the recursive `allocate(16336, 64)` call, `payload_addr = 0x...4028`, `aligned_payload = 0x...4040`, `align_offset = 24`, and `total_needed = 16336 + 24 = 16360 > 16344`, forcing a second recursive `expandHeap(4)` call (8 pages = 32 KiB mapped for a 16 KiB request).
2. **False OOM on partial expansion:** When 2 pages (`8,192` B) remain before `HEAP_MAX_SIZE`, `allocate(4096, 16)` computes `pages_needed = 2`, calls `expandHeap(@max(2, 4))` = `expandHeap(4)`, maps 2 pages (`8,152` B free block), hits `HEAP_MAX_SIZE` on iteration 2, returns `false`, and `allocate(4096, 16)` returns `null`.

**Impact:**  
Unnecessary multi-page over-expansion on aligned allocations (`alignment >= 64`) and false Out-Of-Memory returns when fewer than 4 pages remain before `HEAP_MAX_SIZE` or PMM exhaustion.

**Recommended correction:**  
Include worst-case alignment padding in `pages_needed`, account for an existing `FREE` tail block's capacity when calculating additional pages needed, retry `allocate()` (or clamp `page_count` to `>= pages_needed`) if `expandHeap()` mapped enough pages to satisfy the request, and assert `expandHeap(initial_pages)` succeeds in `heap.init()`.

**Regression tests:**  
1. Unit test verifying `init(4)` $\to$ `allocate(16320, 16)` $\to$ `allocate(16336, 64)` expands the heap once (by 5 pages) rather than twice (8 pages).
2. Unit test verifying `allocate(4096, 16)` succeeds when only 2 pages of headroom remain below `HEAP_MAX_SIZE`.

**Dependencies:**  
Related to `F-12`.

---

### [F-12] Unchecked integer arithmetic overflow and missing power-of-two `alignment` validation in `heap.allocate()`

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
[`kernel/src/mm/heap.zig:99-112`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L99-L112) and [`kernel/src/mm/heap.zig:147`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L147).

**Evidence:**  
```zig
pub fn allocate(size: usize, alignment: usize) ?[*]u8 {
    if (size == 0) return null;

    const align_val = @max(alignment, 16);
    // Align request size to 16 bytes for System V alignment
    const aligned_size = (size + 15) & ~@as(usize, 15);
    ...
            const payload_addr = @intFromPtr(block) + HEADER_SIZE;
            const aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1);
            const align_offset = aligned_payload - payload_addr;
            const total_needed = aligned_size + align_offset;
    ...
    const pages_needed = (aligned_size + HEADER_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
```

**Technical explanation:**  
1. **Arithmetic overflow:** Passing `size > std.math.maxInt(usize) - 15` overflows `size + 15` (line 104), and large `size` or `alignment` values overflow `payload_addr + align_val - 1` (line 110), `aligned_size + align_offset` (line 112), or `aligned_size + HEADER_SIZE + pmm.PAGE_SIZE - 1` (line 147), triggering an integer-overflow panic in `Debug`/`ReleaseSafe` (or wrapping in `ReleaseFast`) instead of returning `null`.
2. **Unvalidated `alignment` in `pub fn allocate`:** While `heapAlloc` receives `std.mem.Alignment`, `pub fn allocate(size: usize, alignment: usize)` does not check `std.math.isPowerOfTwo(alignment)`. For a non-power-of-two `alignment > 16` (e.g., `24`), `(payload_addr + align_val - 1) & ~(align_val - 1)` produces an unaligned address.

**Reproduction scenario:**  
1. `heap.allocate(std.math.maxInt(usize), 16)` panics with `integer overflow` at line 104 instead of returning `null`.
2. `heap.allocate(64, 24)` on `payload_addr = 0xffff_9000_0000_0028` computes `(0x...0028 + 23) & ~23 = 0xffff_9000_0000_0028`, which is neither 24-byte aligned nor 16-byte aligned.

**Impact:**  
Kernel panic on overflowing allocation requests and misaligned pointers if `allocate()` is called directly with a non-power-of-two alignment.

**Recommended correction:**  
Validate `if (alignment != 0 and !std.math.isPowerOfTwo(alignment)) return null;` (or panic on invalid alignment) and bound `if (size > HEAP_MAX_SIZE or align_val > HEAP_MAX_SIZE) return null;` at the top of `allocate()`.

**Regression tests:**  
1. Unit test verifying `allocate(std.math.maxInt(usize), 16)` and `allocate(64, 24)` return `null` cleanly.

**Dependencies:**  
Related to `F-11`.

---

### [F-13] VMM `mapPage()` and `unmapPage()` lack 48-bit canonical address validation, alignment checks, and parent `Flags.USER` propagation

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Virtual Memory Manager ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)).

**Source location:**  
[`kernel/src/mm/virtual.zig:57-123`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L57-L123).

**Evidence:**  
```zig
pub fn mapPage(
    pml4: *PageTable,
    virt: u64,
    phys: u64,
    flags: u64,
) error{ OutOfMemory, AlreadyMapped }!void {
    const intermediate_flags = Flags.PRESENT | Flags.WRITABLE | (flags & Flags.USER);

    // Level 4: PML4 -> PDPT
    const pml4_i = pml4Index(virt);
    if ((pml4.entries[pml4_i] & Flags.PRESENT) == 0) {
        const new_table_phys = pmm.allocPage() orelse return error.OutOfMemory;
        pml4.entries[pml4_i] = new_table_phys | intermediate_flags;
    }
```

**Technical explanation:**  
1. **Missing canonicality validation:** `pml4Index(virt)` masks `(virt >> 39) & 0x1FF`, ignoring bits `48..63`. Passing a non-canonical `virt` (where bits `48..63` do not equal bit `47`) silently modifies the page table entry of its 48-bit canonical alias while `invlpg` on the non-canonical address acts as a no-op.
2. **Missing page-alignment checks:** Neither `mapPage()` nor `unmapPage()` validates `virt % PAGE_SIZE == 0` or `phys % PAGE_SIZE == 0`.
3. **Missing `Flags.USER` propagation to existing parent entries:** If `pml4.entries[pml4_i]`, `pdpt.entries[pdpt_i]`, or `pd.entries[pd_i]` was previously allocated for a supervisor page (`Flags.USER == 0`), a later `mapPage()` call with `Flags.USER` in the same subtree skips the `if ((entry & Flags.PRESENT) == 0)` block and leaves `Flags.USER` cleared on the parent entry, causing Ring 3 accesses to fault with `#PF` (`U=1, P=1`).

**Reproduction scenario:**  
Mapping `0x0000_0040_0000_0000` with `Flags.WRITABLE` followed by `0x0000_0040_0000_1000` with `Flags.WRITABLE | Flags.USER` leaves `Flags.USER == 0` on `pml4[0]`, `pdpt[256]`, and `pd[0]`.

**Impact:**  
Silent canonical aliasing on non-canonical addresses and broken Ring 3 user page permissions when sharing intermediate page tables.

**Recommended correction:**  
Validate 48-bit canonicality (`(@as(i64, @bitCast(virt)) >> 47) == 0 or (@as(i64, @bitCast(virt)) >> 47) == -1`) and 4 KiB alignment (`virt % PAGE_SIZE == 0` and `phys % PAGE_SIZE == 0`) in `mapPage()`/`unmapPage()`, and OR `(flags & Flags.USER)` into already-present `PML4E`, `PDPTE`, and `PDE` entries in `mapPage()`.

**Regression tests:**  
1. Unit test verifying `mapPage()` rejects non-canonical `virt = 0x0001_0000_0000_0000` and unaligned `virt`/`phys`.
2. Unit test verifying `Flags.USER` is set on `PML4E`, `PDPTE`, and `PDE` when a user page is mapped into a subtree previously created by a supervisor mapping.

**Dependencies:**  
Related to `F-09`.

---

### [F-14] Direct execution of `scripts/test-boot.sh` and `tests/test_boot.py` skips rebuilding when `build/zig-os.iso` exists, obscuring QEMU test provenance

**Status:** FIXED (Independently Source-Audited at `771146810e41854f2b9e754f2a048f142ab633a8`; Build, QEMU Smoke-Test, & Regression Suite `E.1`–`E.7` Agent-Reported)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Build graph, ISO packager, provenance verifier, and public run/debug/test entrypoints ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`scripts/build.sh`](file:///home/leevawn/Projects/zig-os/scripts/build.sh), [`scripts/package-iso.sh`](file:///home/leevawn/Projects/zig-os/scripts/package-iso.sh), [`scripts/lib/common.sh`](file:///home/leevawn/Projects/zig-os/scripts/lib/common.sh), [`scripts/lib/provenance.sh`](file:///home/leevawn/Projects/zig-os/scripts/lib/provenance.sh), [`scripts/lib/qemu-runner.sh`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh), [`scripts/test-boot.sh`](file:///home/leevawn/Projects/zig-os/scripts/test-boot.sh), [`scripts/run.sh`](file:///home/leevawn/Projects/zig-os/scripts/run.sh), [`scripts/debug.sh`](file:///home/leevawn/Projects/zig-os/scripts/debug.sh), [`tests/test_boot.py`](file:///home/leevawn/Projects/zig-os/tests/test_boot.py)).

**Source location:**  
- [`build.zig:22-121`](file:///home/leevawn/Projects/zig-os/build.zig#L22-L121)
- [`scripts/build.sh:1-20`](file:///home/leevawn/Projects/zig-os/scripts/build.sh#L1-L20)
- [`scripts/package-iso.sh:1-82`](file:///home/leevawn/Projects/zig-os/scripts/package-iso.sh#L1-L82)
- [`scripts/lib/common.sh:1-90`](file:///home/leevawn/Projects/zig-os/scripts/lib/common.sh#L1-L90)
- [`scripts/lib/provenance.sh:1-92`](file:///home/leevawn/Projects/zig-os/scripts/lib/provenance.sh#L1-L92)
- [`scripts/lib/qemu-runner.sh:1-175`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh#L1-L175)
- [`scripts/test-boot.sh:1-22`](file:///home/leevawn/Projects/zig-os/scripts/test-boot.sh#L1-L22)
- [`scripts/run.sh:1-22`](file:///home/leevawn/Projects/zig-os/scripts/run.sh#L1-L22)
- [`scripts/debug.sh:1-22`](file:///home/leevawn/Projects/zig-os/scripts/debug.sh#L1-L22)
- [`tests/test_boot.py:1-80`](file:///home/leevawn/Projects/zig-os/tests/test_boot.py#L1-L80)

**Resolution & Independent Audit Evaluation (v1.6, Commit `771146810e41854f2b9e754f2a048f142ab633a8`):**  
1. **Independently Reviewed Source Evidence against All Nine Resolution Criteria:**
   - **Criterion 1 (Direct `scripts/test-boot.sh` always builds before QEMU):** [`scripts/test-boot.sh:11-22`](file:///home/leevawn/Projects/zig-os/scripts/test-boot.sh#L11-L22) removes all `if [[ ! -f "${ISO}" ]]` skip checks, parses `--optimize` / `-Doptimize` via `resolve_optimize_from_args 0 "$@"` (rejecting any unrecognized or bypass flags), unconditionally executes `zig build -Doptimize="${ZIG_OS_SELECTED_OPTIMIZE}" iso`, and then `exec`s [`scripts/lib/qemu-runner.sh`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh) in `test-boot` mode.
   - **Criterion 2 (Direct `scripts/run.sh` and `scripts/debug.sh` always build before QEMU):** [`scripts/run.sh:11-22`](file:///home/leevawn/Projects/zig-os/scripts/run.sh#L11-L22) and [`scripts/debug.sh:11-22`](file:///home/leevawn/Projects/zig-os/scripts/debug.sh#L11-L22) identically remove all `if [[ ! -f "${ISO}" ]]` skip checks, resolve optimization flags via `resolve_optimize_from_args 0 "$@"`, unconditionally run `zig build -Doptimize="${ZIG_OS_SELECTED_OPTIMIZE}" iso`, and `exec` [`scripts/lib/qemu-runner.sh`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh) (`run` / `debug`). Likewise, [`scripts/build.sh:11-20`](file:///home/leevawn/Projects/zig-os/scripts/build.sh#L11-L20) removes `if [[ ! -f "${KERNEL_BIN}" || "${1:-}" != "iso" ]]` and unconditionally runs `exec zig build -Doptimize="${ZIG_OS_SELECTED_OPTIMIZE}" iso`.
   - **Criterion 3 (Python test delegates to the canonical path):** [`tests/test_boot.py:26-76`](file:///home/leevawn/Projects/zig-os/tests/test_boot.py#L26-L76) defines an `argparse.ArgumentParser` accepting only `--optimize` / `-Doptimize` (no `--skip-build` or bypass flags exist), normalizes the mode via `OPTIMIZE_ALIASES` (defaulting to `ReleaseSafe`), and delegates via `subprocess.run(["bash", test_script, "--optimize", optimize], cwd=repo_root)` to `scripts/test-boot.sh`, returning `res.returncode`.
   - **Criterion 4 (Zig build targets use a non-recursive build graph):** [`build.zig:60-121`](file:///home/leevawn/Projects/zig-os/build.zig#L60-L121) separates the pipeline into three non-recursive stages:
     - `install` depends on `install_kernel` (`b.addInstallArtifact(kernel, .{})`) and `log_optimize` (`printf "[BUILD] Optimization mode: %s\n"`).
     - `iso` (`iso_step`) runs `bash scripts/package-iso.sh --optimize <optimize_name>` (`iso_cmd.step.dependOn(b.getInstallStep())`). [`scripts/package-iso.sh:1-82`](file:///home/leevawn/Projects/zig-os/scripts/package-iso.sh#L1-L82) packages `zig-out/bin/kernel.elf` into `build/zig-os.iso` without invoking `zig`.
     - `run`, `debug`, and `test-boot` run `bash scripts/lib/qemu-runner.sh <mode> --optimize <optimize_name>` and depend on `iso_step`. [`scripts/lib/qemu-runner.sh:1-175`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh#L1-L175) verifies provenance and launches QEMU without invoking `zig` or `scripts/build.sh`.
   - **Criterion 5 (Default optimization is `ReleaseSafe`):** [`build.zig:25-34`](file:///home/leevawn/Projects/zig-os/build.zig#L25-L34) computes `default_optimize` from `b.graph.release_mode` (mapping `.off, .any, .safe => .safe`) as the fallback for `b.option(std.builtin.Optimize, "optimize", ...)`; [`scripts/lib/common.sh:67-71`](file:///home/leevawn/Projects/zig-os/scripts/lib/common.sh#L67-L71) defaults `raw_opt` to `ReleaseSafe`; and [`tests/test_boot.py:52`](file:///home/leevawn/Projects/zig-os/tests/test_boot.py#L52) defaults `raw_optimize` to `"ReleaseSafe"`.
   - **Criterion 6 (Explicit `Debug`, `ReleaseFast`, and `ReleaseSmall` are supported):** [`build.zig:25-40`](file:///home/leevawn/Projects/zig-os/build.zig#L25-L40) accepts all four `std.builtin.Optimize` enum values (`debug`, `safe`, `fast`, `small`) and maps them to `"Debug"`, `"ReleaseSafe"`, `"ReleaseFast"`, and `"ReleaseSmall"`; [`scripts/lib/common.sh:4-24`](file:///home/leevawn/Projects/zig-os/scripts/lib/common.sh#L4-L24) and [`tests/test_boot.py:14-23`](file:///home/leevawn/Projects/zig-os/tests/test_boot.py#L14-L23) normalize both canonical names (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) and Zig CLI enum aliases (`debug`, `safe`, `fast`, `small`).
   - **Criterion 7 (Kernel ELF in the ISO matches `zig-out/bin/kernel.elf`):** [`scripts/package-iso.sh:45-82`](file:///home/leevawn/Projects/zig-os/scripts/package-iso.sh#L45-L82) refreshes `build/iso_root`, copies `zig-out/bin/kernel.elf` to `build/iso_root/boot/kernel.elf`, builds the ISO, and calls `verify_and_log_provenance` ([`scripts/lib/provenance.sh:8-92`](file:///home/leevawn/Projects/zig-os/scripts/lib/provenance.sh#L8-L92)), which extracts `/boot/kernel.elf` from `build/zig-os.iso` via `xorriso -osirrox on -indev "${iso_file}" -extract /boot/kernel.elf "${extracted_kernel}"`, logs SHA-256 digests of `zig-out/bin/kernel.elf`, `build/iso_root/boot/kernel.elf`, `ISO:/boot/kernel.elf`, and `build/zig-os.iso` (plus optimization mode, Git commit, and working-tree status), and asserts `hash_zig_out == hash_iso_root` and `hash_zig_out == hash_extracted`.
   - **Criterion 8 (Missing artifacts, extraction errors, and hash mismatches prevent QEMU execution):** [`scripts/lib/qemu-runner.sh:2,29`](file:///home/leevawn/Projects/zig-os/scripts/lib/qemu-runner.sh#L2) runs under `set -euo pipefail` and calls `verify_and_log_provenance` at line 29 before reaching the `case "${MODE}"` QEMU invocation block (lines 31–170). In [`scripts/lib/provenance.sh:25-88`](file:///home/leevawn/Projects/zig-os/scripts/lib/provenance.sh#L25-L88), missing or empty files (`! -f` or `! -s`), `xorriso` extraction failures, empty extracted ELFs, or any mismatch among `hash_zig_out`, `hash_iso_root`, and `hash_extracted` immediately return/exit `1`, aborting before `qemu-system-x86_64` is executed.
   - **Criterion 9 (Regression suite `E.1`–`E.7` coverage):** The implementation agent reported passing execution of `verify_f14_regressions.sh` (`E.1`–`E.7`), covering stale artifact replacement on direct `scripts/test-boot.sh` (`E.1`), fresh build enforcement on `scripts/run.sh`, `scripts/debug.sh`, `zig build run`, and `zig build debug` (`E.2a`–`E.2c`), `python3 tests/test_boot.py` fresh rebuild and `--skip-build` rejection (`E.3`), `ReleaseSafe` default and single (`1`) `zig` invocation during `zig build test-boot` (`E.4`), `scripts/build.sh iso -Doptimize=Debug` fresh compilation when `kernel.elf` already exists (`E.5`), independent `xorriso` extraction hash verification (`E.6`), and non-zero abort prior to QEMU launch on build failure, missing artifact, extraction failure, and SHA-256 mismatch (`E.7a`–`E.7d`).
2. **Non-Blocking Implementation Note (Cross-Filesystem Temporary ISO Move in `scripts/package-iso.sh`):**
   - In [`scripts/package-iso.sh:57,63,77`](file:///home/leevawn/Projects/zig-os/scripts/package-iso.sh#L57), the temporary staging directory is created via `PKG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/zig-os-pkg-XXXXXX")"` and the completed image is moved to `OUTPUT_ISO` (`build/zig-os.iso`) via `mv -f "${TMP_ISO}" "${OUTPUT_ISO}"`.
   - Auditor inspection via `df -T /tmp /home/leevawn/Projects/zig-os/build` confirms `/tmp` is mounted on `tmpfs` while `/home/leevawn/Projects/zig-os/build` resides on `/dev/nvme0n1p2` (`ext4`). When `TMPDIR` is unset, `mv` from `/tmp` (`tmpfs`) to `build/` (`ext4`) crosses filesystem boundaries and therefore performs a copy-and-unlink rather than an atomic single-syscall POSIX `rename(2)`. While generating the ISO in `PKG_TMP` still prevents failed `xorriso` or `limine bios-install` commands from writing a partial file to `build/zig-os.iso`, true same-filesystem `rename(2)` atomicity would require creating the temporary file inside `${BUILD_DIR}`.
3. **Provenance Boundary (Auditor-Reviewed vs. Implementation-Agent-Reported Evidence):**
   - **Independently Audited by Argon (`v1.6`):** Full source inspection of all 10 `F-14` files at commit `771146810e41854f2b9e754f2a048f142ab633a8`, verification of Git history (`7711468` atop `9ab3f1e`), on-disk `sha256sum` check (`zig-out/bin/kernel.elf` and `build/iso_root/boot/kernel.elf` = `7b1ac542917334d3b222100f80f86bcab164134d51243340ef15db49d8d3b861`; `build/zig-os.iso` = `c819a34806abfc810a0e4faec179eeb8e9da3732639e210828d0e8fbce44ace4`), and filesystem mount inspection (`df -T`). The auditor did not re-execute `zig build` or QEMU during the `v1.6` documentation pass.
   - **Implementation-Agent-Reported (`7711468`):** Passing `zig build --summary all`, `zig build test --summary all`, `zig build -Doptimize=Debug iso --summary all` (`Debug` ELF `0704203edb046d847ad73bb8df3b5ef7d13118ee40a3204d1f6d96e33d47e964`), `zig build -Doptimize=Debug test-boot --summary all`, `zig build -Doptimize=ReleaseSafe iso --summary all` (`ReleaseSafe` ELF `7b1ac542917334d3b222100f80f86bcab164134d51243340ef15db49d8d3b861`), `./scripts/test-boot.sh`, `python3 tests/test_boot.py`, `zig build test-boot --summary all`, and regression suite `E.1`–`E.7` (with `E.2a`–`E.2c` and `E.7a`–`E.7d` using a `PATH`-stubbed `qemu-system-x86_64`).

**Historical Evidence (Baseline `c10c05f1` through `9df21f8b`):**  
Prior to `77114681`, `scripts/test-boot.sh`, `scripts/run.sh`, `scripts/debug.sh`, and `tests/test_boot.py` guarded ISO generation behind `if [[ ! -f "${ISO}" ]]` (or `if not os.path.exists(iso_path):`), `scripts/build.sh` guarded kernel compilation behind `if [[ ! -f "${KERNEL_BIN}" || "${1:-}" != "iso" ]]` while invoking `zig build -Doptimize=ReleaseSafe` recursively when called from `build.zig`, and `build.zig` used `b.standardOptimizeOption(.{})` (defaulting to `Debug`) while `scripts/build.sh` hardcoded `ReleaseSafe`.

**Dependencies:**  
None.

---

### [F-15] `cpu.enableSse()` does not clear `CR0.TS` (bit 3, Task Switched) under Limine Base Revision 3

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
CPU control register initialization ([`kernel/src/arch/x86_64/cpu.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig)) and Limine base-revision contract ([`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig)).

**Source location:**  
- [`kernel/src/arch/x86_64/cpu.zig:117-129`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129)
- [`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12)

**Evidence:**  
In [`kernel/src/arch/x86_64/cpu.zig:117-129`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129):
```zig
pub inline fn enableSse() void {
    // Clear CR0.EM (bit 2), set CR0.MP (bit 1)
    var cr0 = readCr0();
    cr0 &= ~@as(u64, 1 << 2);
    cr0 |= (1 << 1);
    writeCr0(cr0);

    // Set CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10)
    var cr4 = readCr4();
    cr4 |= (1 << 9);
    cr4 |= (1 << 10);
    writeCr4(cr4);
}
```
And in [`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12), the kernel requests **Limine Base Revision 3**:
```zig
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    3,
};
```

**Technical explanation:**  
Four distinct architectural and runtime aspects must be separated:
1. **Limine Base Revision 3 `CR0` guarantees vs. Base Revision 5+:**  
   Per the official Limine Boot Protocol specification (*Entry / Machine State — x86_64*), Limine only guarantees that all unspecified `CR0` bits are cleared to `0` starting with **Base Revision 5 or later**. Under **Base Revision 3** (requested by ZIG-OS), the protocol specifies `CR0.PE = 1`, `CR0.PG = 1`, and `CR0.WP = 1`, and does **not** guarantee that `CR0.TS` (bit 3, Task Switched) is cleared (`0`) at kernel handoff.
2. **Incomplete `CR0` initialization in `cpu.enableSse()`:**  
   `cpu.enableSse()` clears `CR0.EM` (bit 2), sets `CR0.MP` (bit 1), and sets `CR4.OSFXSR` (bit 9) and `CR4.OSXMMEXCPT` (bit 10), but does **not** clear `CR0.TS` (bit 3). Per Intel SDM Vol. 3A §2.5 and §13.1.3, whenever `CR0.TS == 1`, executing any x87/MMX/SSE instruction or `FXSAVE`/`FXRSTOR` raises `#NM` (Device Not Available, Vector 7), and executing `WAIT`/`FWAIT` when `CR0.MP == 1` and `CR0.TS == 1` also raises `#NM`.
3. **Current QEMU behavior vs. other valid Base Revision 3 bootloader handoff states:**  
   - *Current QEMU behavior (`CR0` value at entry `UNVERIFIED` by direct register capture):* During `./scripts/test-boot.sh`, the existing `kernel.elf` binary (which contains 6,904 `xmm` instructions) executes past `cpu.enableSse()` without raising `#NM` (Vector 7). While this indirectly suggests `CR0.TS` was not set when those instructions executed, the exact hardware `CR0` register value at `_start` entry in QEMU + Limine `12.9.6` was **not** captured via GDB or serial register logging during this audit and is therefore marked **`UNVERIFIED` (no direct GDB/runtime register evidence captured)**.
   - *Other valid bootloader handoff states:* Because Base Revision 3 does not require `CR0.TS == 0`, any protocol-compliant Base Revision 3 bootloader or firmware path that hands off with `CR0.TS == 1` will leave `CR0.TS == 1` after `cpu.enableSse()`, causing an immediate `#NM` (Vector 7) fatal panic on the first x87/MMX/SSE instruction.
4. **Dependency on `F-01` SIMD strategy and future Phase 2 scheduler use of `CR0.TS`:**  
   - *Interaction with `F-01` Approach 2 (`FXSAVE64`/`FXRSTOR64` with kernel SSE enabled):* Clearing `CR0.TS` in `enableSse()` is mandatory before any kernel SSE instruction or `fxsave64`/`fxrstor64` in `isr_common` executes.
   - *Interaction with `F-01` Approach 1 (compiler-generated SIMD disabled in kernel code):* Even if compiler-emitted SIMD is disabled in general kernel code, `cpu.enableSse()` is the architectural hardware initialization routine called at boot (`main.zig:18`) to prepare the CPU for FPU/SIMD state management and self-tests, so it must explicitly clear `CR0.TS` to fulfill its contract.
   - *Future Phase 2 scheduler use of `CR0.TS`:* In Phase 2 multitasking, if the scheduler uses **eager** FPU/SIMD context switching, `CR0.TS` must remain `0` continuously; if the scheduler uses **lazy** FPU switching, the context-switch path will deliberately set `CR0.TS = 1` and the Vector 7 (`#NM`) handler will clear `CR0.TS` via `clts` before restoring task FPU state.

*Severity & Priority Rationale (`MEDIUM` / `P1`):* Upgraded from `LOW` / `P2` to **`MEDIUM` / `P1`** because under the pinned **Base Revision 3** contract, `CR0.TS == 0` is not guaranteed by the bootloader specification, and leaving `CR0.TS` un-cleared in `cpu.enableSse()` exposes any SSE or `FXSAVE`/`FXRSTOR` execution to an unhandled `#NM` fault (`Vector 7`) on compliant Base Revision 3 handoff states.

**Reproduction scenario:**  
Under any valid Limine Base Revision 3 handoff state where `CR0.TS == 1` prior to calling `cpu.enableSse()`, `enableSse()` leaves `CR0.TS == 1` (and sets `CR0.MP = 1`), causing the first subsequent SSE or `FXSAVE`/`FXRSTOR` instruction to trap into Vector 7 (`#NM`), where `x86_64_interrupt_dispatch` logs an unhandled exception and halts.

**Impact:**  
Protocol-contract bug under Limine Base Revision 3: `cpu.enableSse()` fails to guarantee `CR0.TS == 0`, risking immediate `#NM` (Vector 7) faults on valid Base Revision 3 handoff states or during `F-01` Approach 2 (`FXSAVE64`/`FXRSTOR64`) execution.

**Recommended correction:**  
1. Factor the pure `CR0` bit-manipulation logic into a host-testable helper (e.g., `pub inline fn computeSseCr0(cr0: u64) u64 { return (cr0 & ~@as(u64, (1 << 2) | (1 << 3))) | (1 << 1); }`) so it can be unit-tested without privileged instructions.
2. In [`cpu.enableSse()`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129), clear both `CR0.EM` (bit 2) and `CR0.TS` (bit 3) while setting `CR0.MP` (bit 1):
```zig
cr0 = computeSseCr0(cr0); // clears CR0.EM (bit 2) and CR0.TS (bit 3), sets CR0.MP (bit 1)
```

**Regression tests:**  
Merely calling `cpu.enableSse()` and asserting `(cpu.readCr0() & ((1 << 2) | (1 << 3))) == 0` is **insufficient**, because if the bootloader/QEMU environment starts with `CR0.TS = 0`, that assertion passes even when `cpu.enableSse()` never clears `CR0.TS`. Both host-side bit-mask verification and privileged in-kernel QEMU runtime verification are required:
1. **Privileged In-Kernel Runtime Verification under QEMU (Ring 0):**  
   Because reading and writing `CR0` (`mov %cr0, ...` / `mov ..., %cr0`) are Ring 0 privileged instructions that cannot execute in an ordinary host user-space test process, run an in-kernel self-test inside QEMU that:
   - **Step 1:** Deliberately sets `CR0.TS = 1` (bit 3) immediately before calling `cpu.enableSse()` (e.g., `cpu.writeCr0(cpu.readCr0() | (1 << 3))`).
   - **Step 2:** Calls `cpu.enableSse()` directly without executing **any** x87/MMX/SSE instructions between setting `CR0.TS = 1` and `cpu.enableSse()` clearing `CR0.TS` (avoiding a premature `#NM` trap prior to `writeCr0`).
   - **Step 3:** Reads back `CR0` via `cpu.readCr0()` and verifies that both `CR0.TS` (bit 3) and `CR0.EM` (bit 2) are `0` (`(cpu.readCr0() & ((1 << 2) | (1 << 3))) == 0`) and `CR0.MP` (bit 1) is `1`.
2. **Host-Side Pure Bit-Mask Unit Test (`zig build test`):**  
   In [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig), test the pure `computeSseCr0(cr0: u64) u64` bit-mask function against synthetic `CR0` inputs with `CR0.TS = 1` (bit 3) and `CR0.EM = 1` (bit 2) set (e.g., `0x8001000C`) and assert that the returned bitmask clears both `CR0.TS` and `CR0.EM`, sets `CR0.MP` (bit 1), and preserves unrelated `CR0` bits (`0x80010002`).

**Dependencies:**  
Directly interacts with `F-01` (SIMD/FPU strategy) and Phase 2 task FPU state management.

---

### [F-16] PMM bitmap placement check (`entry.base != 0`) permits placing the bitmap below 1 MiB (`0x100000`)

**Status:** VERIFIED

**Severity:** LOW

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
[`kernel/src/mm/physical.zig:72-80`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L72-L80) and [`kernel/src/mm/physical.zig:100-103`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L100-L103).

**Evidence:**  
In [`physical.zig:72-80`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L72-L80):
```zig
    // Find a usable region with enough space to hold the allocation bitmap
    var bitmap_phys: ?u64 = null;
    for (0..memmap.entry_count) |i| {
        const entry = memmap.entries[i];
        if (entry.type == .usable and entry.length >= bitmap_size_bytes and entry.base != 0) {
            bitmap_phys = entry.base;
            break;
        }
    }
```
Compare with lines 100–103 in the same function:
```zig
    // Keep the first 1 MiB / page 0 reserved for legacy BIOS/hardware stability
    if (frame * PAGE_SIZE < 0x100000) {
        continue;
    }
```

**Technical explanation:**  
Line 101 of `physical.zig`, [`docs/ARCHITECTURE.md:82`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md#L82), [`ADR-0001:29`](file:///home/leevawn/Projects/zig-os/docs/adr/0001-higher-half-kernel-memory-layout.md#L29), and [`.agents/rules/04-memory-management.md:12`](file:///home/leevawn/Projects/zig-os/.agents/rules/04-memory-management.md#L12) all specify that physical memory below `1 MiB` (`0x0..0x100000`) must remain reserved. However, the bitmap placement loop at line 75 only checks `entry.base != 0` instead of `entry.base >= 0x100000`. Because Limine reserves page `0x0` (`0x0..0x1000`) and reports conventional low RAM starting above `0x0` (below the EBDA at `~0x9F000`) as `.usable`, any `.usable` entry with `0 < entry.base < 0x100000` and `entry.length >= bitmap_size_bytes` is selected by line 75 for `bitmap_phys`. *(Note: The current boot log does not print the memory map entries or `bitmap_phys`, so the exact physical address chosen in QEMU is not asserted without runtime logging; what is statically `VERIFIED` is that `entry.base != 0` permits `< 1 MiB` placement whenever that conventional `.usable` entry is `>= bitmap_size_bytes`.)*

**Reproduction scenario:**  
Given any Limine memory map whose first `.usable` entry has `0 < entry.base < 0x100000` and `entry.length >= bitmap_size_bytes`, `pmm.init()` selects `bitmap_phys = entry.base` (`< 0x100000`).

**Impact:**  
Violates the project's `< 1 MiB` reservation policy (which protects low memory for legacy BIOS data and future SMP AP real-mode startup trampolines), although it does not corrupt non-usable memory in Phase 1 because `entry.type == .usable` and the bitmap frames are marked used at lines 111–117.

**Recommended correction:**  
Require `bitmap_phys >= 0x100000` when scanning `.usable` entries in `pmm.init()` (clamping candidate region starts below `0x100000` up to `0x100000` and checking if the remaining length is `>= bitmap_size_bytes`).

**Regression tests:**  
1. Assert `pmm.virtToPhys(@intFromPtr(pmm.bitmap)) >= 0x100000` in `pmm.testPmm()` and log `bitmap_phys` during PMM initialization.

**Dependencies:**  
Related to `F-07` and `F-08`.

---

### [F-17] PMM page counters (`usable_pages`, `used_pages`, `free_pages`) have undocumented, differing semantics

**Status:** VERIFIED

**Severity:** INFORMATIONAL

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
[`kernel/src/mm/physical.zig:13-16`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L13-L16) and [`kernel/src/mm/physical.zig:91-128`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L91-L128).

**Evidence:**  
A repository-wide search (`grep -rn -E "(usable_pages|free_pages|used_pages|total_pages)" kernel/ tests/`) confirms all references to `usable_pages`, `used_pages`, and `free_pages` occur solely in [`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig):
- `usable_pages` is zeroed at line 91, incremented at line 105 for each `.usable` frame `>= 0x100000` before the bitmap frames are marked used (lines 111–117), and **never read anywhere**.
- `used_pages` and `free_pages` are recounted over `0..total_pages` at lines 120–128 (so `used_pages` includes all non-usable/reserved/MMIO frames plus the bitmap frames, and `used_pages + free_pages == total_pages`), updated on `allocPage()`/`allocPages()`/`freePage()`, and **never read by any caller or test**.
- `total_usable_bytes` (lines 55, 64) is also computed and never read.

**Technical explanation:**  
Because no kernel subsystem or test reads `usable_pages`, `used_pages`, or `free_pages`, the fact that `usable_pages` counts gross `.usable` frames `>= 1 MiB` while `free_pages` counts net available frames after reserving the PMM bitmap (and `used_pages` counts `total_pages - free_pages`, including MMIO holes) is **not a functional defect**. However, their intended meanings should be explicitly documented in comments before a future `meminfo` utility (Phase 5) or OOM diagnostic reads them and mistakes `used_pages` (which includes MMIO holes) for allocated RAM pages.

**Reproduction scenario:**  
At the end of `pmm.init()`, `used_pages + free_pages == total_pages` (which includes non-RAM holes up to `highest_address`), whereas `usable_pages` counts only `.usable` RAM frames `>= 0x100000` prior to subtracting the bitmap footprint.

**Impact:**  
No functional impact in Phase 1; potential reporting confusion in future memory-statistics utilities if counter semantics are not defined.

**Recommended correction:**  
Document the exact invariant for each counter in `physical.zig` (e.g., `total_pages`: bitmap span in frames; `usable_pages`: gross `.usable` RAM frames `>= 1 MiB`; `free_pages`: currently allocatable `.usable` frames; `used_pages`: `usable_pages - free_pages` or `total_pages - free_pages`), and remove the unused `total_usable_bytes` local variable.

**Regression tests:**  
1. Unit test asserting the documented counter invariant after `pmm.init()`, `allocPage()`, and `freePage()`.

**Dependencies:**  
Related to `F-07` and `F-16`.

---

### [F-18] Linker script (`kernel/linker.ld`) omits `.got` section placement, creating an orphan `.got` after `.bss` that pads the `data` segment file size

**Status:** VERIFIED

**Severity:** LOW

**Confidence:** HIGH

**Affected component:**  
Kernel linker script ([`kernel/linker.ld`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld)) and ELF binary (`build/iso_root/boot/kernel.elf`).

**Source location:**  
[`kernel/linker.ld:32-45`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld#L32-L45).

**Evidence:**  
`readelf -S -l build/iso_root/boot/kernel.elf` shows:
```text
Section Headers:
  [Nr] Name              Type             Address           Offset
       Size              EntSize          Flags  Link  Info  Align
  [ 3] .data             PROGBITS         ffffffff8004e000  0004f000
       0000000000000120  0000000000000000  WA       0     0     8
  [ 4] .bss              NOBITS           ffffffff8004e140  0004f120
       0000000000002100  0000000000000000  WA       0     0     64
  [ 5] .got              PROGBITS         ffffffff80050240  00051240
       0000000000000000  0000000000000000  WA       0     0     8

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  LOAD           0x000000000004f000 0xffffffff8004e000 0xffffffff8004e000
                 0x0000000000002240 0x0000000000002240  RW     0x1000
```

**Technical explanation:**  
1. **Verified Phase 1 ELF layout issue:** Because [`kernel/linker.ld`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld) does not assign `.got` / `.got.plt` to an output section, LLD creates an orphan `PROGBITS` section `[ 5] .got` and places it **after** `[ 4] .bss` (`NOBITS`, size `0x2100`) inside the `data` `PT_LOAD` segment. Because a `PROGBITS` section is placed at a higher virtual address than `.bss` in the same segment, LLD is forced to materialize `0x2100` bytes (`8,448` bytes) of `.bss` zeros into the ELF file image (`FileSiz = 0x2240 == MemSiz`, instead of `FileSiz = 0x120`).
2. **Distinction from future VMM requirements:** Note that the current Phase 1 VMM ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)) operates on the active `CR3` page tables constructed by Limine from the ELF `PT_LOAD` headers and therefore does **not** currently require linker-exported section boundary symbols (`__text_start`, `__bss_end`, etc.). Linker boundary symbols will only be needed in a future phase if the kernel constructs a fresh `PML4` from scratch rather than cloning kernel higher-half `PML4` entries (`256..511`).

**Reproduction scenario:**  
Inspect `readelf -S -l build/iso_root/boot/kernel.elf`; observe `[ 5] .got` placed after `[ 4] .bss` and `FileSiz == MemSiz == 0x2240` on `LOAD` segment `02`.

**Impact:**  
Unnecessary file-size padding across `.bss` in `kernel.elf` and unplaced orphan `.got` section.

**Recommended correction:**  
Place `*(.got .got.*)` inside `.data` (before `.bss`) in [`kernel/linker.ld`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld#L32-L40) so `.bss` remains the final `NOBITS` section in the `data` `PT_LOAD` segment.

**Regression tests:**  
1. Run `readelf -S -l zig-out/bin/kernel.elf` and verify no `PROGBITS` section follows `.bss` and `FileSiz < MemSiz` on the `data` `PT_LOAD` segment.

**Dependencies:**  
None.

---

### [F-19] Limine Base Revision 3 ACPI HHDM mapping limitation for Phase 2 integration

**Status:** LIKELY

**Severity:** LOW

**Confidence:** HIGH

**Affected component:**  
Limine protocol configuration ([`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig)) and architecture documentation ([`docs/ARCHITECTURE.md`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md)).

**Source location:**  
- [`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12)
- [`kernel/src/mm/physical.zig:21-23`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L21-L23)
- [`docs/ARCHITECTURE.md:72`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md#L72)

**Evidence:**  
[`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12) sets `base_revision` to `3`. Meanwhile, [`docs/ARCHITECTURE.md:72`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md#L72) describes the HHDM as a `(Direct 1:1 virtual mapping of all physical RAM)` and [`physical.zig:21`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L21) translates physical addresses via `paddr + hhdm_offset`.

**Technical explanation:**  
Under the official Limine protocol specification for **Base Revision 3**, Limine guarantees HHDM mappings only for `.usable`, `.bootloader_reclaimable`, `.executable_and_modules`, and `.framebuffer` memory map regions; it does **not** guarantee that `.acpi_reclaimable` or `.acpi_nvs` regions are mapped into the HHDM. This is **not** a Phase 1 defect because Phase 1 does not parse ACPI tables. However, when Phase 2 introduces APIC/IOAPIC/HPET discovery via ACPI (RSDP/XSDT/MADT), calling `physToVirt()` on an `.acpi_reclaimable` physical address under Base Revision 3 is `LIKELY` to fault with `#PF` (`non-present page`) unless explicitly handled.

**Reproduction scenario:**  
Dereferencing `physToVirt(rsdp_or_madt_phys)` in Phase 2 when the RSDP/MADT resides in an unmapped `.acpi_reclaimable` frame under Base Revision 3.

**Impact:**  
Page fault during future Phase 2 ACPI table parsing if `physToVirt()` is used without mapping ACPI regions.

**Recommended correction:**  
Before implementing Phase 2 ACPI table parsing, choose and document one of two approaches:
1. **Option A (Remain on Base Revision 3):** During early VMM initialization (or on demand in the ACPI subsystem), iterate the Limine memory map and explicitly map `.acpi_reclaimable` and `.acpi_nvs` regions (plus any RSDP frame) into the HHDM via `vmm.mapPage()`.
2. **Option B (Upgrade to Base Revision 4 or later):** With Project Owner ADR approval and verification against the pinned Limine `12.9.6` bootloader binaries, update `base_revision[2]` to `4`, under which Limine maps ACPI regions into the HHDM automatically.

**Regression tests:**  
1. When ACPI support is added, verify `vmm.isMapped(pml4, @intFromPtr(pmm.physToVirt(acpi_entry.base)))` for all `.acpi_reclaimable` entries before dereferencing ACPI tables.

**Dependencies:**  
Phase 2 prerequisite; requires Project Owner decision if Option B (ADR update) is chosen.

---

### [F-20] Explicit Limine `PagingModeRequest` (`4LVL`) defense-in-depth policy

**Status:** VERIFIED

**Severity:** INFORMATIONAL

**Confidence:** HIGH

**Affected component:**  
Limine protocol bindings ([`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig)) and VMM ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)).

**Source location:**  
[`kernel/src/limine.zig:1-141`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L1-L141) and [`kernel/src/mm/virtual.zig:31-55`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L31-L55).

**Evidence:**  
[`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig) does not include a `PagingModeRequest` tag, and [`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig) implements 4-level paging (`PML4 -> PDPT -> PD -> PT`).

**Technical explanation:**  
Per the official Limine Boot Protocol specification, when a kernel does not supply a `LIMINE_PAGING_MODE_REQUEST` tag on `x86_64`, Limine **defaults to 4-level paging** (`PAGING_MODE_X86_64_4LVL`). Therefore, the absence of a `PagingModeRequest` tag in `kernel/src/limine.zig` is **not** an active paging-mode bug in Phase 1; the bootloader protocol guarantee and the VMM's 4-level implementation are consistent. Adding an explicit `PagingModeRequest` (`mode = 0, max_mode = 0, min_mode = 0`) and asserting `(cpu.readCr4() & (1 << 12)) == 0` (`CR4.LA57 == 0`) is an optional defense-in-depth measure to make the 4-level paging contract self-documenting and explicitly verified at runtime.

**Reproduction scenario:**  
Not a defect under Limine default handoff rules.

**Impact:**  
Informational / defense-in-depth hardening only.

**Recommended correction:**  
Optionally add a `PagingModeRequest` pinning 4-level paging (`mode = 0`) in [`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig) and assert `(cpu.readCr4() & (1 << 12)) == 0` during boot.

**Regression tests:**  
1. Assert `(cpu.readCr4() & (1 << 12)) == 0` in `vmm.testVmm()`.

**Dependencies:**  
None.

---

## 5. Rejected Findings Register (`R-01`–`R-09`)

The following claims from prior audit reports and earlier revisions were independently evaluated against snapshot `c10c05f1f37aacfda5046480a314f29d940b67ef` and the official x86-64 architecture manuals and are **REJECTED**:

| Rejected ID | Previously Claimed Defect | Status | Contradicting Source, Binary, & Architectural Evidence in `c10c05f1f37aacfda5046480a314f29d940b67ef` |
|---|---|---|---|
| **R-01** | Missing `cld` instruction in `isr_common` before calling Zig interrupt dispatcher | **REJECTED** | [`kernel/src/arch/x86_64/interrupts/stubs.s:1551`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s#L1551) explicitly contains `cld` immediately before `call x86_64_interrupt_dispatch`. Verified in `build/iso_root/boot/kernel.elf` via `objdump -d` at `0xffffffff80000a59: fc cld`. |
| **R-02** | Missing `CR4.OSXMMEXCPT` (bit 10) configuration in `cpu.enableSse()` | **REJECTED** | [`kernel/src/arch/x86_64/cpu.zig:124-128`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L124-L128) explicitly sets both `CR4.OSFXSR` (`cr4 \|= (1 << 9)`) and `CR4.OSXMMEXCPT` (`cr4 \|= (1 << 10)`). Verified in `build/iso_root/boot/kernel.elf` at `0xffffffff80017df2` (`or rax, 0x200`) and `0xffffffff80017e00` (`or rax, 0x400`). |
| **R-03** | Single combined `RWE` `PT_LOAD` segment in `linker.ld` / `kernel.elf` violating $W \oplus X$ | **REJECTED** | [`kernel/linker.ld:8-13`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld#L8-L13) defines three separate `PHDRS` (`text`, `rodata`, `data`) with `ALIGN(4096)` between sections. `readelf -l build/iso_root/boot/kernel.elf` confirms three separate 4 KiB-aligned `LOAD` segments: Segment `00` (`.text`, `R E`), Segment `01` (`.rodata`, `R`), and Segment `02` (`.data .bss`, `RW`). |
| **R-04** | `GdtPtr.load()` passes stack local by value without memory clobber | **REJECTED** | [`kernel/src/arch/x86_64/gdt/gdt.zig:1-38`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/gdt/gdt.zig#L1-L38) does not contain `GdtPtr` or `load()` at all. Phase 1 retains Limine's GDT and only provides `getCs()`, `getDs()`, and `getSs()`. |
| **R-05** | Missing page-alignment check (`paddr % PAGE_SIZE != 0`) in `pmm.freePage()` | **REJECTED** | [`kernel/src/mm/physical.zig:198-200`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L198-L200) explicitly validates alignment at the top of `freePage()`: `if (paddr % PAGE_SIZE != 0) { @panic("PMM: Attempted to free unaligned physical address"); }` (and `freePages()` checks it at line 224). |
| **R-06** | Partial heap expansion in `expandHeap()` leaks physical frames and virtual mappings | **REJECTED** | [`kernel/src/mm/heap.zig:54-94`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L54-L94) frees `phys` if `vmm.mapPage()` fails (`line 56`), and for every page that succeeds, initializes `new_block` as `FREE`, appends it to `head_block`, and coalesces it with `curr` before the next loop iteration. No physical frames or virtual pages are leaked (the actual defect is false OOM return, documented in `F-11`). |
| **R-07** | 40-byte `BlockHeader` causes `heap.allocate()` to return misaligned pointers | **REJECTED** | [`kernel/src/mm/heap.zig:109-111, 140`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L109-L111) computes `aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1)` and returns `@ptrFromInt(aligned_payload)`. For power-of-two alignments, returned pointers are properly aligned; the 40-byte header only adds 8 bytes of alignment padding (`align_offset = 8`, which causes a documentation discrepancy with [`ADR-0004:13`](file:///home/leevawn/Projects/zig-os/docs/adr/0004-segregated-heap-allocator-canaries.md#L13)'s "32-byte header" claim and contributes to `F-06`/`F-11`). |
| **R-08** | Same-CPL long-mode interrupt frames do not contain hardware-saved `RSP`/`SS` (formerly `F-05`) | **REJECTED** | Per Intel SDM Vol. 3A §6.14.2 and AMD64 APM Vol. 2 §8.9.3, in 64-bit long mode the processor unconditionally pushes `SS` (`+32`) and `RSP` (`+24`) onto the interrupt stack frame even for same-privilege (`CPL 0 -> CPL 0`) interrupts with `IST = 0`, and `IRETQ` unconditionally restores `SS:RSP`. Thus `frame.rsp` and `frame.ss` in [`handlers.zig:32-33`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L32-L33) and [`logException()`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L147-L151) are always present on valid long-mode interrupt paths. |
| **R-09** | Current valid ISR paths lack dynamic stack alignment (formerly `F-02`) | **REJECTED** | Per Intel SDM Vol. 3A §6.14.2, in 64-bit mode the processor aligns `%rsp` to a 16-byte boundary before pushing the hardware frame. On valid paths without a hardware error code (`5` CPU + `2` stub + `15` GPR = `22` qwords = `176` bytes) and on valid hardware error-code exception paths (`6` CPU + `1` stub + `15` GPR = `22` qwords = `176` bytes), `%rsp` before `call x86_64_interrupt_dispatch` is `RSP_aligned - 176`. Since `176 = 11 * 16`, `%rsp % 16 == 0` is already satisfied at the call site without `and rsp, -16`. |

---

## 6. Prioritization & Phase 1 Hardening Plan

> **Governance Gate Notice:** This section defines the proposed engineering sequence for **Phase 1 Hardening**. It does **not** authorize Phase 2 and does **not** mark Phase 1 as Human Approved. Only the Project Owner may approve milestone gates.

### P0 — Must Fix Before Further Kernel Development (1 Active Finding)

**Included Active Finding:** `F-10` (`F-10B` pending; `F-10A` completed at `9df21f8`)  
*(Note: `F-01` was resolved at `515aa91`; `F-10A` extracted the four pure math/layout modules `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` at `9df21f8`; `F-14` was resolved at `7711468` with unconditional fresh builds, `ReleaseSafe` default optimization, non-recursive build steps, and 3-way kernel ELF SHA-256 provenance verification).*

- **Dependencies:** None (foundational testable kernel module architecture).
- **Required Implementation Task:**
  1. **`F-10` (`F-10B` — Stateful Kernel Core Testability):** Building on completed `F-10A`, refactor stateful PMM (`physical.zig`), VMM (`virtual.zig`), and Heap (`heap.zig`) cores with injectable/parameterized backing interfaces so [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig) directly compiles and tests production stateful allocator and paging algorithms on the host.
- **Required Regression Tests:**
  - Verify `zig build test` imports production kernel modules (`F-10A` completed for pure modules) and fails when a stateful PMM/VMM/Heap production invariant is broken (`F-10B` pending).
- **Acceptance Criteria:** Host unit tests bound to both pure (`F-10A`) and stateful (`F-10B`) production kernel code, verified alongside the completed `F-14` fresh-build and ISO provenance pipeline.

---

### P1 — Must Fix Before Phase 2 Authorization (10 Findings)

**Included Findings:** `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-09`, `F-11`, `F-12`, `F-13`, `F-15`

- **Dependencies:** Requires **P0** (`F-01` SIMD strategy, `F-10` testable architecture, and `F-14` rebuild pipeline) to verify fixes. `F-04` requires updating/superseding [`ADR-0003`](file:///home/leevawn/Projects/zig-os/docs/adr/0003-limine-gdt-preservation-phase1.md); `F-15` coordinates with `F-01` and Phase 2 FPU context switching.
- **Required Implementation Tasks:**
  1. **`F-03`, `F-04`, & `F-15` (Interrupt Vector Protection, GDT/TSS/IST, Frame Verification, & `CR0.TS` Initialization):** Prohibit Ring 0 software `INT n` to hardware error-code exception vectors (`8, 10..14, 17, 21, 29, 30`), remap or keep masked the legacy 8259 PIC (`>= 0x20`), assign APIC interrupt vectors outside `0–31`, and preserve `DPL = 0` on exception gates (`F-03`, noting dynamic stack alignment alone does not repair a missing error-code slot); install a kernel-owned GDT and 64-bit TSS (`lgdt`, `ltr`) with a dedicated `IST1` stack for `#DF` (Vector 8) (`F-04`); clear `CR0.TS` (bit 3) alongside `CR0.EM` (bit 2) in [`cpu.enableSse()`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129) so `CR0.TS == 0` is guaranteed under Limine Base Revision 3 (`F-15`).
  2. **`F-06`, `F-11`, & `F-12` (Heap Hardening):** Store `align_offset: u32` in [`BlockHeader`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L15-L23) and enforce `raw_addr == payload_start + block.align_offset` in `deallocate()`; include alignment padding in `pages_needed` and handle partial expansion / free tail blocks in `expandHeap()`; check `heap.init()` return status; validate `std.math.isPowerOfTwo(alignment)` and `size <= HEAP_MAX_SIZE` before arithmetic in `allocate()`.
  3. **`F-07` & `F-08` (PMM Hardening):** Compute `highest_address` across RAM/reclaimable memory map entries only (excluding `.reserved` MMIO apertures); in `freePage()`, validate `paddr >= 0x100000`, non-overlap with `[bitmap_phys_start, bitmap_phys_end)`, and membership in a `.usable` memory map region.
  4. **`F-09` & `F-13` (VMM Hardening):** Check `Flags.HUGE` at `PDPT` and `PD` levels in `mapPage()` and `unmapPage()`; validate 48-bit canonical `virt` and 4 KiB page alignment of `virt` and `phys`; propagate `Flags.USER` to already-present parent `PML4E`, `PDPTE`, and `PDE` entries.
- **Required Regression Tests:**
  - **`F-15` (Dual-Layer `CR0.TS` Verification):** (a) Privileged in-kernel QEMU runtime test that deliberately sets `CR0.TS = 1` immediately before calling `cpu.enableSse()` (with zero intervening FPU/SSE instructions) and verifies `(cpu.readCr0() & ((1 << 2) | (1 << 3))) == 0` afterward, and (b) host unit test in [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig) verifying the pure `computeSseCr0()` bit-mask helper clears `CR0.TS` and `CR0.EM` on synthetic `CR0` values.
  - Host and in-kernel tests covering interior-pointer free rejection (`F-06`), `allocate(16336, 64)` single-expansion behavior (`F-11`), overflow/alignment rejection (`F-12`), PMM high-MMIO-hole sizing (`F-07`), `freePage(0x0)` / `freePage(bitmap_phys)` rejection (`F-08`), and VMM huge-page conflict, canonicality, and `Flags.USER` propagation (`F-09`, `F-13`).
  - Three-regime QEMU interrupt frame verification (`F-04`): (a) same-CPL (`IST = 0`) exceptions verifying saved `frame.rsp` and `frame.ss`, (b) `IST1` stack-switched `#DF` verifying `IST1` stack pointer and interrupted `frame.rsp`/`frame.ss`, and (c) `CPL 3 -> CPL 0` privilege transition frame verification once Ring 3 exists.
- **Acceptance Criteria:** All CPU `CR0`/`CR4`, PMM, VMM, Heap, GDT/TSS, and IDT invariants pass host unit tests and fresh-build QEMU runtime verification in both `Debug` and `ReleaseSafe` modes.

---

### P2 — Important Hardening That Can Follow (2 Findings)

**Included Findings:** `F-16`, `F-19`

- **Dependencies:** `F-16` coordinates with `F-07`/`F-08`; `F-19` requires Project Owner selection between Base Revision 3 explicit ACPI mapping vs. Base Revision 4 ADR update.
- **Required Implementation Tasks:**
  1. **`F-16`:** Enforce `bitmap_phys >= 0x100000` (`1 MiB`) in [`pmm.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L72-L80) and log the selected `bitmap_phys` address.
  2. **`F-19`:** Before Phase 2 ACPI table access, either map `.acpi_reclaimable` / `.acpi_nvs` regions into the HHDM via `vmm.mapPage()` or advance Limine Base Revision to `4` via an approved ADR.
- **Required Regression Tests:**
  - Assert `bitmap_phys >= 0x100000` and HHDM reachability of `.acpi_reclaimable` frames before ACPI parsing.
- **Acceptance Criteria:** `< 1 MiB` strictly preserved for SMP trampolines and ACPI memory safely mapped prior to Phase 2 MADT discovery.

---

### P3 — Future Improvements (3 Findings & Architectural Maintenance)

**Included Findings:** `F-17`, `F-18`, `F-20`

- **Dependencies:** None.
- **Required Implementation Tasks:**
  1. **`F-17`:** Document exact semantics for `pmm.total_pages`, `usable_pages`, `used_pages`, and `free_pages` and remove unused `total_usable_bytes`.
  2. **`F-18`:** Add `*(.got .got.*)` to `.data` before `.bss` in [`kernel/linker.ld`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld) (and export section boundary symbols when kernel-constructed page tables are introduced).
  3. **`F-20`:** Optionally add an explicit `PagingModeRequest` (`4LVL`) to [`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig) and assert `(cpu.readCr4() & (1 << 12)) == 0`.
  4. **Intermediate Page Table Reclamation & Documentation Sync:** Reclaim empty `PT`/`PD`/`PDPT` tables during Phase 2 process teardown, and update [`ADR-0004`](file:///home/leevawn/Projects/zig-os/docs/adr/0004-segregated-heap-allocator-canaries.md) / [`docs/ARCHITECTURE.md`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md) to reflect the 40-byte `BlockHeader`.
- **Required Regression Tests:**
  - `readelf -S -l zig-out/bin/kernel.elf` confirms no orphan `.got` after `.bss` and `FileSiz < MemSiz` on the `data` segment.
- **Acceptance Criteria:** Clean ELF segment layout, documented PMM counter invariants, and synchronized architecture documentation.
