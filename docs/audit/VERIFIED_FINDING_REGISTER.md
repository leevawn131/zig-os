# ZIG-OS — Verified Finding Register & Phase 1 Hardening Plan

> **Document Authority:** Principal Kernel Auditor & Documentation Architect (Gemini 4 Argon)  
> **Original Audit Baseline:** `c10c05f1f37aacfda5046480a314f29d940b67ef` (`main`)  
> **Current Implementation Snapshot:** `b3cf68bbfc659be339b24cf8b3110be7eb159b53` (`main`)
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
| **v1.7** | 2026-11-13 | Gemini 4 Argon | Consolidated audit of `F-10B` Parts 1–3 (`bc2efdb0e673a6086f59e5ad0ca1669216f8c604`, `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`, `b3cf68bbfc659be339b24cf8b3110be7eb159b53`) and VMM hardening at HEAD `b3cf68bbfc659be339b24cf8b3110be7eb159b53`: (1) independently audited `physical_core.zig`, `physical.zig`, `virtual_core.zig`, `virtual.zig`, `heap_core.zig`, `heap.zig`, `heap_layout.zig`, `tests/pmm_test.zig`, `tests/vmm_test.zig`, `tests/heap_test.zig`, `tests/unit_test.zig`, and `build.zig`, verifying that all four host test targets (`unit_test` [7], `pmm_test` [10], `vmm_test` [10], `heap_test` [14] = 41 tests) import actual production modules with zero test-side algorithm duplication; (2) marked `F-10` as `FIXED` (`F-10A` + `F-10B` complete); (3) independently audited VMM hardening in `0156e91` and marked `F-09` (1 GiB `PDPTE` and 2 MiB `PDE` `Flags.HUGE` conflict rejection prior to child-table resolution or mutation) and `F-13` (48-bit canonical address validation, 4 KiB virtual/physical alignment checks, and parent `Flags.USER` propagation) as `FIXED`, while explicitly distinguishing Ring 0 QEMU runtime coverage (`vmm.testVmm()`) from host fake-backend coverage (`FakeVmmBackend` for huge-page conflicts and `Flags.USER` parent promotion); (4) verified that `F-06`, `F-11`, and `F-12` in `heap_core.zig` and `F-07`, `F-08`, `F-16`, and `F-17` in `physical_core.zig` remain `VERIFIED` (`OPEN`); and (5) reconciled all status (`12 VERIFIED`, `1 LIKELY`, `5 FIXED`, `9 REJECTED`; `13` active findings), severity (`0 CRITICAL`, `3 HIGH`, `5 MEDIUM`, `3 LOW`, `2 INFORMATIONAL`), and priority (`P0: 0`, `P1: 8`, `P2: 2`, `P3: 3`) tables. |

---

## 1. Audited Snapshot & Workspace Identification

### 1.1 Git Snapshot Identity

| Attribute | Original Audit Baseline (`v1.0`–`v1.3.1`) | Current Implementation Snapshot (`v1.7`) | Match Status |
|---|---|---|---|
| **Repository** | `leevawn131/zig-os` | `leevawn131/zig-os` | **MATCH** |
| **Branch** | `main` (`origin/main` first-parent ancestor; `origin/dev` ref also points to `c10c05f1`) | `main` (`origin/main`) | **MATCH** |
| **HEAD Commit SHA** | `c10c05f1f37aacfda5046480a314f29d940b67ef` | `b3cf68bbfc659be339b24cf8b3110be7eb159b53` | **EXACT MATCH** |
| **Commit Subject** | `feat(kernel): implement Phase 1 core kernel infrastructure` | `test(mm): extract host-testable stateful heap core (F-10B Part 3)` | **EXACT MATCH** |
| **Commit Timestamp** | `2026-11-10T14:10:11+07:00` | `2026-11-13T07:38:37+07:00` | **EXACT MATCH** |
| **Intervening Source Commits** | — | `515aa91becaf772f3f5b9243f92c1c0828f5d0bc` (`F-01` fix), `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (`F-10A` pure modules), `771146810e41854f2b9e754f2a048f142ab633a8` (`F-14` fix), `bc2efdb0e673a6086f59e5ad0ca1669216f8c604` (`F-10B` Part 1 PMM), `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6` (`F-10B` Part 2 VMM + `F-09`/`F-13`), `b3cf68bbfc659be339b24cf8b3110be7eb159b53` (`F-10B` Part 3 Heap) | **VERIFIED** |

### 1.2 Working Tree & Build Artifact Status (`git status --short`)

At current snapshot `b3cf68bbfc659be339b24cf8b3110be7eb159b53`:
```text
 M zig.zip
?? docs/md.zip
?? graphify-out/
```

- **Kernel, Linker, Build, and Test Source Integrity (`b3cf68b`):** Zero tracked source files under [`kernel/`](file:///home/leevawn/Projects/zig-os/kernel), [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`scripts/`](file:///home/leevawn/Projects/zig-os/scripts), or [`tests/`](file:///home/leevawn/Projects/zig-os/tests) have uncommitted modifications. All tracked code, build definitions, scripts, and tests match commit `b3cf68bbfc659be339b24cf8b3110be7eb159b53` byte-for-byte.
- **Untouched Working-Tree Artifacts:** `zig.zip`, `docs/md.zip`, and `graphify-out/` remain untouched in the local workspace per governance safety rules (causing `git status --porcelain` in `scripts/lib/common.sh` to report `tree=dirty` during local builds).
- **On-Disk Build Artifacts at `b3cf68b` (Independently Inspected via `sha256sum`; `Debug` Kernel ELF/ISO from Final `zig build -Doptimize=Debug test-boot` Run):**
  ```text
  beb50ec40adbf0f5376b5c9777736eb16027a0dfb4ef38d5e32ca5e9a9d86471  zig-out/bin/kernel.elf
  beb50ec40adbf0f5376b5c9777736eb16027a0dfb4ef38d5e32ca5e9a9d86471  build/iso_root/boot/kernel.elf
  af681f65bbc6eccd68e9bacefa9b6d59f927728e937c58bc9c4b70c8e965260d  build/zig-os.iso
  ```
- **Agent-Reported Kernel ELF Artifacts at `b3cf68b` Across Optimization Modes (`F-10B` Part 3):**
  ```text
  beb50ec40adbf0f5376b5c9777736eb16027a0dfb4ef38d5e32ca5e9a9d86471  zig-out/bin/kernel.elf (Debug)
  169982e35631ee32f94faf9df45ac68065efc7611c3bf8222a146b73933bb532  zig-out/bin/kernel.elf (ReleaseSafe)
  93ae4d560ba09feac47ff5163a457151512fecc3f2f2e02144022797b6cb79ca  zig-out/bin/kernel.elf (ReleaseFast)
  fe45f8395266259aa1209d641e8565f18817288901e898f4c740f54de7d6f5d2  zig-out/bin/kernel.elf (ReleaseSmall)
  ```
- **On-Disk Build Artifacts Inspected at `7711468` (`v1.6`, `ReleaseSafe` Default Build):**
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
| **Static Source Inspection (`c10c05f` through `b3cf68b`)** | **YES (Independently Audited)** | Direct line-by-line review of all files in `kernel/`, `build.zig`, `scripts/`, `tests/`, `docs/`, and `/opt/zig/current/lib/std/Target/x86.zig` | Completed across 100% of kernel and build sources at baseline `c10c05f1`, re-verified at `9df21f8b` (`F-10A` shared pure modules `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, `heap_layout.zig`), audited at `77114681` across all 10 `F-14` build/script/test files, and independently audited at `b3cf68bbfc659be339b24cf8b3110be7eb159b53` across commits `bc2efdb0` (`F-10B` Part 1 PMM: `physical_core.zig`, `physical.zig`, `tests/pmm_test.zig`), `0156e910` (`F-10B` Part 2 VMM + `F-09`/`F-13`: `virtual_core.zig`, `virtual.zig`, `tests/vmm_test.zig`), and `b3cf68bb` (`F-10B` Part 3 Heap: `heap_core.zig`, `heap.zig`, `tests/heap_test.zig`, `build.zig`). |
| **ELF & ISO Binary Inspection (`c10c05f`, `515aa91`, `7711468`, & `b3cf68b`)** | **YES (Baseline & On-Disk Hashes Audited / `F-01` Disassembly Agent-Reported)** | `sha256sum`, `xorriso -extract`, `readelf -h -l -S -d`, `nm -n`, `objdump -d -M intel`, `df -T` | At `c10c05f`, confirmed `/boot/kernel.elf` inside `build/zig-os.iso` matched `zig-out/bin/kernel.elf` (`19e69d10...`), 3 `PT_LOAD` segments (`R E`, `R`, `RW`), orphan `.got` section, Limine request ordering, and 6,904 `xmm` / 2,274 `movaps` instructions. At `515aa91` (`F-01`) and `b3cf68b` (`F-10B` Part 3), implementation agents reported `0` prohibited SIMD/x87 instructions in `kernel.elf`. At `b3cf68b`, auditor verified on-disk `zig-out/bin/kernel.elf` and `build/iso_root/boot/kernel.elf` SHA-256 (`beb50ec40adbf0f5376b5c9777736eb16027a0dfb4ef38d5e32ca5e9a9d86471`). |
| **Host Unit Tests (`c10c05f` vs. `b3cf68b`)** | **Baseline Audited / `b3cf68b` Source Audited & Execution Agent-Reported** | `zig build test --summary all` across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall` | At `c10c05f`, `5/5` tests passed against local duplicate functions in `tests/unit_test.zig`. At `b3cf68b`, independent source review confirms `zig build test` wires four host test targets importing production modules with zero duplicate algorithms: `unit_test` (`tests/unit_test.zig`, 7 pure tests), `pmm_test` (`tests/pmm_test.zig` importing `physical_core.zig`, 10 stateful PMM tests), `vmm_test` (`tests/vmm_test.zig` importing `virtual_core.zig`, 10 stateful VMM tests including `F-09` and `F-13`), and `heap_test` (`tests/heap_test.zig` importing `heap_core.zig`, 14 stateful Heap tests). Implementation agent reported `41/41` host tests passing uncached across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`. |
| **Build, Provenance, & QEMU Boot Verification (`c10c05f` vs. `7711468` & `b3cf68b`)** | **Baseline Audited / `7711468` & `b3cf68b` Source Audited & Execution Agent-Reported** | `zig build -Doptimize=<mode>`, `zig build -Doptimize=<mode> iso`, `./scripts/test-boot.sh`, `python3 tests/test_boot.py`, `zig build -Doptimize=Debug test-boot` | At `b3cf68b`, implementation agent reported clean kernel compilation across all 4 optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`), passing `Debug` (`beb50ec4...`) and `ReleaseSafe` (`169982e3...`) ISO builds with 3-way SHA-256 provenance verification, and passing QEMU headless smoke tests (`./scripts/test-boot.sh`, `python3 tests/test_boot.py`, and `zig build -Doptimize=Debug test-boot --summary all`). Note that in-kernel QEMU boot tests (`pmm.testPmm()`, `vmm.testVmm()`, `heap.testHeap()`) exercise Ring 0 4 KiB page mapping/unmapping, canonical/alignment rejection, frame allocation, and heap allocation, whereas 1 GiB/2 MiB huge-page conflict protection (`F-09`) and `Flags.USER` parent-entry promotion (`F-13`) are verified via host-side fake-backend unit tests (`tests/vmm_test.zig`), not Ring 3 QEMU tests. |

---

## 3. Summary of Findings

### 3.1 Count by Verification Status

| Status Category | Count | Finding IDs |
|---|---:|---|
| **VERIFIED** | **12** | `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-11`, `F-12`, `F-15`, `F-16`, `F-17`, `F-18`, `F-20` |
| **LIKELY** | **1** | `F-19` |
| **NEEDS_RUNTIME_VERIFICATION** | **0** | None |
| **REJECTED** | **9** | `R-01`, `R-02`, `R-03`, `R-04`, `R-05`, `R-06`, `R-07`, `R-08` (formerly `F-05`), `R-09` (formerly `F-02`) |
| **FIXED** | **5** | `F-01` (at `515aa91`: `cpu_features_sub`/`cpu_features_add` in `build.zig`), `F-09` (at `0156e91`: 1 GiB/2 MiB `Flags.HUGE` conflict checks in `virtual_core.zig`), `F-10` (across `9df21f8`, `bc2efdb`, `0156e91`, `b3cf68b`: `F-10A` pure modules + `F-10B` stateful PMM, VMM, and Heap cores wired into `zig build test`), `F-13` (at `0156e91`: 48-bit canonicality, 4 KiB alignment, and parent `Flags.USER` propagation in `virtual_core.zig`), `F-14` (at `7711468`: unconditional fresh build, non-recursive graph, `ReleaseSafe` default, and 3-way ELF SHA-256 provenance verification) |

### 3.2 Severity Distribution (Active Findings: 13 Total)

| Severity | Count | Finding IDs |
|---|---:|---|
| **CRITICAL** | **0** | None |
| **HIGH** | **3** | `F-06`, `F-07`, `F-08` |
| **MEDIUM** | **5** | `F-03`, `F-04`, `F-11`, `F-12`, `F-15` |
| **LOW** | **3** | `F-16`, `F-18`, `F-19` |
| **INFORMATIONAL** | **2** | `F-17`, `F-20` |

### 3.3 Priority Distribution (`P0`–`P3`: 13 Active Findings)

| Priority | Count | Finding IDs |
|---|---:|---|
| **P0 — Must fix before further kernel development** | **0** | None (`F-01`, `F-10`, and `F-14` are `FIXED`) |
| **P1 — Must fix before Phase 2 authorization** | **8** | `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-11`, `F-12`, `F-15` (`F-09` and `F-13` are `FIXED`) |
| **P2 — Important hardening that can follow** | **2** | `F-16`, `F-19` |
| **P3 — Future improvements** | **3** | `F-17`, `F-18`, `F-20` |

---

## 4. Finding Register (`F-01`–`F-20`)

> **Source Version Note:** Findings were originally audited at baseline commit `c10c05f1f37aacfda5046480a314f29d940b67ef` (`2026-11-10`) and updated through current implementation snapshot `b3cf68bbfc659be339b24cf8b3110be7eb159b53` (`2026-11-13`, incorporating `515aa91` for `F-01`, `9df21f8` for `F-10A`, `7711468` for `F-14`, `bc2efdb` for `F-10B` Part 1 PMM, `0156e91` for `F-10B` Part 2 VMM + `F-09`/`F-13`, and `b3cf68b` for `F-10B` Part 3 Heap). Historical IDs `F-02` and `F-05` are retained in place with `Status: REJECTED` and cross-referenced to `R-09` and `R-08` in Section 5 to preserve full audit traceability.

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
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)), block header layout ([`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig)), and kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
- [`kernel/src/mm/heap_core.zig:140-178`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L140-L178) and [`kernel/src/mm/heap_core.zig:189-208`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L189-L208)
- [`kernel/src/mm/heap_layout.zig:4-14`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L4-L14)
- [`kernel/src/mm/heap.zig:50-64`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L50-L64)

**Evidence:**  
In [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L143-L175) (extracted verbatim from `heap.zig` in `b3cf68b`):
```zig
const payload_addr = @intFromPtr(block) + HEADER_SIZE;
const aligned_payload = (payload_addr + align_val - 1) & ~(align_val - 1);
const align_offset = aligned_payload - payload_addr;
const total_needed = aligned_size + align_offset;
...
return @ptrFromInt(aligned_payload);
```
In [`HeapAllocator.deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L198-L206):
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

*(Note: `F-10B` Part 3 at `b3cf68bbfc659be339b24cf8b3110be7eb159b53` intentionally extracted the existing `deallocate()` range check into `heap_core.zig` without fixing `F-06`.)*

**Reproduction scenario:**  
```zig
const p = heap.allocate(64, 16).?; // returns 0xffff_9000_0000_0030 (payload_start = 0x...0028, payload_end = 0x...0070)
heap.deallocate(p + 17);           // 0xffff_9000_0000_0041 is inside [0x...0028, 0x...0070) -> silently frees `p`!
```

**Impact:**  
Silently frees active allocations when passed an interior or offset pointer, masking caller pointer-arithmetic bugs and causing use-after-free heap corruption.

**Recommended correction:**  
Store `align_offset: u32` inside [`BlockHeader`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L4-L12) (replacing 4 of the 7 `padding: [7]u8` bytes so `@sizeOf(BlockHeader)` remains 40 bytes), and require `raw_addr == payload_start + block.align_offset` in [`HeapAllocator.deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L189-L208), returning `error.BlockHeaderNotFound` (which panics in `heap.deallocate()`) if `raw_addr` does not match the exact returned payload pointer.

**Regression tests:**  
1. Host unit test in [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig) verifying `deallocate()` succeeds for the exact pointer `p = allocate(128, 64).?` and rejects `p - 8` (alignment padding), `p + 1` (interior pointer), and `p + 128` (tail slack).

**Dependencies:**  
Host test harness provided by completed `F-10` (`F-10B` Part 3).

---

### [F-07] PMM `highest_address` and bitmap size are computed across all memory map entries including reserved and MMIO regions

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)) and kernel adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:143-156`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L143-L156)
- [`kernel/src/mm/physical.zig:44-52, 80-110`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L44-L52)

**Evidence:**  
In [`PhysicalAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L143-L156) (extracted in `bc2efdb`):
```zig
// Preserve full-map scan across all region types to determine total tracked frame count.
var computed_highest: u64 = 0;
for (0..region_count) |i| {
    const region = regions.get(i);
    const region_top = region.base + region.length;
    if (region_top > computed_highest) {
        computed_highest = region_top;
    }
}

const computed_total_pages = physical_math.totalPagesFromBytes(computed_highest);
const computed_bitmap_size = physical_math.bitmapSizeBytes(computed_total_pages);
```

**Technical explanation:**  
`computed_highest` (`highest_address`) is computed across **all** memory map regions regardless of `region.kind` (`.usable` and `.non_usable`, which [`limineRegionGet()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L44-L52) maps from `.reserved`, `.framebuffer`, `.acpi_nvs`, etc.). *(Note: the unused `total_usable_bytes` local variable present at `c10c05f` was removed when `physical_core.zig` was extracted in `bc2efdb`, while the full-map `computed_highest` scan was intentionally preserved for `F-10B` Part 1 behavioral parity.)* Because x86_64 memory maps include `.reserved` firmware ROM / APIC MMIO regions up to `4 GiB` (`0x1_0000_0000`) and, on systems with 64-bit PCIe BARs, `.reserved` apertures at multi-terabyte physical addresses (e.g., `1 TiB`..`64 TiB`), sizing the flat bitmap to `highest_address` wastes RAM across non-RAM MMIO holes and will fail to find a contiguous `.usable` region large enough to hold `bitmap_size_bytes` on systems with high 64-bit MMIO entries, returning `error.NoUsableBitmapRegion` (`physical_core.zig:168`) and panicking at `physical.zig:105`.

**Reproduction scenario:**  
With 256 MiB of `.usable` RAM (`8,192` B bitmap needed) and a standard `4 GiB` `.reserved` top entry, `bitmap_size_bytes` is inflated 16x to `131,072` B (`128 KiB`). With a `.reserved` 64-bit PCIe aperture at `16 TiB` (`0x1000_0000_0000`), `bitmap_size_bytes` becomes `512 MiB` (`> 256 MiB` total RAM), causing `pmm.init()` to panic at `physical.zig:105`.

**Impact:**  
16x bitmap bloat on standard 256 MiB QEMU and immediate boot panic on hardware/VMs with high 64-bit PCIe MMIO apertures.

**Recommended correction:**  
Compute `highest_address` only across RAM-backed memory map types (`.usable`, `.bootloader_reclaimable`, `.acpi_reclaimable`, `.executable_and_modules`), excluding `.reserved`, `.framebuffer`, `.acpi_nvs`, and `.bad_memory` apertures.

**Regression tests:**  
1. Host unit test in [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig) passing a memory map with 256 MiB `.usable` RAM and a `.reserved` entry at `0x4000_0000_0000` (`64 TiB`), asserting `total_pages` and `bitmap.len` reflect the RAM ceiling rather than the 64 TiB MMIO hole.

**Dependencies:**  
Related to `F-08` and `F-16`; host test harness provided by completed `F-10` (`F-10B` Part 1).

---

### [F-08] PMM `freePage()` lacks allocatable-RAM range, reserved-region, and bitmap-overlap validation

**Status:** VERIFIED

**Severity:** HIGH

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)) and kernel adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:186-218`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L186-L218) and [`kernel/src/mm/physical_core.zig:314-336`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L314-L336)
- [`kernel/src/mm/physical.zig:124-136`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L124-L136)

**Evidence:**  
In [`PhysicalAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L186-L218), the 1-bit-per-frame bitmap sets `1` (`isBitSet(frame) == true`) for all non-free frames: allocated `.usable` frames, reserved `< 1 MiB` frames, `.non_usable` (`.reserved` MMIO, `.executable_and_modules` kernel, `.bootloader_reclaimable`) frames, and the PMM bitmap's own physical frames.
In [`PhysicalAllocator.freePage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L314-L336):
```zig
pub fn freePage(self: *Self, paddr: u64) FreeError!void {
    if (paddr % PAGE_SIZE != 0) {
        return error.UnalignedAddress;
    }

    const frame: usize = physical_math.physToFrame(paddr);
    if (frame >= self.total_pages) {
        return error.OutOfBounds;
    }

    if (!self.isBitSet(frame)) {
        return error.DoubleFree;
    }

    self.clearBit(frame);
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
While keeping the existing page-alignment (`paddr % PAGE_SIZE != 0`), bounds (`frame >= total_pages`), and double-free (`!isBitSet(frame)`) checks, add three explicit validations in `PhysicalAllocator.freePage()`:
1. **Protected low-memory check:** Reject `paddr < 0x100000` (`1 MiB`).
2. **Bitmap self-overlap check:** Reject any `paddr` overlapping `[self.bitmap_phys, self.bitmap_phys + self.bitmap.len)`.
3. **Allocatable-RAM membership check:** Verify that `paddr` lies within a `.usable` region of the memory map.

**Regression tests:**  
1. Host unit tests in [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig) verifying `freePage()` rejects `paddr = 0x0`, `paddr = 0x80000` (`< 1 MiB`), `paddr = bitmap_phys`, and `paddr` inside a `.non_usable` region, while still rejecting double-free of a valid `.usable` frame.

**Dependencies:**  
Related to `F-07` and `F-16`; host test harness provided by completed `F-10` (`F-10B` Part 1).

---

### [F-09] VMM `mapPage()` and `unmapPage()` do not check `Flags.HUGE`, corrupting 1 GiB / 2 MiB huge pages if traversed

**Status:** FIXED (Independently Source-Audited at `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`; Host Fake-Backend Unit Test `VMM G & F-09` Agent-Reported Passing; Live QEMU `vmm.testVmm()` Exercises 4 KiB Path Only)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Virtual Memory Manager core ([`kernel/src/mm/virtual_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig)), kernel VMM adapter ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)), and VMM host test suite ([`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig)).

**Source location:**  
- [`kernel/src/mm/virtual_core.zig:45-60`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L45-L60)
- [`kernel/src/mm/virtual_core.zig:145-171`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L145-L171) and [`kernel/src/mm/virtual_core.zig:220-245`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L220-L245)
- [`kernel/src/mm/virtual.zig:19-20, 52-63`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L19-L20)
- [`tests/vmm_test.zig:504-594`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L504-L594)

**Resolution & Independent Audit Evaluation (v1.7, Commit `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`):**
1. **Independently Reviewed Source Evidence:**
   - Both [`MapError`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L45-L53) and [`UnmapError`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L55-L60) define `error.HugePageConflict` (re-exported by [`kernel/src/mm/virtual.zig:19-20`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L19-L20)).
   - In [`virtual_core.mapPage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L145-L171), existing hierarchy entries are inspected read-only prior to any table allocation, entry mutation, or TLB invalidation:
     - At the `PDPT` level (1 GiB huge page), if `(pdpte & Flags.PRESENT) != 0` and `(pdpte & Flags.HUGE) != 0`, `mapPage()` immediately returns `error.HugePageConflict` (`lines 152-154`) **before** calling `backend.resolveTable(pdpte & Flags.PHYS_ADDR_MASK)`.
     - At the `PD` level (2 MiB huge page), if `(pde & Flags.PRESENT) != 0` and `(pde & Flags.HUGE) != 0`, `mapPage()` immediately returns `error.HugePageConflict` (`lines 160-162`) **before** calling `backend.resolveTable(pde & Flags.PHYS_ADDR_MASK)`.
   - In [`virtual_core.unmapPage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L228-L238):
     - At the `PDPT` level (`line 231`), `if ((pdpte & Flags.HUGE) != 0) return error.HugePageConflict;` executes before `backend.resolveTable(pdpte & Flags.PHYS_ADDR_MASK)`.
     - At the `PD` level (`line 237`), `if ((pde & Flags.HUGE) != 0) return error.HugePageConflict;` executes before `backend.resolveTable(pde & Flags.PHYS_ADDR_MASK)`.
   - In [`virtual_core.virtToPhys()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L260-L272), 1 GiB (`HUGE_1GIB_ADDR_MASK` + `HUGE_1GIB_OFFSET_MASK`) and 2 MiB (`HUGE_2MIB_ADDR_MASK` + `HUGE_2MIB_OFFSET_MASK`) huge-page translations are preserved.
2. **Regression Test & Provenance Boundary (Host Fake-Backend vs. QEMU Runtime):**
   - **Independently Audited Host Regression Test ([`tests/vmm_test.zig:504-594`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L504-L594), `"VMM G & F-09"`):** Seeds a 1 GiB huge-page `PDPTE` (`paddr_1g_base = 0x4000_0000`) and a 2 MiB huge-page `PDE` (`paddr_2m_base = 0x8020_0000`) whose backing physical addresses lie strictly outside the `FakeVmmBackend` page-table pool (so any erroneous `resolveTableFn` call on the data frame sets `fake.unexpected_resolve = true`). Verifies `virtToPhys` and `isMapped` with non-zero offsets across both levels, and verifies that `mapPage` and `unmapPage` inside both the 1 GiB and 2 MiB regions return `error.HugePageConflict` with zero table allocations (`alloc_attempts == 0`), zero frees (`free_calls == 0`), zero TLB invalidations (`invlpg_calls == 0`), zero child-table resolutions on the huge-page data frames (`!fake.unexpected_resolve`), and unmodified `PML4E`, `PDPTE`, and `PDE` entries (including no premature `Flags.USER` promotion on parent entries).
   - **Coverage Boundary:** Huge-page conflict protection (`F-09`) is verified via the host fake-backend unit test (`tests/vmm_test.zig`, reported passing across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`); the live Ring 0 QEMU self-test ([`vmm.testVmm()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L73-L172)) exercises 4 KiB page mapping, write, translation, unmap, and canonical/alignment rejection without injecting synthetic 1 GiB/2 MiB huge-page conflicts into the active `CR3` hierarchy.

**Historical Evidence (Baseline `c10c05f1` through `bc2efdb0`):**
Prior to `0156e910`, `virtual.zig` checked `Flags.HUGE` in `virtToPhys()` but omitted `Flags.HUGE` checks in `mapPage()` and `unmapPage()`, treating `pdpt.entries[pdpt_i]` and `pd.entries[pd_i]` unconditionally as child `PageTable` physical addresses.

**Dependencies:**  
Related to `F-10` (`F-10B` Part 2) and `F-13`.

---

### [F-10] Host unit test suite lacks a testable kernel module architecture for pure and stateful PMM, VMM, and Heap cores

**Status:** FIXED (Independently Source-Audited across `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`, `bc2efdb0e673a6086f59e5ad0ca1669216f8c604`, `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`, and `b3cf68bbfc659be339b24cf8b3110be7eb159b53`; `41/41` Host Unit Tests Across All 4 Optimization Modes and `Debug`/`ReleaseSafe` QEMU Smoke Tests Agent-Reported)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Build test graph ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig)), shared pure production modules ([`kernel/src/mm/paging_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig), [`kernel/src/mm/physical_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig), [`kernel/src/arch/x86_64/interrupts/page_fault.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig), [`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig)), shared stateful production cores and kernel adapters ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig), [`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig), [`kernel/src/mm/virtual_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig), [`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig), [`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig), [`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)), and host unit test targets ([`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig), [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig), [`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig), [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)).

**Source location:**  
- [`build.zig:123-210`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L210)
- [`kernel/src/mm/paging_math.zig:1-24`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig#L1-L24), [`kernel/src/mm/physical_math.zig:1-29`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig#L1-L29), [`kernel/src/arch/x86_64/interrupts/page_fault.zig:1-20`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig#L1-L20), [`kernel/src/mm/heap_layout.zig:1-14`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L1-L14)
- [`kernel/src/mm/physical_core.zig:1-365`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L1-L365) and [`kernel/src/mm/physical.zig:1-180`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L1-L180)
- [`kernel/src/mm/virtual_core.zig:1-285`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L1-L285) and [`kernel/src/mm/virtual.zig:1-172`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L1-L172)
- [`kernel/src/mm/heap_core.zig:1-299`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L1-L299) and [`kernel/src/mm/heap.zig:1-175`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L1-L175)
- [`tests/unit_test.zig:1-222`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L1-L222), [`tests/pmm_test.zig:1-573`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L1-L573), [`tests/vmm_test.zig:1-780`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L1-L780), and [`tests/heap_test.zig:1-631`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L1-L631)

**Resolution & Independent Audit Evaluation (v1.7, Snapshot `b3cf68bbfc659be339b24cf8b3110be7eb159b53`):**
1. **Completed `F-10A` — Shared Pure-Module Extraction (`9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`):**
   - Extracted `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` into hardware-independent production modules imported directly by both the freestanding kernel (`virtual_core.zig`, `physical_core.zig`, `handlers.zig`, `heap_core.zig`) and [`tests/unit_test.zig:6-9`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L6-L9) (7 host tests, zero duplicated helper definitions).
2. **Completed `F-10B` Part 1 — Stateful PMM Core (`bc2efdb0e673a6086f59e5ad0ca1669216f8c604`):**
   - [`kernel/src/mm/physical_core.zig:1-365`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L1-L365) implements `PhysicalAllocator` (`init`, `initFromSlice`, `allocPage`, `allocPages`, `freePage`, `freePages`, `isPageAllocated`) parameterized by `RegionProvider`, `BitmapProvider`, and `PageZeroer`, with zero Limine or HHDM dependencies.
   - [`kernel/src/mm/physical.zig:1-180`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L1-L180) binds `PhysicalAllocator` to `limine.hhdm_request`, `limine.memmap_request`, `physToVirt`, and the existing kernel `@panic` contracts while synchronizing all public PMM globals via `syncGlobals()`.
   - [`tests/pmm_test.zig:1-573`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L1-L573) imports `@import("physical_core")` (`build.zig:155-169`) and runs 10 stateful host tests against `physical_core.PhysicalAllocator` using `FakeMemoryBackend` (covering `< 1 MiB`, non-usable, and multi-page bitmap reservation, init failure state preservation, single/contiguous allocation and zeroing, unaligned/out-of-bounds/double-free rejection, OOM recovery, partial final bitmap byte/word boundaries, scan-cursor backward update/wraparound, and deterministic PRNG stress).
3. **Completed `F-10B` Part 2 — Stateful VMM Core (`0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`):**
   - [`kernel/src/mm/virtual_core.zig:1-285`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L1-L285) implements `mapPage`, `unmapPage`, `virtToPhys`, `isMapped`, `isCanonical`, `PageTable`, `Flags`, `MapError`, and `UnmapError` over an injected `Backend` (`resolveTableFn`, `allocTableFn`, `freeTableFn`, `invlpgFn`), with zero privileged `CR3` or `invlpg` instructions in the core.
   - [`kernel/src/mm/virtual.zig:1-172`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L1-L172) binds `virtual_core` to `cpu.readCr3()`, `pmm.physToVirt()`, `pmm.allocPage()`, `pmm.freePage()`, and `cpu.invlpg()`.
   - [`tests/vmm_test.zig:1-780`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L1-L780) imports `@import("virtual_core")` (`build.zig:172-186`) and runs 10 stateful host tests (`VMM A`–`VMM J`, including `F-09` and `F-13` regressions) against `virtual_core` using `FakeVmmBackend` (with `0xA5A5...` poisoned page-table slots).
4. **Completed `F-10B` Part 3 — Stateful Heap Core (`b3cf68bbfc659be339b24cf8b3110be7eb159b53`):**
   - [`kernel/src/mm/heap_core.zig:1-299`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L1-L299) imports `BlockHeader` and `HEADER_SIZE` from `heap_layout.zig` and implements `HeapAllocator` (`create`, `mappedBytes`, `init`, `expandHeap`, `allocate`, `deallocate`, `allocator`, `allocator_vtable`), `PageMapper`, and `FreeError` over configurable `heap_start` and `heap_max_size`.
   - [`kernel/src/mm/heap.zig:1-175`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L1-L175) binds `HeapAllocator` (`HEAP_START`, `HEAP_MAX_SIZE`) to `vmm.getActivePml4()`, `pmm.allocPage()`, `vmm.mapPage(..., vmm.Flags.WRITABLE)`, and `pmm.freePage()`, preserving all public globals (`current_heap_end`, `head_block`, `initialized`, `total_allocated_bytes`, `total_freed_bytes`), `init`, `allocate`, `deallocate`, `vtable`, `allocator`, `testHeap`, and `@panic` strings.
   - [`tests/heap_test.zig:1-631`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L1-L631) imports `@import("heap_core")` (`build.zig:189-203`) and runs 14 stateful host tests (`Heap 01`–`Heap 14`) against `heap_core.HeapAllocator` over page-aligned host buffers (`FakeHeapBackend`).
5. **Unified `zig build test` Target Architecture (`build.zig:123-210`):**
   - `unit_test_step` (`b.step("test", "Run host unit tests")`) depends on all four test artifacts (`run_unit_tests` [7 tests in `tests/unit_test.zig`], `run_pmm_tests` [10 tests in `tests/pmm_test.zig`], `run_vmm_tests` [10 tests in `tests/vmm_test.zig`], and `run_heap_tests` [14 tests in `tests/heap_test.zig`]) for an aggregate of **41 host unit tests** (note that stateful tests reside in dedicated `pmm_test.zig`, `vmm_test.zig`, and `heap_test.zig` targets wired into `zig build test` rather than inside `tests/unit_test.zig`).
   - **Provenance Boundary:** Source architecture across all 12 files was independently audited by Argon at `b3cf68bbfc659be339b24cf8b3110be7eb159b53`; uncached execution of `41/41` host tests across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`, 4-mode kernel compilation, and `Debug`/`ReleaseSafe` QEMU smoke tests are implementation-agent-reported.

**Historical Evidence (Baseline `c10c05f1`):**
At baseline `c10c05f1`, `tests/unit_test.zig` duplicated 5 pure helpers/structs locally with zero `@import` edges into `kernel/src/`, and stateful PMM, VMM, and Heap algorithms were coupled directly to Limine globals, HHDM pointers, `HEAP_START`, and privileged CPU instructions (`CR3`, `invlpg`).

**Dependencies:**  
Provides the host unit test foundation for memory-management findings `F-06`–`F-09`, `F-11`–`F-13`, `F-16`, and `F-17`.

---

### [F-11] Heap `allocate()` omits alignment padding in `pages_needed` and ignores partial expansion progress in `expandHeap()`

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)) and kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
- [`kernel/src/mm/heap_core.zig:80-131`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L80-L131) and [`kernel/src/mm/heap_core.zig:180-187`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L180-L187)
- [`kernel/src/mm/heap.zig:45-54`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L45-L54)

**Evidence:**  
In [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L180-L187) (extracted in `b3cf68b`):
```zig
const page_size_usize: usize = @intCast(PAGE_SIZE);
const pages_needed = (aligned_size + HEADER_SIZE + page_size_usize - 1) / page_size_usize;
if (self.expandHeap(@max(pages_needed, 4))) {
    return self.allocate(size, alignment);
}

return null;
```
And in [`HeapAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L88-L90):
```zig
_ = self.expandHeap(initial_pages);

self.initialized = true;
```

**Technical explanation:**  
1. **Missing alignment padding in `pages_needed`:** Inside the search loop (`heap_core.zig:143-146`), the required block payload is `total_needed = aligned_size + align_offset`, where `align_offset` is `8` bytes for `align_val == 16` on a page-aligned block (`HEADER_SIZE = 40`) and up to `align_val - 8` bytes for larger alignments. Line 181 omits `align_offset` when computing `pages_needed`, so `expandHeap()` can map a block that is still smaller than `total_needed`, triggering a second recursive `expandHeap()` call.
2. **False allocation failure on partial expansion (no memory leak):** In `expandHeap(page_count)` (`heap_core.zig:93-131`), each mapped page is immediately initialized as a `FREE` `BlockHeader`, linked into `head_block`, and coalesced with `curr` if `curr.is_free`. Thus, partial expansion does **not** leak physical frames or virtual pages (`R-06`, also exercised in `tests/heap_test.zig:495-529` `"Heap 11"`). However, because `allocate()` passes `@max(pages_needed, 4)` and only retries if `expandHeap()` returns `true` for all requested pages (and ignores any pre-existing free capacity in a `FREE` tail block), `allocate()` falsely returns `null` if `expandHeap()` stops after mapping `k < @max(pages_needed, 4)` pages even when those `k` pages (plus any coalesced free tail block) are large enough to satisfy the request.
3. **Unchecked `init()` expansion:** `HeapAllocator.init()` (`heap_core.zig:88`) ignores the return value of `_ = self.expandHeap(initial_pages);` and sets `self.initialized = true`.

*(Note: `F-10B` Part 3 at `b3cf68bbfc659be339b24cf8b3110be7eb159b53` intentionally extracted these existing behaviors into `heap_core.zig` without fixing `F-11`.)*

**Reproduction scenario:**  
1. **Under-expansion:** After `heap.init(4)` and `b1 = heap.allocate(16320, 16)` (which marks the initial 4-page block `USED` without splitting), calling `heap.allocate(16336, 64)` computes `pages_needed = (16336 + 40 + 4095) / 4096 = 4`. `expandHeap(4)` creates a 4-page free block at `heap_start + 0x4000` with `size = 16344`. On the recursive `allocate(16336, 64)` call, `payload_addr = +0x4028`, `aligned_payload = +0x4040`, `align_offset = 24`, and `total_needed = 16336 + 24 = 16360 > 16344`, forcing a second recursive `expandHeap(4)` call (8 pages = 32 KiB mapped for a 16 KiB request).
2. **False OOM on partial expansion:** When 2 pages (`8,192` B) remain before `heap_max_size`, `allocate(4096, 16)` computes `pages_needed = 2`, calls `expandHeap(@max(2, 4))` = `expandHeap(4)`, maps 2 pages (`8,152` B free block), hits `heap_max_size` on iteration 2, returns `false`, and `allocate(4096, 16)` returns `null`.

**Impact:**  
Unnecessary multi-page over-expansion on aligned allocations (`alignment >= 64`) and false Out-Of-Memory returns when fewer than 4 pages remain before `HEAP_MAX_SIZE` or PMM exhaustion.

**Recommended correction:**  
Include worst-case alignment padding in `pages_needed`, account for an existing `FREE` tail block's capacity when calculating additional pages needed, retry `allocate()` (or clamp `page_count` to `>= pages_needed`) if `expandHeap()` mapped enough pages to satisfy the request, and assert `expandHeap(initial_pages)` succeeds in `init()`.

**Regression tests:**  
1. Host unit test in [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig) verifying `init(4)` $\to$ `allocate(16320, 16)` $\to$ `allocate(16336, 64)` expands the heap once (by 5 pages) rather than twice (8 pages).
2. Host unit test in [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig) verifying `allocate(4096, 16)` succeeds when only 2 pages of headroom remain below `heap_max_size`.

**Dependencies:**  
Related to `F-12`; host test harness provided by completed `F-10` (`F-10B` Part 3).

---

### [F-12] Unchecked integer arithmetic overflow and missing power-of-two `alignment` validation in `heap.allocate()`

**Status:** VERIFIED

**Severity:** MEDIUM

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)) and kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)).

**Source location:**  
- [`kernel/src/mm/heap_core.zig:133-147`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L133-L147) and [`kernel/src/mm/heap_core.zig:180-182`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L180-L182)
- [`kernel/src/mm/heap.zig:50-54`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L50-L54)

**Evidence:**  
In [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L133-L147) (extracted in `b3cf68b`):
```zig
pub fn allocate(self: *Self, size: usize, alignment: usize) ?[*]u8 {
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
    const page_size_usize: usize = @intCast(PAGE_SIZE);
    const pages_needed = (aligned_size + HEADER_SIZE + page_size_usize - 1) / page_size_usize;
```

**Technical explanation:**  
1. **Arithmetic overflow:** Passing `size > std.math.maxInt(usize) - 15` overflows `size + 15` (`heap_core.zig:138`), and large `size` or `alignment` values overflow `payload_addr + align_val - 1` (`line 144`), `aligned_size + align_offset` (`line 146`), or `aligned_size + HEADER_SIZE + page_size_usize - 1` (`line 181`), triggering an integer-overflow panic in `Debug`/`ReleaseSafe` (or wrapping in `ReleaseFast`) instead of returning `null`.
2. **Unvalidated `alignment` in `pub fn allocate`:** While `vtableAlloc`/`heapAlloc` receives `std.mem.Alignment`, `pub fn allocate(size: usize, alignment: usize)` does not check `std.math.isPowerOfTwo(alignment)`. For a non-power-of-two `alignment > 16` (e.g., `24`), `(payload_addr + align_val - 1) & ~(align_val - 1)` produces an unaligned address.

*(Note: `F-10B` Part 3 at `b3cf68bbfc659be339b24cf8b3110be7eb159b53` intentionally extracted `allocate()` into `heap_core.zig` without fixing `F-12`.)*

**Reproduction scenario:**  
1. `heap.allocate(std.math.maxInt(usize), 16)` panics with `integer overflow` at `heap_core.zig:138` instead of returning `null`.
2. `heap.allocate(64, 24)` on `payload_addr = 0xffff_9000_0000_0028` computes `(0x...0028 + 23) & ~23 = 0xffff_9000_0000_0028`, which is neither 24-byte aligned nor 16-byte aligned.

**Impact:**  
Kernel panic on overflowing allocation requests and misaligned pointers if `allocate()` is called directly with a non-power-of-two alignment.

**Recommended correction:**  
Validate `if (alignment != 0 and !std.math.isPowerOfTwo(alignment)) return null;` (or panic on invalid alignment) and bound `if (size > self.heap_max_size or align_val > self.heap_max_size) return null;` at the top of `HeapAllocator.allocate()`.

**Regression tests:**  
1. Host unit test in [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig) verifying `allocate(std.math.maxInt(usize), 16)` and `allocate(64, 24)` return `null` cleanly.

**Dependencies:**  
Related to `F-11`; host test harness provided by completed `F-10` (`F-10B` Part 3).

---

### [F-13] VMM `mapPage()` and `unmapPage()` lack 48-bit canonical address validation, alignment checks, and parent `Flags.USER` propagation

**Status:** FIXED (Independently Source-Audited at `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`; Host Fake-Backend Unit Tests `VMM H & F-13` and `VMM I & F-13` Agent-Reported Passing; Canonical/Alignment Rejection Also Exercised in QEMU Ring 0 `vmm.testVmm()`, `Flags.USER` Hierarchy Promotion Host-Verified Only Prior to Ring 3)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Virtual Memory Manager core ([`kernel/src/mm/virtual_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig)), kernel VMM adapter ([`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig)), and VMM host test suite ([`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig)).

**Source location:**  
- [`kernel/src/mm/virtual_core.zig:45-60, 88-135, 206-222, 249-250`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L88-L135)
- [`kernel/src/mm/virtual.zig:15-20, 52-63, 73-128`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L73-L128)
- [`tests/vmm_test.zig:343-357, 470-501, 596-748`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L596-L748)

**Resolution & Independent Audit Evaluation (v1.7, Commit `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`):**
1. **Independently Reviewed Source Evidence:**
   - **48-Bit Canonical Address Validation (`virtual_core.zig:89-102, 128, 221, 250`):**
     - `isCanonical(virt: u64) bool` (`lines 89-93`, re-exported by `virtual.zig:15`) verifies sign-extension of bit 47 across bits `48..63` (`const signed: i64 = @bitCast(virt); const high_bits = signed >> 47; return high_bits == 0 or high_bits == -1;`).
     - `validateVirtualPage(virt)` (`lines 95-102`) returns `error.NonCanonicalAddress` before any page-table index calculation, table lookup, frame allocation, or `invlpg` in both `mapPage()` (`line 128`) and `unmapPage()` (`line 221`).
     - `virtToPhys()` (`line 250`) returns `null` (and `isMapped()` returns `false`) if `!isCanonical(virt)`.
   - **Virtual and Physical Page-Alignment Validation (`virtual_core.zig:99-101, 129-134, 221`):**
     - `validateVirtualPage(virt)` returns `error.UnalignedVirtualAddress` when `(virt & Flags.PAGE_OFFSET_MASK) != 0` in both `mapPage()` and `unmapPage()`.
     - `mapPage()` returns `error.UnalignedPhysicalAddress` when `(phys & Flags.PAGE_OFFSET_MASK) != 0` (`lines 129-131`) and `error.InvalidPhysicalAddress` when `(phys & ~Flags.PHYS_ADDR_MASK) != 0` (`lines 132-134`).
   - **Parent `Flags.USER` Propagation (`virtual_core.zig:111-117, 206-214`):**
     - After all validation and intermediate table allocations succeed, `linkOrPromoteUser` (`lines 111-117`) either installs newly allocated child tables with `intermediate_flags = Flags.PRESENT | Flags.WRITABLE | (flags & Flags.USER)` or, for already-present parent entries (`new_child_phys == null`), promotes `entry.* |= Flags.USER` across `pd.entries[pd_i]`, `pdpt.entries[pdpt_i]`, and `pml4.entries[pml4_i]` whenever `(flags & Flags.USER) != 0`. Because promotion occurs only at the commit stage (`lines 211-213`), rejected calls (`AlreadyMapped`, `HugePageConflict`, `OutOfMemory`) never mutate parent `Flags.USER` bits.
2. **Regression Test & Provenance Boundary (Host Fake-Backend vs. QEMU Runtime):**
   - **Independently Audited Host Regression Tests ([`tests/vmm_test.zig:596-748`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L596-L748)):**
     - `"VMM H & F-13"` (`lines 596-688`): Verifies `isCanonical` across lower/upper canonical bounds (`0x0000_0000_0000_0000`, `0x0000_7FFF_FFFF_FFFF`, `0xFFFF_8000_0000_0000`, `0xFFFF_FFFF_FFFF_FFFF`) and non-canonical addresses (`0x0000_8000_0000_0000`, `0x0001_0000_0000_0000`, `0x8000_0000_0000_0000`, `0xFFFF_7FFF_FFFF_FFFF`), confirms `mapPage`/`unmapPage`/`virtToPhys`/`isMapped` reject non-canonical addresses without aliasing `0x0`, and confirms `UnalignedVirtualAddress`, `UnalignedPhysicalAddress`, and `InvalidPhysicalAddress` rejection with zero allocations, frees, or TLB invalidations.
     - `"VMM I & F-13"` (`lines 690-748`): Maps supervisor pages first (`Flags.USER == 0`), then maps a `Flags.USER` page into the shared supervisor hierarchy (`0x0000_0040_0000_1000` sharing `PML4[0]`, `PDPT[256]`, `PD[0]`), asserting `Flags.USER` is promoted on `PML4[0]`, `PDPT[256]`, and `PD[0]` and set on `PT[1]`, while `PT[0]`, sibling `PDPT[257]`, and `PML4[1]` remain supervisor-only (`Flags.USER == 0`), and a subsequent supervisor mapping in the same PT preserves parent `Flags.USER` bits.
     - `"VMM C"` (`lines 343-357`) and `"VMM F"` (`lines 470-501`) verify that `AlreadyMapped` and `OutOfMemory` on a `Flags.USER` request do not promote `Flags.USER` on existing supervisor parents.
   - **In-Kernel QEMU Runtime Coverage vs. Host Simulation:**
     - [`vmm.testVmm()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L78-L128) in the live Ring 0 QEMU boot path tests `NonCanonicalAddress` (`0x0001_0000_0000_0000`), `UnalignedVirtualAddress` (`test_vaddr + 1`), and `UnalignedPhysicalAddress` (`phys_frame + 1`) rejection in `mapPage`/`unmapPage`/`virtToPhys`/`isMapped` alongside 4 KiB map/write/translate/unmap.
     - Parent `Flags.USER` hierarchy promotion (`VMM I & F-13`) is verified in the host fake-backend unit test (`tests/vmm_test.zig`), not via a Ring 3 user-mode hardware page-walk in QEMU (as Ring 3 userland is not authorized or implemented in Phase 1).

**Historical Evidence (Baseline `c10c05f1` through `bc2efdb0`):**
Prior to `0156e910`, `virtual.zig` masked page-table indices without checking bits `48..63` for canonicality, did not check 4 KiB alignment of `virt` or `phys`, and only set `Flags.USER` on newly allocated intermediate page tables (`if ((entry & Flags.PRESENT) == 0)`).

**Dependencies:**  
Related to `F-09` and `F-10` (`F-10B` Part 2).

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
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)) and kernel adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:158-166`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L158-L166) and [`kernel/src/mm/physical_core.zig:198-202`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L198-L202)
- [`kernel/src/mm/physical.zig:80-110`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L80-L110)

**Evidence:**  
In [`PhysicalAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L158-L166) (extracted in `bc2efdb`):
```zig
// Preserve existing bitmap placement rule: first non-zero-based usable entry holding bitmap_size_bytes.
var chosen_bitmap_phys: ?u64 = null;
for (0..region_count) |i| {
    const region = regions.get(i);
    if (region.kind == .usable and region.length >= computed_bitmap_size and region.base != 0) {
        chosen_bitmap_phys = region.base;
        break;
    }
}
```
Compare with lines 198–202 in the same function:
```zig
// Keep the first 1 MiB / page 0 reserved for legacy BIOS/hardware stability.
if (@as(u64, @intCast(frame)) * PAGE_SIZE < 0x100000) {
    continue;
}
```

**Technical explanation:**  
Line 199 of `physical_core.zig`, [`docs/ARCHITECTURE.md:82`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md#L82), [`ADR-0001:29`](file:///home/leevawn/Projects/zig-os/docs/adr/0001-higher-half-kernel-memory-layout.md#L29), and [`.agents/rules/04-memory-management.md:12`](file:///home/leevawn/Projects/zig-os/.agents/rules/04-memory-management.md#L12) all specify that physical memory below `1 MiB` (`0x0..0x100000`) must remain reserved. However, the bitmap placement loop at line 162 only checks `region.base != 0` instead of `region.base >= 0x100000`. Because Limine reserves page `0x0` (`0x0..0x1000`) and reports conventional low RAM starting above `0x0` (below the EBDA at `~0x9F000`) as `.usable`, any `.usable` entry with `0 < region.base < 0x100000` and `region.length >= computed_bitmap_size` is selected by line 162 for `chosen_bitmap_phys` (as demonstrated in [`tests/pmm_test.zig:511-521`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L511-L521), where `region.base = 0x1000` is selected for `pmm.bitmap_phys`). *(Note: The current boot log does not print the memory map entries or `bitmap_phys`, so the exact physical address chosen in QEMU is not asserted without runtime logging; what is statically `VERIFIED` is that `region.base != 0` permits `< 1 MiB` placement whenever that conventional `.usable` entry is `>= computed_bitmap_size`.)*

**Reproduction scenario:**  
Given any memory map whose first `.usable` entry has `0 < region.base < 0x100000` and `region.length >= computed_bitmap_size`, `PhysicalAllocator.init()` selects `bitmap_phys = region.base` (`< 0x100000`).

**Impact:**  
Violates the project's `< 1 MiB` reservation policy (which protects low memory for legacy BIOS data and future SMP AP real-mode startup trampolines), although it does not corrupt non-usable memory in Phase 1 because `region.kind == .usable` and the bitmap frames are marked used at `physical_core.zig:209-217`.

**Recommended correction:**  
Require `bitmap_phys >= 0x100000` when scanning `.usable` entries in `PhysicalAllocator.init()` (clamping candidate region starts below `0x100000` up to `0x100000` and checking if the remaining length is `>= computed_bitmap_size`).

**Regression tests:**  
1. Assert `pmm.bitmap_phys >= 0x100000` in [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig) and `pmm.virtToPhys(@intFromPtr(pmm.bitmap)) >= 0x100000` in `pmm.testPmm()`, and log `bitmap_phys` during PMM initialization.

**Dependencies:**  
Related to `F-07` and `F-08`; host test harness provided by completed `F-10` (`F-10B` Part 1).

---

### [F-17] PMM page counters (`usable_pages`, `used_pages`, `free_pages`) have undocumented, differing semantics

**Status:** VERIFIED

**Severity:** INFORMATIONAL

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)) and kernel adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:94-98`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L94-L98) and [`kernel/src/mm/physical_core.zig:190-248`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L190-L248)
- [`kernel/src/mm/physical.zig:18-21, 62-70`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L18-L21)

**Evidence:**  
In [`physical_core.zig:190-248`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L190-L248) and [`physical.zig:18-21`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L18-L21):
- `usable_pages` is zeroed at `physical_core.zig:177`, incremented at line 203 for each `.usable` frame `>= 0x100000` before the bitmap frames are marked used (lines 209–217), and is never read by any kernel subsystem outside `tests/pmm_test.zig:163`.
- `used_pages` and `free_pages` are recounted over `0..total_pages` at `physical_core.zig:220-248` (so `used_pages` includes all non-usable/reserved/MMIO frames plus the bitmap frames, and `used_pages + free_pages == total_pages`), updated on `allocPage()`/`allocPages()`/`freePage()`, and checked in `pmm.testPmm()` (`physical.zig:143-177`) and `tests/pmm_test.zig`.
- *(Note: The unused `total_usable_bytes` local variable present at `c10c05f` was removed during `F-10B` Part 1 at `bc2efdb`.)*

**Technical explanation:**  
Because `usable_pages` counts gross `.usable` frames `>= 1 MiB` while `free_pages` counts net available frames after reserving the PMM bitmap and `used_pages` counts `total_pages - free_pages` (including non-RAM MMIO holes and `< 1 MiB` reserved frames), this is **not a functional defect**. However, the differing meanings of `total_pages`, `usable_pages`, `used_pages`, and `free_pages` should be explicitly documented in doc-comments on `PhysicalAllocator` and `physical.zig` before a future `meminfo` utility (Phase 5) or OOM diagnostic reads `used_pages` and mistakes non-RAM holes for allocated RAM pages.

**Reproduction scenario:**  
At the end of `pmm.init()`, `used_pages + free_pages == total_pages` (which includes non-RAM holes up to `highest_address`), whereas `usable_pages` counts only `.usable` RAM frames `>= 0x100000` prior to subtracting the bitmap footprint.

**Impact:**  
No functional impact in Phase 1; potential reporting confusion in future memory-statistics utilities if counter semantics are not defined in doc-comments.

**Recommended correction:**  
Document the exact invariant for each counter in `physical_core.zig` and `physical.zig` (`total_pages`: bitmap span in frames; `usable_pages`: gross `.usable` RAM frames `>= 1 MiB`; `free_pages`: currently allocatable `.usable` frames; `used_pages`: `total_pages - free_pages`).

**Regression tests:**  
1. Host unit tests in [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L109-L125) already assert `total_pages == used_pages + free_pages`; retain and pair with documented counter comments.

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

> **Governance Gate Notice:** This section defines the proposed engineering sequence for **Phase 1 Hardening**. It does **not** authorize Phase 2 (`NOT AUTHORIZED`) and does **not** mark Phase 1 as Human Approved (`Pending Human Review`). Completing `F-10` (or `F-01`, `F-09`, `F-13`, `F-14`) does not constitute Project Owner approval of Phase 1 or Phase 2. Only the Project Owner may approve milestone gates.

### P0 — Must Fix Before Further Kernel Development (0 Active Findings — All 3 Resolved)

**Included Active Findings:** None (`F-01`, `F-10`, and `F-14` are `FIXED`)
- **`F-01` (`FIXED` at `515aa91`):** Freestanding kernel target in [`build.zig:4-20`](file:///home/leevawn/Projects/zig-os/build.zig#L4-L20) subtracts `.x87`, `.mmx`, `.sse`, `.sse2`, `.avx`, `.avx2` and adds `.soft_float`.
- **`F-14` (`FIXED` at `7711468`):** All public build/run/debug/test entrypoints enforce unconditional fresh builds, `ReleaseSafe` default optimization, a non-recursive Zig build graph, and 3-way kernel ELF SHA-256 provenance verification prior to QEMU launch.
- **`F-10` (`FIXED` across `9df21f8`, `bc2efdb`, `0156e91`, and `b3cf68b`):** `zig build test` ([`build.zig:123-210`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L210)) compiles and runs four host test targets directly against production kernel modules with zero test-side algorithm duplication:
  - `unit_test` ([`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig)): 7 tests importing `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` (`F-10A`).
  - `pmm_test` ([`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig)): 10 stateful tests importing `physical_core.zig` (`F-10B` Part 1).
  - `vmm_test` ([`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig)): 10 stateful tests importing `virtual_core.zig` (`F-10B` Part 2).
  - `heap_test` ([`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)): 14 stateful tests importing `heap_core.zig` (`F-10B` Part 3).

---

### P1 — Must Fix Before Phase 2 Authorization (8 Active Findings)

**Included Active Findings:** `F-03`, `F-04`, `F-06`, `F-07`, `F-08`, `F-11`, `F-12`, `F-15`
*(Note: VMM findings `F-09` and `F-13` were resolved at `0156e91` in `virtual_core.zig` and `virtual.zig`, with host regression tests in `tests/vmm_test.zig` and Ring 0 canonical/alignment checks in `vmm.testVmm()`).*

- **Dependencies:** Enabled by completed **P0** foundation (`F-01` SIMD prohibition, `F-10` host-testable core modules, and `F-14` rebuild/provenance pipeline). `F-04` requires updating/superseding [`ADR-0003`](file:///home/leevawn/Projects/zig-os/docs/adr/0003-limine-gdt-preservation-phase1.md); `F-15` coordinates with `F-01` and Phase 2 FPU context switching.
- **Required Implementation Tasks:**
  1. **`F-03`, `F-04`, & `F-15` (Interrupt Vector Protection, GDT/TSS/IST, Frame Verification, & `CR0.TS` Initialization):** Prohibit Ring 0 software `INT n` to hardware error-code exception vectors (`8, 10..14, 17, 21, 29, 30`), remap or keep masked the legacy 8259 PIC (`>= 0x20`), assign APIC interrupt vectors outside `0–31`, and preserve `DPL = 0` on exception gates (`F-03`, noting dynamic stack alignment alone does not repair a missing error-code slot); install a kernel-owned GDT and 64-bit TSS (`lgdt`, `ltr`) with a dedicated `IST1` stack for `#DF` (Vector 8) (`F-04`); clear `CR0.TS` (bit 3) alongside `CR0.EM` (bit 2) in [`cpu.enableSse()`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129) so `CR0.TS == 0` is guaranteed under Limine Base Revision 3 (`F-15`).
  2. **`F-06`, `F-11`, & `F-12` (Heap Hardening in `heap_layout.zig` / `heap_core.zig`):** Store `align_offset: u32` in [`BlockHeader`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L4-L12) and enforce `raw_addr == payload_start + block.align_offset` in [`HeapAllocator.deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L189-L208); include alignment padding in `pages_needed` and handle partial expansion / free tail blocks in [`HeapAllocator.expandHeap()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L93-L131); check `init()` expansion status; validate `std.math.isPowerOfTwo(alignment)` and `size <= self.heap_max_size` before arithmetic in [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L133-L187).
  3. **`F-07` & `F-08` (PMM Hardening in `physical_core.zig` / `physical.zig`):** Compute `highest_address` across RAM/reclaimable memory map entries only (excluding `.reserved` MMIO apertures); in [`PhysicalAllocator.freePage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L314-L336), validate `paddr >= 0x100000`, non-overlap with `[self.bitmap_phys, self.bitmap_phys + self.bitmap.len)`, and membership in a `.usable` memory map region.
- **Required Regression Tests:**
  - **`F-15` (Dual-Layer `CR0.TS` Verification):** (a) Privileged in-kernel QEMU runtime test that deliberately sets `CR0.TS = 1` immediately before calling `cpu.enableSse()` (with zero intervening FPU/SSE instructions) and verifies `(cpu.readCr0() & ((1 << 2) | (1 << 3))) == 0` afterward, and (b) host unit test in [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig) verifying the pure `computeSseCr0()` bit-mask helper clears `CR0.TS` and `CR0.EM` on synthetic `CR0` values.
  - Host unit tests in [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig) and [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig) (plus in-kernel self-tests) covering interior/padding/slack pointer free rejection (`F-06`), `allocate(16336, 64)` single-expansion and 2-page headroom behavior (`F-11`), overflow/non-power-of-two alignment rejection (`F-12`), PMM high-MMIO-hole sizing (`F-07`), and `freePage(0x0)` / `freePage(bitmap_phys)` / non-usable region rejection (`F-08`).
  - Three-regime QEMU interrupt frame verification (`F-04`): (a) same-CPL (`IST = 0`) exceptions verifying saved `frame.rsp` and `frame.ss`, (b) `IST1` stack-switched `#DF` verifying `IST1` stack pointer and interrupted `frame.rsp`/`frame.ss`, and (c) `CPL 3 -> CPL 0` privilege transition frame verification once Ring 3 exists.
- **Acceptance Criteria:** All CPU `CR0`/`CR4`, PMM, VMM, Heap, GDT/TSS, and IDT invariants pass host unit tests (`zig build test`) and fresh-build QEMU runtime verification in both `Debug` and `ReleaseSafe` modes.

---

### P2 — Important Hardening That Can Follow (2 Active Findings)

**Included Active Findings:** `F-16`, `F-19`

- **Dependencies:** `F-16` coordinates with `F-07`/`F-08`; `F-19` requires Project Owner selection between Base Revision 3 explicit ACPI mapping vs. Base Revision 4 ADR update.
- **Required Implementation Tasks:**
  1. **`F-16`:** Enforce `bitmap_phys >= 0x100000` (`1 MiB`) in [`PhysicalAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L158-L166) and log the selected `bitmap_phys` address.
  2. **`F-19`:** Before Phase 2 ACPI table access, either map `.acpi_reclaimable` / `.acpi_nvs` regions into the HHDM via `vmm.mapPage()` or advance Limine Base Revision to `4` via an approved ADR.
- **Required Regression Tests:**
  - Assert `bitmap_phys >= 0x100000` in [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig) and `pmm.testPmm()`, and verify HHDM reachability of `.acpi_reclaimable` frames before ACPI parsing.
- **Acceptance Criteria:** `< 1 MiB` strictly preserved for SMP trampolines and ACPI memory safely mapped prior to Phase 2 MADT discovery.

---

### P3 — Future Improvements (3 Active Findings & Architectural Maintenance)

**Included Active Findings:** `F-17`, `F-18`, `F-20`

- **Dependencies:** None.
- **Required Implementation Tasks:**
  1. **`F-17`:** Document exact semantics for `total_pages`, `usable_pages`, `used_pages`, and `free_pages` in [`physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig) and [`physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig) (note: unused `total_usable_bytes` was removed in `bc2efdb`).
  2. **`F-18`:** Add `*(.got .got.*)` to `.data` before `.bss` in [`kernel/linker.ld`](file:///home/leevawn/Projects/zig-os/kernel/linker.ld) (and export section boundary symbols when kernel-constructed page tables are introduced).
  3. **`F-20`:** Optionally add an explicit `PagingModeRequest` (`4LVL`) to [`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig) and assert `(cpu.readCr4() & (1 << 12)) == 0`.
  4. **Intermediate Page Table Reclamation & Documentation Sync:** Reclaim empty `PT`/`PD`/`PDPT` tables during Phase 2 process teardown, and update [`ADR-0004`](file:///home/leevawn/Projects/zig-os/docs/adr/0004-segregated-heap-allocator-canaries.md) / [`docs/ARCHITECTURE.md`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md) to reflect the 40-byte `BlockHeader`.
- **Required Regression Tests:**
  - `readelf -S -l zig-out/bin/kernel.elf` confirms no orphan `.got` after `.bss` and `FileSiz < MemSiz` on the `data` segment.
- **Acceptance Criteria:** Clean ELF segment layout, documented PMM counter invariants, and synchronized architecture documentation.
