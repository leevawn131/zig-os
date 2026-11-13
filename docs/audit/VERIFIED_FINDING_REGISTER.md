# ZIG-OS — Verified Finding Register & Phase 1 Hardening Plan

> - **Document Authority:** Principal Kernel Auditor & Documentation Architect (Gemini 4 Argon)
> - **v1.9–v2.1 Documentation Operator:** Gemini 4 Hydrogen *(temporary documentation-only fallback while Gemini 4 Argon is out of quota; `F-06`/`F-11`/`F-12` at v1.9, `F-15` at v2.0, and `F-03` at v2.1 reflected from independent source reviews by ChatGPT)*
> - **Original Audit Baseline:** `c10c05f1f37aacfda5046480a314f29d940b67ef` (`main`)
> - **Current Implementation Snapshot:** `697f1ff58a031422da41645b0ba4a422e576281a` (`main`)
> - **Audit Date:** 2026-11-11 (Updated: 2026-11-13)
> - **Scope:** Independent source, build-pipeline, and ELF binary verification for Phase 1 hardening.

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
| **v1.8** | 2026-11-13 | Gemini 4 Argon | Consolidated PMM hardening audit at HEAD `c1ef192b336ba548ac0acb5340d92143bdad7994` (`fix(mm): harden PMM memory-map and free validation (F-07 F-08 F-16)`): (1) independently audited `kernel/src/mm/physical_core.zig`, `kernel/src/mm/physical.zig`, and `tests/pmm_test.zig` (16 stateful PMM tests; `47/47` total host unit tests across `unit_test` [7], `pmm_test` [16], `vmm_test` [10], and `heap_test` [14]); (2) marked `F-07` (`RegionKind.contributesToHighestAddress()` RAM-backed ceiling calculation, explicit `mapLimineRegionKind()` mapping, and checked arithmetic excluding high MMIO/framebuffer/reserved apertures), `F-08` (6-step `validateFreePage()` enforcing `< 1 MiB` `ReservedAddress`, page-rounded `BitmapOverlap`, and `.usable` `NotUsableRegion`, two-pass atomic `freePages()`, exhaustive `panicOnFreeError()`, value-stored `RegionSource` union, and module-static `limine_region_ctx`), and `F-16` (`>= 1 MiB` page-aligned bitmap placement, page-rounded backing fit, non-usable overlap rejection, and full `[bitmap_phys, bitmap_end_phys)` frame reservation) as `FIXED` (concurring with independent review by ChatGPT); (3) maintained strict provenance separation between independent source audit, agent-reported 4-mode host tests (`47/47`), 4-mode kernel builds, `F-01` disassembly (`0` matches), `Debug`/`ReleaseSafe` QEMU smoke tests, and host-only synthetic memory-map cases (64 TiB MMIO exclusion and `freePages()` failure-atomicity); (4) preserved `F-03`, `F-04`, `F-06`, `F-11`, `F-12`, `F-15`, `F-17`, `F-18`, `F-19`, and `F-20` as `OPEN`; and (5) reconciled all status (`9 VERIFIED`, `1 LIKELY`, `8 FIXED`, `9 REJECTED`; `10` active findings), severity (`0 CRITICAL`, `1 HIGH`, `5 MEDIUM`, `2 LOW`, `2 INFORMATIONAL`), and priority (`P0: 0`, `P1: 6`, `P2: 1`, `P3: 3`) tables. |
| **v1.9** | 2026-11-13 | Gemini 4 Hydrogen *(Documentation Operator fallback)* | Updated register at HEAD `0092cf37f8c26cbdcea1c1d5eba98676b2542667` (`fix(heap): restore zero-alignment compatibility and check split bounds (F-11 F-12)`, following `18dabd7c3f62345b4970f8a4baf3016197471e11`) acting in temporary documentation-only fallback capacity while Gemini 4 Argon is unavailable (permanent Document Authority remains Gemini 4 Argon): (1) recorded independent source/diff review dispositions by ChatGPT marking `F-06`, `F-11`, and `F-12` as `FIXED` across `kernel/src/mm/heap_layout.zig`, `kernel/src/mm/heap_core.zig`, `kernel/src/mm/heap.zig`, and `tests/heap_test.zig` (specifically preserving `alignment == 0` -> 16-byte default compatibility restored at `0092cf3`); (2) preserved strict provenance separation between ChatGPT's independent source/diff review and implementation-agent-reported execution results (`54/54` uncached host tests across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`: `unit_test` [7], `pmm_test` [16], `vmm_test` [10], `heap_test` [21]; 4-mode kernel builds; `F-01` disassembly `0` matches; `Debug` and `ReleaseSafe` QEMU smoke tests with 3-way provenance); (3) preserved Phase 1 (`Pending Human Review`) and Phase 2 (`NOT AUTHORIZED`) gates unchanged; and (4) reconciled all status (`6 VERIFIED`, `1 LIKELY`, `0 NEEDS_RUNTIME_VERIFICATION`, `9 REJECTED`, `11 FIXED`; `7` active findings), severity (`0 CRITICAL`, `0 HIGH`, `3 MEDIUM` [`F-03`, `F-04`, `F-15`], `2 LOW` [`F-18`, `F-19`], `2 INFORMATIONAL` [`F-17`, `F-20`]), and priority (`P0: 0`, `P1: 3` [`F-03`, `F-04`, `F-15`], `P2: 1` [`F-19`], `P3: 3` [`F-17`, `F-18`, `F-20`]) tables. |
| **v2.0** | 2026-11-13 | Gemini 4 Hydrogen *(Documentation Operator fallback)* | Updated register at HEAD `6aa895d419843b106d9773a8b375c501f1530095` (`fix(cpu): clear CR0.TS during SSE initialization (F-15)`) acting in temporary documentation-only fallback capacity while Gemini 4 Argon is unavailable (permanent Document Authority remains Gemini 4 Argon): (1) recorded ChatGPT's independent source/diff review disposition (`PASS / FIXED` at source level) for `F-15` across `kernel/src/arch/x86_64/sse.zig`, `kernel/src/arch/x86_64/cpu.zig`, `kernel/src/main.zig`, `tests/unit_test.zig`, and `build.zig`; (2) documented hardware-independent CR0/CR4 helpers (`computeSseCr0()`, `computeSseCr4()`, `isSseCr0Valid()`, `isSseCr4Valid()`) used by `cpu.enableSse()` and host `unit_test` via `build.zig`, plus Ring 0 boot regression `cpu.testSseCr0Init()` invoked during `_start()` after serial initialization and before IDT initialization; (3) maintained strict provenance separation between ChatGPT's independent source/diff inspection (ChatGPT did not independently execute tests, builds, or QEMU) and implementation-agent-reported execution (`56/56` uncached host tests across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`: `unit_test` [9], `pmm_test` [16], `vmm_test` [10], `heap_test` [21]; 4-mode kernel builds; `F-01` disassembly `0` matches; `Debug` and `ReleaseSafe` QEMU smoke tests with Ring 0 marker `[CPU] SSE/CR0.TS initialization verified.` and 3-way ELF SHA-256 provenance); (4) preserved Phase 1 (`Pending Human Review`) and Phase 2 (`NOT AUTHORIZED`) gates unchanged; and (5) reconciled all status (`5 VERIFIED`, `1 LIKELY`, `0 NEEDS_RUNTIME_VERIFICATION`, `9 REJECTED`, `12 FIXED`; `6` active findings), severity (`0 CRITICAL`, `0 HIGH`, `2 MEDIUM` [`F-03`, `F-04`], `2 LOW` [`F-18`, `F-19`], `2 INFORMATIONAL` [`F-17`, `F-20`]), and priority (`P0: 0`, `P1: 2` [`F-03`, `F-04`], `P2: 1` [`F-19`], `P3: 3` [`F-17`, `F-18`, `F-20`]) tables. |
| **v2.1** | 2026-11-13 | Gemini 4 Hydrogen *(Documentation Operator fallback)* | Updated register at HEAD `697f1ff58a031422da41645b0ba4a422e576281a` (`fix(test): detect preprocessor-expanded forbidden INT vectors`, covering `4b3ea6f`, `184784d`, and `697f1ff`) acting in temporary documentation-only fallback capacity while Gemini 4 Argon is unavailable (permanent Document Authority remains Gemini 4 Argon): (1) moved `F-03` from `VERIFIED` to `FIXED` reflecting ChatGPT's independent source/diff reviews (`PASS` at source level for `F-03` implementation `4b3ea6f`, `F-03-R1` fail-closed scanner `184784d`, and `F-03-R2` `.S` preprocessor scanner `697f1ff`) across `kernel/src/arch/x86_64/interrupts/vectors.zig`, `kernel/src/arch/x86_64/interrupts/pic.zig`, `kernel/src/arch/x86_64/idt/idt.zig`, `kernel/src/main.zig`, `tests/vector_policy_test.zig`, and `build.zig`; (2) updated `F-10` and Section 6 P0 summary for the 5th host test target (`vector_policy_test`, 11 tests → `67` aggregate host unit tests); (3) maintained strict provenance separation between ChatGPT's independent source/diff reviews (ChatGPT did not independently execute tests, builds, or QEMU) and implementation-agent-reported (Hydrogen) execution (`67/67` host tests in all four optimization modes, four-mode kernel builds, zero prohibited SIMD/x87 matches, zero live kernel scanner hits, and `Debug`/`ReleaseSafe` QEMU smoke tests with Ring 0 `[PIC]` and `[IDT]` markers); (4) preserved `F-04` as `VERIFIED` (`P1`), Phase 1 as `Pending Human Review`, and Phase 2 as `NOT AUTHORIZED`; and (5) reconciled all status (`4 VERIFIED`, `1 LIKELY`, `0 NEEDS_RUNTIME_VERIFICATION`, `9 REJECTED`, `13 FIXED`; `5` active findings), severity (`0 CRITICAL`, `0 HIGH`, `1 MEDIUM` [`F-04`], `2 LOW` [`F-18`, `F-19`], `2 INFORMATIONAL` [`F-17`, `F-20`]), and priority (`P0: 0`, `P1: 1` [`F-04`], `P2: 1` [`F-19`], `P3: 3` [`F-17`, `F-18`, `F-20`]) tables. |

---

## 1. Audited Snapshot & Workspace Identification

### 1.1 Git Snapshot Identity

| Attribute | Original Audit Baseline (`v1.0`–`v1.3.1`) | Current Implementation Snapshot (`v2.1`) | Match Status |
|---|---|---|---|
| **Repository** | `leevawn131/zig-os` | `leevawn131/zig-os` | **MATCH** |
| **Branch** | `main` (`origin/main` first-parent ancestor; `origin/dev` ref also points to `c10c05f1`) | `main` (`origin/main`) | **MATCH** |
| **HEAD Commit SHA** | `c10c05f1f37aacfda5046480a314f29d940b67ef` | `697f1ff58a031422da41645b0ba4a422e576281a` | **EXACT MATCH** |
| **Commit Subject** | `feat(kernel): implement Phase 1 core kernel infrastructure` | `fix(test): detect preprocessor-expanded forbidden INT vectors` | **EXACT MATCH** |
| **Commit Timestamp** | `2026-11-10T14:10:11+07:00` | `2026-11-13T17:20:09+07:00` | **EXACT MATCH** |
| **Intervening Source Commits** | — | `515aa91becaf772f3f5b9243f92c1c0828f5d0bc` (`F-01` fix), `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6` (`F-10A` pure modules), `771146810e41854f2b9e754f2a048f142ab633a8` (`F-14` fix), `bc2efdb0e673a6086f59e5ad0ca1669216f8c604` (`F-10B` Part 1 PMM), `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6` (`F-10B` Part 2 VMM + `F-09`/`F-13`), `b3cf68bbfc659be339b24cf8b3110be7eb159b53` (`F-10B` Part 3 Heap), `c1ef192b336ba548ac0acb5340d92143bdad7994` (`F-07`/`F-08`/`F-16` PMM hardening), `18dabd7c3f62345b4970f8a4baf3016197471e11` (`F-06`/`F-11`/`F-12` heap hardening), `0092cf37f8c26cbdcea1c1d5eba98676b2542667` (`align=0` compatibility & checked split/bounds hardening), `6aa895d419843b106d9773a8b375c501f1530095` (`F-15` `CR0.TS` initialization fix & tests; following `v1.9` register update `5b142b4fd9a39a316cea61cb24dc6fabcaf92abf`), `4b3ea6fcb2fd1c3c03ff57b530bace20012b68b8` (`F-03` vector policy, masked 8259 PIC remap, IDT gate validation, & static `INT` scanner; following `v2.0` register update `4a266a30bfdf3d4bc188182f2622d1fdd87f92c3`), `184784ddf7596cc8aa330a6856eaed7a9cd804ad` (`F-03-R1` fail-closed symbolic & Zig escape `INT` scanner hardening), `697f1ff58a031422da41645b0ba4a422e576281a` (`F-03-R2` `.S` C-preprocessor `INT` scanner hardening) | **VERIFIED** |

### 1.2 Working Tree & Build Artifact Status (`git status --short`)

At current snapshot `697f1ff58a031422da41645b0ba4a422e576281a`:
```text
 D zig.zip
?? graphify-out/
```

- **Kernel, Linker, Build, and Test Source Integrity (`697f1ff`):** Zero tracked source files under [`kernel/`](file:///home/leevawn/Projects/zig-os/kernel), [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`scripts/`](file:///home/leevawn/Projects/zig-os/scripts), [`tests/`](file:///home/leevawn/Projects/zig-os/tests), [`.agents/`](file:///home/leevawn/Projects/zig-os/.agents), or [`docs/`](file:///home/leevawn/Projects/zig-os/docs) have uncommitted modifications outside this documentation-only register update. All tracked code, build definitions, scripts, rules, documentation, and tests match commit `697f1ff58a031422da41645b0ba4a422e576281a` byte-for-byte (`4b3ea6f` added [`kernel/src/arch/x86_64/interrupts/vectors.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig), [`kernel/src/arch/x86_64/interrupts/pic.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/pic.zig), and [`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig) and updated [`kernel/src/arch/x86_64/idt/idt.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig), [`kernel/src/main.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig), [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`.agents/rules/05-interrupt-and-abi.md`](file:///home/leevawn/Projects/zig-os/.agents/rules/05-interrupt-and-abi.md), [`docs/ARCHITECTURE.md`](file:///home/leevawn/Projects/zig-os/docs/ARCHITECTURE.md), and [`docs/TESTING_POLICY.md`](file:///home/leevawn/Projects/zig-os/docs/TESTING_POLICY.md); `184784d` updated [`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig); `697f1ff` updated [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig) and [`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig)).
- **Untouched Working-Tree Artifacts:** `D zig.zip` and `?? graphify-out/` remain untouched in the local workspace per governance safety rules (`zig.zip` and `docs/md.zip` changed externally prior to `697f1ff`, causing `git status --porcelain` in `scripts/lib/common.sh` to report `tree=dirty` during local builds).
- **Implementation-Agent-Reported Build & ISO Artifacts at `697f1ff` (`Debug` via `bash scripts/test-boot.sh --optimize Debug` and `ReleaseSafe` via `python3 tests/test_boot.py --optimize ReleaseSafe`; Not Independently Executed by ChatGPT or Argon; 3-Way Kernel ELF Provenance Reported; Kernel ELF Hashes Match `4b3ea6f` Because `184784d` and `697f1ff` Modified Only `tests/` and `build.zig` Host Options):**
  ```text
  Debug:
    ELF: 4f04b87e2bcc68832bc018e1dc7d2b5943452fb85ec24b730b555814f36d1ba0
    ISO: b9ac5388939be188cb51609c64dea7ca227a82a97285fd54d944e7018bb31190

  ReleaseSafe:
    ELF: 074a0ff28228d2f306c597ee71b821cdd585cee8957e88514cf7955ebf812211
    ISO: e9a06d4c1994d2981211f0d7335b85e43b917c471e2c4549fa07f1e54efd4157
  ```
- **Historical Build Artifacts Reported at `6aa895d` (`v2.0`, `F-15` `CR0.TS` Initialization Fix; Implementation-Agent-Reported Only):**
  ```text
  Debug:
    ELF: bac556b4525699bff5b6c01514000d0d7f731dd2ca5f576492de17937c102267
    ISO: e064c912ca626b076f0a25b918a2609f7ed5b55200530c76652c2af420a94efe

  ReleaseSafe:
    ELF: 2d359beb75cd14d796ad81e9a53a45f2f6dec27cd9f440c43e3d9318a9076c57
    ISO: ce59150a294695600fe5e4ae58a528f6f04ab6ee954d20413d986d2786beb82d
  ```
- **Historical Build Artifacts Inspected at `0092cf3` (`v1.9`, Heap Hardening Corrective Patch):**
  ```text
  4db2911990d19ca63045aa3dcdab13ac93b272a3c2b9210d8dd59365e1ecec0c  zig-out/bin/kernel.elf (ReleaseSafe)
  4db2911990d19ca63045aa3dcdab13ac93b272a3c2b9210d8dd59365e1ecec0c  build/iso_root/boot/kernel.elf (ReleaseSafe)
  f283df7385fbd1ac5ffbc303414d4fcfa4d6871f62b99a92e7a49d49f5c26c34  build/zig-os.iso (ReleaseSafe)
  76f798ca76424630ad7f7938e7ab68d249f7ef7aa4456339e1bd9c6c63ba2732  zig-out/bin/kernel.elf (Debug, agent-reported)
  76f798ca76424630ad7f7938e7ab68d249f7ef7aa4456339e1bd9c6c63ba2732  build/iso_root/boot/kernel.elf (Debug, agent-reported)
  23a568024f7526bea6f3d050eb05f887c732b7da9981f0cab5c5e009004b0102  build/zig-os.iso (Debug, agent-reported)
  ```
- **Historical Build Artifacts Inspected at `c1ef192` (`v1.8`, PMM Hardening):**
  ```text
  8a3184185b09f97970764cbd722eed42e8e21aafb9292434adee39d8e8ab064f  zig-out/bin/kernel.elf (ReleaseSafe)
  8a3184185b09f97970764cbd722eed42e8e21aafb9292434adee39d8e8ab064f  build/iso_root/boot/kernel.elf (ReleaseSafe)
  a5b1a9ccc0fb0fdf964bbf6d8a70be07a7d8b47b06786c7538138d1e65bd1948  build/zig-os.iso (ReleaseSafe)
  539f0998886c12b990e9af57b10862fe9f6f811ee2e0f93667ebf44bba45de09  zig-out/bin/kernel.elf (Debug, agent-reported)
  09f882ef9a6ceee505cb9b977fa55664b623aa615fcc24bcd9abde0840c4d2f7  build/zig-os.iso (Debug, agent-reported)
  ```
- **Historical Build Artifacts Inspected at `b3cf68b` (`v1.7`, `F-10B` Part 3):**
  ```text
  beb50ec40adbf0f5376b5c9777736eb16027a0dfb4ef38d5e32ca5e9a9d86471  zig-out/bin/kernel.elf (Debug)
  169982e35631ee32f94faf9df45ac68065efc7611c3bf8222a146b73933bb532  zig-out/bin/kernel.elf (ReleaseSafe)
  93ae4d560ba09feac47ff5163a457151512fecc3f2f2e02144022797b6cb79ca  zig-out/bin/kernel.elf (ReleaseFast)
  fe45f8395266259aa1209d641e8565f18817288901e898f4c740f54de7d6f5d2  zig-out/bin/kernel.elf (ReleaseSmall)
  af681f65bbc6eccd68e9bacefa9b6d59f927728e937c58bc9c4b70c8e965260d  build/zig-os.iso (Debug)
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
| **Static Source Inspection (`c10c05f` through `697f1ff`)** | **YES (`c10c05f`–`c1ef192` Audited by Argon; `18dabd7`–`0092cf3`, `6aa895d`, & `4b3ea6f`–`697f1ff` Independently Reviewed by ChatGPT)** | Direct line-by-line review of source files and diffs across `kernel/`, `build.zig`, `scripts/`, `tests/`, `.agents/`, `docs/`, and `/opt/zig/current/lib/std/Target/x86.zig` | Baseline through `c1ef192b` independently audited by Gemini 4 Argon. At `0092cf3` (`v1.9`), independent technical reviewer **ChatGPT** reviewed `heap_layout.zig`, `heap_core.zig`, `heap.zig`, and `tests/heap_test.zig`, issuing `FIXED` source dispositions for `F-06`, `F-11`, and `F-12`. At `6aa895d` (`v2.0`), **ChatGPT** independently reviewed `sse.zig`, `cpu.zig`, `main.zig`, `tests/unit_test.zig`, and `build.zig`, issuing `PASS / FIXED` at source level for `F-15`. Across `4b3ea6f` (`F-03`), `184784d` (`F-03-R1`), and `697f1ff` (`F-03-R2`) (`v2.1`), **ChatGPT** independently reviewed the complete source and diffs (`vectors.zig`, `pic.zig`, `idt.zig`, `main.zig`, `tests/vector_policy_test.zig`, `build.zig`, `.agents/rules/05-interrupt-and-abi.md`, `docs/ARCHITECTURE.md`, `docs/TESTING_POLICY.md`), issuing source-level `PASS` dispositions for `F-03` (`4b3ea6f`), `F-03-R1` (`184784d`), and `F-03-R2` (`697f1ff`). Gemini 4 Argon remained unavailable due to quota exhaustion for `v1.9`–`v2.1`, and ChatGPT did **not** independently execute tests, builds, or QEMU. |
| **ELF & ISO Binary Inspection (`c10c05f`, `515aa91`, `7711468`, `b3cf68b`, `c1ef192`, `0092cf3`, `6aa895d`, & `697f1ff`)** | **Historical Hashes Inspected / `6aa895d` & `697f1ff` Disassembly & Hashes Implementation-Agent-Reported (Not Independently Run by ChatGPT or Argon)** | `sha256sum`, `xorriso -extract`, `readelf -h -l -S -d`, `nm -n`, `objdump -d -M intel`, `df -T` | At `c10c05f`, confirmed `/boot/kernel.elf` inside `build/zig-os.iso` matched `zig-out/bin/kernel.elf` (`19e69d10...`), 3 `PT_LOAD` segments (`R E`, `R`, `RW`), orphan `.got` section, Limine request ordering, and 6,904 `xmm` / 2,274 `movaps` instructions. Through `6aa895d` and at `697f1ff` (across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`), implementation agent (Hydrogen) reported `0` prohibited SIMD/x87 matches in `zig-out/bin/kernel.elf` via `objdump -d -M intel`. Historical `0092cf3` `ReleaseSafe` SHA-256 hashes were verified (`4db29119...` ELF / `f283df73...` ISO) and `6aa895d` hashes were agent-reported; at `697f1ff`, implementation agent (Hydrogen) reported `Debug` (`4f04b87e2bcc68832bc018e1dc7d2b5943452fb85ec24b730b555814f36d1ba0` ELF; `b9ac5388939be188cb51609c64dea7ca227a82a97285fd54d944e7018bb31190` ISO) and `ReleaseSafe` (`074a0ff28228d2f306c597ee71b821cdd585cee8957e88514cf7955ebf812211` ELF; `e9a06d4c1994d2981211f0d7335b85e43b917c471e2c4549fa07f1e54efd4157` ISO) artifacts with 3-way ELF SHA-256 provenance verification (ChatGPT did not independently execute builds or hash checks). |
| **Host Unit Tests (`c10c05f` vs. `b3cf68b`, `c1ef192`, `0092cf3`, `6aa895d`, & `697f1ff`)** | **Test Graph & Scanner Source-Reviewed / Execution Implementation-Agent-Reported (Not Independently Run by ChatGPT or Argon)** | `zig build test -Doptimize=<mode> --cache-dir <tmp> --summary all` across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall` | At `c10c05f`, `5/5` tests passed against local duplicate functions in `tests/unit_test.zig`. At `697f1ff` (expanding from `56/56` at `6aa895d`), `zig build test` wires five host test targets importing production modules with zero duplicate algorithms: `unit_test` (`tests/unit_test.zig`, **9** pure tests including `F-15` CR0/CR4 checks via `sse.zig`), `pmm_test` (`tests/pmm_test.zig` importing `physical_core.zig`, **16** stateful PMM tests), `vmm_test` (`tests/vmm_test.zig` importing `virtual_core.zig`, **10** stateful VMM tests), `heap_test` (`tests/heap_test.zig` importing `heap_core.zig`, **21** stateful Heap tests: `Heap 01`–`Heap 21`), and `vector_policy_test` (`tests/vector_policy_test.zig` importing `vectors.zig` + `build_options`, **11** vector-policy & static forbidden-`INT` scanner tests: `vectors 1`–`vectors 5`, `scanner 1`–`scanner 6`). Implementation agent (Hydrogen) reported **67/67** host unit tests passing in all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) and **0** live `kernel/` scanner hits; ChatGPT source-reviewed `vector_policy_test.zig` and `build.zig` wiring across `4b3ea6f`/`184784d`/`697f1ff` but did **not** independently execute host tests. **Environment note:** Host tests validate pure `vectors.zig`/`sse.zig` policies and static `.zig`/`.s`/`.asm`/preprocessed-`.S` scanning on the host without executing privileged Ring 0 `CR0`/`CR4`, PIC port I/O, `lidt`, or hardware/software interrupts. |
| **Build, Provenance, & QEMU Boot Verification (`c10c05f` vs. `7711468`, `c1ef192`, `0092cf3`, `6aa895d`, & `697f1ff`)** | **Implementation-Agent-Reported (Not Independently Run by ChatGPT or Argon)** | `zig build -Doptimize=<mode>`, `bash scripts/test-boot.sh --optimize Debug`, `python3 tests/test_boot.py --optimize ReleaseSafe` | At `697f1ff`, implementation agent (Hydrogen) reported clean freestanding `kernel.elf` builds across all 4 optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`), passing `Debug` (`4f04b87e...` ELF; `b9ac5388...` ISO) and `ReleaseSafe` (`074a0ff2...` ELF; `e9a06d4c...` ISO) ISO builds with 3-way kernel ELF SHA-256 provenance verification, and passing headless QEMU boot smoke tests emitting Ring 0 markers `[CPU] SSE/CR0.TS initialization verified.`, `[PIC] Legacy 8259 PIC remapped to 0x20-0x2F and masked (0xFF/0xFF).`, and `[IDT] 256 interrupt gates configured and verified.` alongside `pmm.testPmm()`, `vmm.testVmm()`, `heap.testHeap()`, and `zig-os:~$`. ChatGPT did **not** independently execute builds or QEMU. **Provenance & Environment Boundary:** `cpu.testSseCr0Init()`, `pic.remapAndMask()`, `idt.validateExceptionGates()`, `idt.testExceptionDispatch()`, `idt.testPageFaultHandling()`, `pmm.testPmm()`, `vmm.testVmm()`, and `heap.testHeap()` execute under Ring 0 inside QEMU; however, synthetic edge cases (`sse.zig` exhaustive synthetic `CR0` inputs, `vector_policy_test` synthetic `.S`/`.equ`/escaped-string traps, `Heap 15`–`Heap 21`, 64 TiB MMIO exclusion, `freePages()` atomicity, `F-16` bitmap edges, `F-09` huge-page conflicts, and `F-13` `Flags.USER` promotion) rely on host unit/static/fake-backend tests rather than dedicated QEMU fault injection. |

---

## 3. Summary of Findings

### 3.1 Count by Verification Status

| Status Category | Count | Finding IDs |
|---|---:|---|
| **VERIFIED** | **4** | `F-04`, `F-17`, `F-18`, `F-20` |
| **LIKELY** | **1** | `F-19` |
| **NEEDS_RUNTIME_VERIFICATION** | **0** | None |
| **REJECTED** | **9** | `R-01`, `R-02`, `R-03`, `R-04`, `R-05`, `R-06`, `R-07`, `R-08` (formerly `F-05`), `R-09` (formerly `F-02`) |
| **FIXED** | **13** | `F-01` (at `515aa91`: `cpu_features_sub`/`cpu_features_add` in `build.zig`), `F-03` (at `4b3ea6f`/`184784d`/`697f1ff`: `vectors.zig` reserved-vector & software-`INT` policy, `pic.zig` 8259 remap to `0x20`–`0x2F` & `0xFF`/`0xFF` masking, `idt.validateExceptionGates()` `0x8E`/CS/distinct-stub checks, `_start()` boot wiring, and fail-closed + `.S`-preprocessed `vector_policy_test` static scanner), `F-06` (at `18dabd7`/`0092cf3`: `BlockHeader.align_offset` exact-pointer check in `heap_layout.zig`/`heap_core.zig`), `F-07` (at `c1ef192`: RAM-backed `RegionKind.contributesToHighestAddress()` ceiling calculation in `physical_core.zig`), `F-08` (at `c1ef192`: `< 1 MiB`, page-rounded bitmap, and `.usable` validation in `freePage()`/atomic `freePages()`, value-stored `RegionSource`, and static `limine_region_ctx`), `F-09` (at `0156e91`: 1 GiB/2 MiB `Flags.HUGE` conflict checks in `virtual_core.zig`), `F-10` (across `9df21f8`, `bc2efdb`, `0156e91`, `b3cf68b`: `F-10A` pure modules + `F-10B` stateful PMM, VMM, and Heap cores wired into `zig build test`), `F-11` (at `18dabd7`/`0092cf3`: alignment-aware expansion sizing, coalesced free-tail deficit calculation, batch clamping, partial-expansion retry, and checked `init()`/`tryInit()`), `F-12` (at `18dabd7`/`0092cf3`: checked size/split/range/deallocate arithmetic, nonzero non-power-of-two rejection, `align=0` -> 16-byte default compatibility, and corrupted-metadata guards), `F-13` (at `0156e91`: 48-bit canonicality, 4 KiB alignment, and parent `Flags.USER` propagation in `virtual_core.zig`), `F-14` (at `7711468`: unconditional fresh build, non-recursive graph, `ReleaseSafe` default, and 3-way ELF SHA-256 provenance verification), `F-15` (at `6aa895d`: `sse.zig` pure `computeSseCr0()`/`computeSseCr4()`/`isSseCr0Valid()`/`isSseCr4Valid()` helpers clearing `CR0.EM` & `CR0.TS` and setting `CR0.MP` & `CR4.OSFXSR`/`CR4.OSXMMEXCPT`, wired into `cpu.enableSse()`, Ring 0 `cpu.testSseCr0Init()`, and host `unit_test`), `F-16` (at `c1ef192`: `>= 1 MiB` page-aligned bitmap placement, page-rounded fit, and full backing-page reservation in `physical_core.zig`) |

### 3.2 Severity Distribution (Active Findings: 5 Total)

| Severity | Count | Finding IDs |
|---|---:|---|
| **CRITICAL** | **0** | None |
| **HIGH** | **0** | None |
| **MEDIUM** | **1** | `F-04` |
| **LOW** | **2** | `F-18`, `F-19` |
| **INFORMATIONAL** | **2** | `F-17`, `F-20` |

### 3.3 Priority Distribution (`P0`–`P3`: 5 Active Findings)

| Priority | Count | Finding IDs |
|---|---:|---|
| **P0 — Must fix before further kernel development** | **0** | None (`F-01`, `F-10`, and `F-14` are `FIXED`) |
| **P1 — Must fix before Phase 2 authorization** | **1** | `F-04` (`F-03`, `F-06`, `F-07`, `F-08`, `F-09`, `F-11`, `F-12`, `F-13`, and `F-15` are `FIXED`) |
| **P2 — Important hardening that can follow** | **1** | `F-19` (`F-16` is `FIXED`) |
| **P3 — Future improvements** | **3** | `F-17`, `F-18`, `F-20` |

---

## 4. Finding Register (`F-01`–`F-20`)

> **Source Version Note:** Findings were originally audited at baseline commit `c10c05f1f37aacfda5046480a314f29d940b67ef` (`2026-11-10`) and updated through current implementation snapshot `697f1ff58a031422da41645b0ba4a422e576281a` (`2026-11-13`, incorporating `515aa91` for `F-01`, `9df21f8` for `F-10A`, `7711468` for `F-14`, `bc2efdb` for `F-10B` Part 1 PMM, `0156e91` for `F-10B` Part 2 VMM + `F-09`/`F-13`, `b3cf68b` for `F-10B` Part 3 Heap, `c1ef192` for PMM hardening `F-07`/`F-08`/`F-16`, `18dabd7`/`0092cf3` for heap hardening `F-06`/`F-11`/`F-12`, `6aa895d` for `F-15` `CR0.TS` initialization fix, and `4b3ea6f`/`184784d`/`697f1ff` for `F-03` interrupt vector protection and fail-closed/preprocessed static `INT` scanning). Historical IDs `F-02` and `F-05` are retained in place with `Status: REJECTED` and cross-referenced to `R-09` and `R-08` in Section 5 to preserve full audit traceability.

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

**Status:** FIXED (Independent Source & Diff Reviews by ChatGPT: `PASS` at Commits `4b3ea6fcb2fd1c3c03ff57b530bace20012b68b8` [F-03], `184784ddf7596cc8aa330a6856eaed7a9cd804ad` [F-03-R1], & `697f1ff58a031422da41645b0ba4a422e576281a` [F-03-R2]; `67/67` 4-Mode Host Tests, 4-Mode Builds, `0` SIMD/x87 Matches, `0` Live Scanner Hits, and `Debug`/`ReleaseSafe` QEMU Ring 0 Execution Implementation-Agent-Reported)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Interrupt vector policy & gate validator ([`kernel/src/arch/x86_64/interrupts/vectors.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig)), legacy 8259A PIC remap/mask driver ([`kernel/src/arch/x86_64/interrupts/pic.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/pic.zig)), IDT setup & validation ([`kernel/src/arch/x86_64/idt/idt.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig)), kernel boot entry ([`kernel/src/main.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig)), host test & build wiring ([`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig), [`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig)), error-code ISR stubs ([`kernel/src/arch/x86_64/interrupts/stubs.s`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s)), and [`InterruptFrame`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34).

**Source location:**  
- [`kernel/src/arch/x86_64/interrupts/vectors.zig:1-127`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig#L1-L127)
- [`kernel/src/arch/x86_64/interrupts/pic.zig:1-94`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/pic.zig#L1-L94)
- [`kernel/src/arch/x86_64/idt/idt.zig:45-141`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig#L45-L141)
- [`kernel/src/main.zig:55-77`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L55-L77)
- [`tests/vector_policy_test.zig:1-1125`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig#L1-L1125) and [`build.zig:210-236`](file:///home/leevawn/Projects/zig-os/build.zig#L210-L236)
- Baseline defect locations preserved for traceability: [`kernel/src/arch/x86_64/interrupts/stubs.s:53-180`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/stubs.s#L53-L180) and [`kernel/src/arch/x86_64/idt/handlers.zig:6-34`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/handlers.zig#L6-L34).

**Resolution & Review Evaluation (v2.1, Commits `4b3ea6fcb2fd1c3c03ff57b530bace20012b68b8` [`F-03`], `184784ddf7596cc8aa330a6856eaed7a9cd804ad` [`F-03-R1`], & `697f1ff58a031422da41645b0ba4a422e576281a` [`F-03-R2`]):**
1. **Shared Vector Partition Policy & Gate Invariants ([`kernel/src/arch/x86_64/interrupts/vectors.zig:1-127`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig#L1-L127)):**
   - Defines architectural boundaries `IDT_ENTRY_COUNT = 256` (`L5`), `EXCEPTION_VECTOR_COUNT = 32` (`L8`), `FIRST_EXTERNAL_VECTOR = 32` (`L11`), `CONTROLLED_BREAKPOINT_VECTOR = 3` (`L14`), `LEGACY_PIC_MASTER_OFFSET = 0x20` (`L17`), `LEGACY_PIC_SLAVE_OFFSET = 0x28` (`L20`), `IDT_GATE_FLAGS_KERNEL_INTERRUPT = 0x8E` (`L38-39`), and exact hardware error-code vector set `ERROR_CODE_VECTORS = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 }` (`L42`).
   - Provides `pushesHardwareErrorCode()` (`L49-54`), `isExceptionVector()` (`L57-59`), `isExternalVectorAllowed()` (`L62-64`), `validateExternalVector()` (`L67-72`, returning `error.ReservedExceptionVector` for `0..31`), `isAllowedKernelSoftwareIntVector()`/`isForbiddenSoftwareIntVector()` (`L76-84`, allowing only controlled `#BP` vector `3` and vectors `>= 32`), `isPicOffsetValid()` (`L90-109`, requiring 8-vector alignment, `>= 32`, `<= 255`, and disjoint master/slave ranges), and `isValidKernelInterruptGate()` (`L112-127`, enforcing `0x8E`, cleared `ist` reserved bits `0xF8`, `reserved == 0`, matching kernel CS, and exact stub offset).
2. **Legacy 8259 PIC Remap & Full Masking ([`kernel/src/arch/x86_64/interrupts/pic.zig:1-94`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/pic.zig#L1-L94), [`kernel/src/main.zig:55-60`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L55-L60)):**
   - Enforces `comptime` validation via `vectors.isPicOffsetValid(LEGACY_PIC_MASTER_OFFSET, LEGACY_PIC_SLAVE_OFFSET)` (`L24-28`).
   - Before IDT activation and with interrupts disabled (`IF = 0`), `_start()` calls `pic.remapAndMask()`, which validates offsets at runtime, masks all 16 legacy IRQs (`0xFF` on `0x21`/`0xA1`), runs ICW1–ICW4 (`0x11`, `0x20`/`0x28`, `0x04`/`0x02`, `0x01`), re-masks all 16 IRQs (`0xFF`/`0xFF`), verifies IMR readback via `areAllMasked()`, halts cleanly on failure, and emits `[PIC] Legacy 8259 PIC remapped to 0x20-0x2F and masked (0xFF/0xFF).` (`main.zig:56-60`).
3. **IDT Gate Validation & Controlled `#BP`-Only Software Self-Test ([`kernel/src/arch/x86_64/idt/idt.zig:45-141`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/idt/idt.zig#L45-L141), [`kernel/src/main.zig:63-76`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L63-L76)):**
   - `idt.init()` configures all 256 gates using `vectors.IDT_ENTRY_COUNT` and `vectors.IDT_GATE_FLAGS_KERNEL_INTERRUPT` (`0x8E`).
   - Immediately after `idt.init()`, `_start()` executes `idt.validateExceptionGates()`, verifying IDTR base/limit, non-zero `isr_stub_table[i]`, `vectors.isValidKernelInterruptGate(...)` across all 256 gates against `gdt.getCs()`, and pairwise distinct stub addresses across all 32 architectural exception vectors (`0..31`), halting on failure and emitting `[IDT] 256 interrupt gates configured and verified.` (`main.zig:64-76`). `idt.testExceptionDispatch()` retains `int $3` (`CONTROLLED_BREAKPOINT_VECTOR`) only.
4. **Fail-Closed & Preprocessor-Aware Static Forbidden-`INT` Scanner ([`tests/vector_policy_test.zig:1-1125`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig#L1-L1125), [`build.zig:210-236`](file:///home/leevawn/Projects/zig-os/build.zig#L210-L236)):**
   - Wired as the 5th host test target `vector_policy_test` in `zig build test`, importing `vectors.zig` and `build_options` (`kernel_dir`, `zig_exe`), with 11 host tests (`vectors 1`–`vectors 5` and `scanner 1`–`scanner 6`).
   - **F-03-R1 (`184784d`):** Replaced silent unknown-operand skips with fail-closed `ViolationKind` (`forbidden_vector` vs. `unresolved_operand`), per-file `.equ`/`.set`/`.equiv` symbol resolution (`putSymbol`, `resolveOperandValue`) that fails closed on unresolvable symbolic `int` operands, and full Zig string literal escape decoding (`decodeZigStringLiteral`, covering `\xNN` and `\u{...}`), verified by `scanner 3 (Finding A)` (`L875`) and `scanner 4 (Finding B)` (`L938`).
   - **F-03-R2 (`697f1ff`):** Routes `.S` assembly sources (`hasScannedExtension`, `L674-681`) through `scanPreprocessedAssemblyFile` -> `preprocessAssemblyFile` (`L255-322`), invoking `zig clang -E -ffreestanding --target=x86_64-freestanding-none -x assembler-with-cpp` (failing closed with `error.PreprocessorFailed`) and tracking `# <line> "<file>"` linemarkers (`parseLinemarkerLine`, `L210-251`) in `scanAssemblyTextWithOptions` for accurate file/line provenance while skipping unused macros and preserving direct `scanAssemblyText` scanning for `.s`/`.asm` and decoded Zig inline assembly (`scanZigSource`), verified by `scanner 5 (Finding F-03-R2)` (`L998`) and live tree check `scanner 6` (`L1071`).
5. **Independent Source Review & Implementation-Agent Execution Provenance:**
   - **Independent Source & Diff Review (ChatGPT):** Reviewed complete source and diffs for `4b3ea6f` (F-03 implementation, also updating `.agents/rules/05-interrupt-and-abi.md`, `docs/ARCHITECTURE.md`, and `docs/TESTING_POLICY.md`), `184784d` (F-03-R1), and `697f1ff` (F-03-R2), issuing source-level `PASS` dispositions for all three commits. ChatGPT did **not** independently execute tests, builds, or QEMU.
   - **Agent-Reported Verification Execution (Hydrogen at `697f1ff`):**
     - **67/67** host unit tests passing across all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`), with `vector_policy_test` (`11/11`) reporting **0** live `kernel/` scanner hits alongside `unit_test` (`9`), `pmm_test` (`16`), `vmm_test` (`10`), and `heap_test` (`21`).
     - Clean freestanding `kernel.elf` builds across all four optimization modes with **0** prohibited SIMD/x87 disassembly matches.
     - `Debug` (`bash scripts/test-boot.sh --optimize Debug`: ELF `4f04b87e2bcc68832bc018e1dc7d2b5943452fb85ec24b730b555814f36d1ba0`, ISO `b9ac5388939be188cb51609c64dea7ca227a82a97285fd54d944e7018bb31190`) and `ReleaseSafe` (`python3 tests/test_boot.py --optimize ReleaseSafe`: ELF `074a0ff28228d2f306c597ee71b821cdd585cee8957e88514cf7955ebf812211`, ISO `e9a06d4c1994d2981211f0d7335b85e43b917c471e2c4549fa07f1e54efd4157`) QEMU boot smoke tests passing with 3-way ELF SHA-256 provenance verification and Ring 0 serial markers `[PIC] Legacy 8259 PIC remapped to 0x20-0x2F and masked (0xFF/0xFF).` and `[IDT] 256 interrupt gates configured and verified.`.

**Historical Evidence (Baseline `c10c05f1`):**

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

**Status:** FIXED (Independently Source-Reviewed at `0092cf37f8c26cbdcea1c1d5eba98676b2542667` by ChatGPT following `18dabd7c3f62345b4970f8a4baf3016197471e11`; Host Production-Core Regression Test `Heap 15` Across All 4 Optimization Modes Implementation-Agent-Reported Passing; Live Ring 0 `heap.testHeap()` Exercises `b2 - 8`, `b2 + 1`, and `b2 + 128` under QEMU, While Unsplit Tail-Slack Rejection Is Verified in Host Unit Tests Only)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)), block header layout ([`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig)), kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)), and heap host test suite ([`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)).

**Source location:**  
- [`kernel/src/mm/heap_layout.zig:4-22`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L4-L22)
- [`kernel/src/mm/heap_core.zig:54-72, 210-341, 386-445`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L386-L445)
- [`kernel/src/mm/heap.zig:12-15, 69-77, 177-190`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L177-L190)
- [`tests/heap_test.zig:126-174, 639-715`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L639-L715)

**Resolution & Review Evaluation (v1.9, Commits `18dabd7c` & `0092cf37f8c26cbdcea1c1d5eba98676b2542667`):**
1. **Independent Source & Diff Disposition (Reviewed by ChatGPT at `0092cf3`):**
   - **Fixed-Layout `align_offset` Field (`heap_layout.zig:4-22`):** [`BlockHeader`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L4-L13) places `padding: [3]u8 = [_]u8{ 0, 0, 0 }` followed by `align_offset: u32 = 0` immediately before `next`, enforced by `comptime` checks requiring `@sizeOf(BlockHeader) == 40`, `@alignOf(BlockHeader) == 8`, `@offsetOf(BlockHeader, "align_offset") == 20`, and `@offsetOf(BlockHeader, "next") == 24`.
   - **Allocation Tracking & Remainder Reset (`heap_core.zig:54-72, 210-341`):** [`tryAllocateFromFreeList()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L210-L341) stores `block.align_offset = align_offset_u32` on allocated blocks (including unsplit blocks carrying tail slack) while resetting `.align_offset = 0` on split remainder free blocks and on coalesced blocks in [`coalesceWithNext()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L54-L72) (with `canary == CANARY` checks).
   - **Exact-Pointer Validation & Boundary Guards (`heap_core.zig:386-445`):** [`HeapAllocator.deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L386-L445) rejects `!self.initialized` or out-of-range pointers (`error.PointerOutOfBounds`), validates every walked block's `[heap_start, current_heap_end]` address/size boundaries before testing payload containment (`error.CorruptBlockHeader`), preserves `MAGIC_USED`/`CANARY` (`error.CorruptBlockHeader`), `is_free` (`error.DoubleFree`), and `align_offset <= block.size` / `block.size - align_offset >= 16` checks, and enforces exact pointer equality `raw_addr == expected_ptr` where `expected_ptr = payload_start + block.align_offset` (returning `error.BlockHeaderNotFound` on alignment-padding, header, interior, or tail-slack pointers before mutating any state).
2. **Execution Evidence & Provenance Boundary (Implementation-Agent-Reported Only):**
   - **Host Fake-Backend Tests ([`tests/heap_test.zig:639-715`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L639-L715), `"Heap 15"` + `assertListInvariants`):** Implementation agent (Hydrogen) reported `54/54` host unit tests passing uncached across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`, including `"Heap 15"` Part A (split block rejecting `p2 - 8` padding, header interior, `p2 + 1`, `p2 + 64`, `p2 + 128`, and corrupt `align_offset` bounds with zero state mutation) and Part B (unsplit 4000@64 block rejecting `p_slack - 8` padding, `p_slack + 1`, and `p_slack + 4016` tail slack), verified against page-aligned host buffers in `FakeHeapBackend`.
   - **Kernel Build & QEMU Boot Tests ([`kernel/src/mm/heap.zig:177-190`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L177-L190)):** Implementation agent reported clean 4-mode kernel compilation (`0` `F-01` SIMD/x87 matches) and passing `Debug`/`ReleaseSafe` QEMU smoke boots executing Ring 0 `heap.testHeap()`, which verifies `core.deallocate(b2 - 8)`, `core.deallocate(b2 + 1)`, and `core.deallocate(b2 + 128)` return `error.BlockHeaderNotFound`. Unsplit tail-slack free rejection (`Heap 15` Part B) is verified in host unit tests only.

**Historical Evidence (Baseline `c10c05f1` through `c1ef192b`):**
Prior to `18dabd7c`, [`HeapAllocator.deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig) (extracted verbatim from `heap.zig` in `b3cf68b`) accepted any address within `[payload_start, payload_start + block.size)`, silently freeing allocations on alignment-padding pointers in `[payload_start, aligned_payload)`, interior pointers, or unsplit tail-slack pointers.

**Dependencies:**  
Host test harness provided by completed `F-10` (`F-10B` Part 3); arithmetic and split-bound hardening coordinated with `F-12`.

---

### [F-07] PMM `highest_address` and bitmap size are computed across all memory map entries including reserved and MMIO regions

**Status:** FIXED (Independently Source-Audited at `c1ef192b336ba548ac0acb5340d92143bdad7994` & Reviewed by ChatGPT; Host Production-Core Regression Tests `F-07` Agent-Reported Passing; 64 TiB Synthetic MMIO Exclusion Verified in Host Unit Tests Only, Live Limine Map Exercised in QEMU `pmm.testPmm()`)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)), kernel PMM adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)), and PMM host test suite ([`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:12-49`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L12-L49), [`kernel/src/mm/physical_core.zig:159-161`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L159-L161), and [`kernel/src/mm/physical_core.zig:251-274`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L251-L274)
- [`kernel/src/mm/physical_core.zig:329-386`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L329-L386)
- [`kernel/src/mm/physical.zig:51-79`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L51-L79)
- [`tests/pmm_test.zig:617-733`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L617-L733)

**Resolution & Independent Audit Evaluation (v1.8, Commit `c1ef192b336ba548ac0acb5340d92143bdad7994`):**
1. **Independently Reviewed Source Evidence:**
   - **Explicit Memory-Map Classification (`physical_core.zig:12-49`, `physical.zig:51-64`):**
     - [`RegionKind`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L13-L24) defines ten explicit hardware-independent variants: `.usable`, `.bootloader_reclaimable`, `.acpi_reclaimable`, `.executable_and_modules`, `.reserved`, `.acpi_nvs`, `.bad_memory`, `.framebuffer`, `.reserved_mapped`, and `.unknown`.
     - [`RegionKind.contributesToHighestAddress()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L28-L43) returns `true` exclusively for RAM-backed region types (`.usable`, `.bootloader_reclaimable`, `.acpi_reclaimable`, `.executable_and_modules`) and `false` for all non-RAM apertures (`.reserved`, `.acpi_nvs`, `.bad_memory`, `.framebuffer`, `.reserved_mapped`, `.unknown`).
     - [`RegionKind.isUsable()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L46-L48) returns `true` exclusively for `.usable`.
     - [`mapLimineRegionKind()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L51-L64) maps every `limine.MemmapType` variant explicitly and maps unknown firmware values (`_`) to `.unknown`.
   - **Checked Ceiling Calculation & Non-Usable Reservation (`physical_core.zig:251-274, 329-386`):**
     - In [`initWithSource()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L253-L263), `computed_highest` is accumulated only across entries where `region.kind.contributesToHighestAddress()` is `true` and `region.length > 0`, using checked addition (`std.math.add(u64, region.base, region.length) catch return error.NoUsableBitmapRegion`) and `bytesToPageCountCeil` + `std.math.cast(usize, total_pages_u64)`.
     - All bitmap bits default to `0xFF` (`USED`, `line 329`), only whole frames `>= LOW_MEMORY_LIMIT` (`0x100000`) inside `.usable` regions are cleared (`lines 331-358`), and a second pass (`lines 360-386`) defensively re-marks any frame overlapping a non-usable region as `USED`. Thus `.bootloader_reclaimable`, `.acpi_reclaimable`, and `.executable_and_modules` contribute to `highest_address` without ever becoming allocatable or freeable.
2. **Regression Test & Provenance Boundary (Host Fake-Backend vs. QEMU Runtime):**
   - **Independently Audited Host Regression Tests ([`tests/pmm_test.zig:617-733`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L617-L733)):**
     - `"F-07: high reserved, framebuffer, acpi_nvs, bad_memory, reserved_mapped, and unknown apertures do not inflate ceiling"` (`lines 617-669`): Verifies that 256 MiB `.usable` RAM (`[0x100000, 0x10100000)` and exact `[0x100000, 0x10000000)`) paired with high `.unknown` (`4 GiB`), `.reserved_mapped` (`8 GiB`), `.bad_memory` (`16 GiB`), `.acpi_nvs` (`32 GiB`), `.framebuffer` (`64 GiB` / `512 GiB`), and `.reserved` (`0x4000_0000_0000` = `64 TiB`) produces `highest_address = 0x10100000` (`total_pages = 65,792`, `bitmap.len = 8,224`) and `highest_address = 0x10000000` (`total_pages = 65,536`, `bitmap.len = 8,192`), with `freePage(0x4000_0000_0000)` returning `error.OutOfBounds`.
     - `"F-07: RAM-backed reclaimable/kernel types raise ceiling while all non-usable entries remain unallocatable"` (`lines 671-733`): Verifies `.bootloader_reclaimable`, `.acpi_reclaimable`, and `.executable_and_modules` raise `highest_address` to `0x114000` while `.reserved` at `0x2000_0000` is ignored, and draining all free pages via `allocPage()` yields only the 5 `.usable` frames.
   - **Coverage Boundary:** The 64 TiB `.reserved` MMIO aperture and synthetic multi-region permutations are verified in host unit tests (`tests/pmm_test.zig`, reported passing across all 4 optimization modes); the QEMU boot tests (`Debug` and `ReleaseSafe`) exercise the live Limine memory map via `pmm.init()` and `pmm.testPmm()`.

**Historical Evidence (Baseline `c10c05f1` through `b3cf68bb`):**
Prior to `c1ef192b`, `PhysicalAllocator.init()` computed `computed_highest` across all memory-map entries regardless of `region.kind` (`.usable` and `.non_usable`), inflating the bitmap across high `.reserved` MMIO holes.

**Dependencies:**  
Related to `F-08`, `F-10` (`F-10B` Part 1), and `F-16`.

---

### [F-08] PMM `freePage()` lacks allocatable-RAM range, reserved-region, and bitmap-overlap validation

**Status:** FIXED (Independently Source-Audited at `c1ef192b336ba548ac0acb5340d92143bdad7994` & Reviewed by ChatGPT; Host Production-Core Regression Tests `F-08` & Lifetime Tests Agent-Reported Passing; Live Ring 0 `pmm.testPmm()` Exercises `ReservedAddress`, `BitmapOverlap`, and `NotUsableRegion` on `core.freePage()`, While `freePages()` Failure-Atomicity Spans Are Verified in Host Unit Tests Only)

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)), kernel PMM adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)), and PMM host test suite ([`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:61-133`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L61-L133), [`kernel/src/mm/physical_core.zig:193-196, 222-241, 321-325`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L193-L196), and [`kernel/src/mm/physical_core.zig:492-590`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L492-L590)
- [`kernel/src/mm/physical.zig:43-50, 89-127, 156-217`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L43-L50)
- [`tests/pmm_test.zig:735-898`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L735-L898) and [`tests/pmm_test.zig:959-1049`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L959-L1049)

**Resolution & Independent Audit Evaluation (v1.8, Commit `c1ef192b336ba548ac0acb5340d92143bdad7994`):**
1. **Independently Reviewed Source Evidence:**
   - **Deterministic 6-Step `validateFreePage()` Contract (`physical_core.zig:126-133, 492-565`):**
     - [`FreeError`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L126-L133) defines `UnalignedAddress`, `OutOfBounds`, `ReservedAddress`, `BitmapOverlap`, `NotUsableRegion`, and `DoubleFree`.
     - [`validateFreePage()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L522-L549) validates in strict order before any bitmap bit or counter mutation:
       1. `paddr % PAGE_SIZE != 0` $\to$ `error.UnalignedAddress` (`lines 523-525`).
       2. `std.math.cast(usize, paddr / PAGE_SIZE)` / `frame >= self.total_pages` $\to$ `error.OutOfBounds` (`lines 527-530`).
       3. `paddr < LOW_MEMORY_LIMIT` (`0x100000`) $\to$ `error.ReservedAddress` (`lines 532-534`).
       4. `self.overlapsBitmapPage(paddr)` (`paddr < self.bitmap_end_phys and page_end > self.bitmap_phys`, where `bitmap_end_phys` is page-rounded to `bitmap_pages * PAGE_SIZE`) $\to$ `error.BitmapOverlap` (`lines 492-496, 536-538`).
       5. `!self.isPageInUsableRegion(paddr)` (requires `[paddr, paddr + PAGE_SIZE)` to be wholly contained within at least one `.usable` entry and to have zero overlap with any non-usable entry) $\to$ `error.NotUsableRegion` (`lines 498-520, 540-542`).
       6. `!self.isBitSet(frame)` $\to$ `error.DoubleFree` (`lines 544-546`).
   - **Two-Pass Atomic `freePages()` (`physical_core.zig:567-589`):**
     - Returns immediately on `count == 0`, checks `paddr % PAGE_SIZE != 0` (`UnalignedAddress`) and `start_frame >= self.total_pages or count > self.total_pages - start_frame` (`OutOfBounds`), then validates every page in `0..count` via `validateFreePage(page_paddr)` (`lines 580-584`) before calling `releaseValidatedFrame(start_frame + i)` in Pass 2 (`lines 586-588`), preventing partial frees on mixed ranges.
   - **Exhaustive Kernel Adapter Panic Mapping (`physical.zig:101-110`):**
     - [`panicOnFreeError()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L101-L110) switches exhaustively over all six `FreeError` variants without a catch-all `else`, preserving existing panic messages for `UnalignedAddress`, `OutOfBounds`, and `DoubleFree` while mapping `ReservedAddress`, `BitmapOverlap`, and `NotUsableRegion` to dedicated `@panic` diagnostics.
   - **Safe Region-Provider & Context Lifetime (`physical_core.zig:99-119, 196, 222-241`, `physical.zig:43-50, 117-127`):**
     - `PhysicalAllocator` stores `region_source: RegionSource = .none` directly by value (`union(enum) { none, slice: []const MemoryRegion, provider: RegionProvider }`), so `initFromSlice()` stores `.{ .slice = regions }` directly without any self-referential pointer to an internal struct field that would dangle if `PhysicalAllocator` is returned or copied by value.
     - In [`kernel/src/mm/physical.zig:46-49, 117-127`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L46-L49), the former stack-local `region_ctx` inside `init()` is replaced by module-static `var limine_region_ctx: LimineRegionContext`, ensuring `&limine_region_ctx` remains valid for the lifetime of the kernel while `.bootloader_reclaimable` memory remains reserved during Phase 1.
2. **Regression Test & Provenance Boundary (Host Fake-Backend vs. QEMU Runtime):**
   - **Independently Audited Host Regression Tests ([`tests/pmm_test.zig:735-898, 959-1049`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L735-L898)):**
     - `"F-08: freePage enforces low-memory (<1MiB), page-rounded bitmap overlap, and usable-region boundaries"` (`lines 735-825`): Verifies `ReservedAddress` on `0x0`, `0x1000`, `0x80000`, `0xFF000`; `BitmapOverlap` across all 3 frames (`0x100000`, `0x101000`, and partial 32-byte 3rd page `0x102000`) of an 8,224-byte bitmap; `NotUsableRegion` across all 9 non-usable `RegionKind` variants, an unmapped gap (`0x10D000`), and unaligned `.usable` boundary pages (`0x10E000`, `0x111000`), asserting zero bitmap, counter, or scan-cursor mutations via `expectFreeUnchanged`.
     - `"F-08: freePages fails atomically with zero bitmap or counter mutations"` (`lines 827-898`): Verifies zero partial frees when multi-page ranges cross from valid allocated usable pages into `.reserved`, `.bootloader_reclaimable`, bitmap frames, `< 1 MiB` frames, `usize` max count overflow, or an already-free page (`DoubleFree`).
     - `"PMM retains region source safely across helper returns, stack reuse, and reinitialization"` (`lines 959-1049`): Verifies `createAllocatorViaSliceReturn()` by-value return + `clobberStackFrame()` and `initViaProviderHelper()` reinitialization with an external `ProviderLifetimeCtx`.
   - **In-Kernel QEMU Runtime Coverage vs. Host Simulation:**
     - [`pmm.testPmm()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L186-L217) in the live Ring 0 QEMU boot path non-destructively invokes `core.freePage(0x0)` (`error.ReservedAddress`), `core.freePage(bitmap_phys)` and `core.freePage(bitmap_end_phys - PAGE_SIZE)` (`error.BitmapOverlap`), and `core.freePage(start)` on the first tracked non-usable Limine page `>= 1 MiB` (`error.NotUsableRegion`).
     - Multi-page `freePages()` failure-atomicity boundary permutations and stack-clobber/by-value return lifetime tests are verified in host unit tests (`tests/pmm_test.zig`), not under QEMU.

**Historical Evidence (Baseline `c10c05f1` through `b3cf68bb`):**
Prior to `c1ef192b`, `freePage()` checked only page alignment, `frame >= total_pages`, and `!isBitSet(frame)`, allowing `< 1 MiB`, bitmap, and non-usable frames (whose bits are `1`) to be freed into the allocatable pool, and `physical.init()` passed a stack-local `&region_ctx` to `core.init()`.

**Dependencies:**  
Related to `F-07`, `F-10` (`F-10B` Part 1), and `F-16`.

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

**Status:** FIXED (Independently Source-Audited across `9df21f8b1e6bb4f26d4ab3ffe7bc88b7a6c656e6`, `bc2efdb0e673a6086f59e5ad0ca1669216f8c604`, `0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`, `b3cf68bbfc659be339b24cf8b3110be7eb159b53`, and `c1ef192b336ba548ac0acb5340d92143bdad7994`; Extended at `18dabd7`/`0092cf3` [`54/54`], `6aa895d` [`56/56`], and `4b3ea6f`/`184784d`/`697f1ff` [`67/67` Across All 4 Optimization Modes and `Debug`/`ReleaseSafe` QEMU Smoke Tests, Implementation-Agent-Reported; `sse.zig`, `vectors.zig`, & `vector_policy_test.zig` Wiring Source-Reviewed by ChatGPT])

**Severity:** HIGH (Resolved)

**Confidence:** HIGH

**Affected component:**  
Build test graph ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig)), shared pure production modules ([`kernel/src/mm/paging_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig), [`kernel/src/mm/physical_math.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig), [`kernel/src/arch/x86_64/interrupts/page_fault.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig), [`kernel/src/mm/heap_layout.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig), [`kernel/src/arch/x86_64/sse.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/sse.zig), [`kernel/src/arch/x86_64/interrupts/vectors.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig)), shared stateful production cores and kernel adapters ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig), [`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig), [`kernel/src/mm/virtual_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig), [`kernel/src/mm/virtual.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig), [`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig), [`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)), and host unit test targets ([`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig), [`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig), [`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig), [`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig), [`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig)).

**Source location:**  
- [`build.zig:123-237`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L237)
- [`kernel/src/mm/paging_math.zig:1-24`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/paging_math.zig#L1-L24), [`kernel/src/mm/physical_math.zig:1-29`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_math.zig#L1-L29), [`kernel/src/arch/x86_64/interrupts/page_fault.zig:1-20`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/page_fault.zig#L1-L20), [`kernel/src/mm/heap_layout.zig:1-14`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_layout.zig#L1-L14), [`kernel/src/arch/x86_64/sse.zig:1-44`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/sse.zig#L1-L44), [`kernel/src/arch/x86_64/interrupts/vectors.zig:1-127`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/interrupts/vectors.zig#L1-L127)
- [`kernel/src/mm/physical_core.zig:1-596`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L1-L596) and [`kernel/src/mm/physical.zig:1-253`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L1-L253)
- [`kernel/src/mm/virtual_core.zig:1-285`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L1-L285) and [`kernel/src/mm/virtual.zig:1-172`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L1-L172)
- [`kernel/src/mm/heap_core.zig:1-299`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L1-L299) and [`kernel/src/mm/heap.zig:1-175`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L1-L175)
- [`tests/unit_test.zig:1-289`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L1-L289), [`tests/pmm_test.zig:1-1049`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L1-L1049), [`tests/vmm_test.zig:1-780`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L1-L780), [`tests/heap_test.zig:1-631`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L1-L631), and [`tests/vector_policy_test.zig:1-1125`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig#L1-L1125)

**Resolution & Independent Audit Evaluation (v1.7–v2.1, Extended through Snapshot `697f1ff58a031422da41645b0ba4a422e576281a`):**
1. **Completed `F-10A` & Pure Policy Modules (`sse.zig`, `vectors.zig`; `9df21f8`, Extended at `6aa895d` & `4b3ea6f`):**
   - Extracted `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, and `heap_layout.zig` at `9df21f8` (`7` host tests), added `sse.zig` (`F-15`) at `6aa895d` (`2` CR0/CR4 tests in [`tests/unit_test.zig:6-10`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L6-L10)), and added `vectors.zig` (`F-03`) at `4b3ea6f` (imported directly by `pic.zig`, `idt.zig`, and [`tests/vector_policy_test.zig:2`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig#L2) across 5 pure vector/gate tests + 6 static `INT` scanner tests), producing hardware-independent production modules shared with the freestanding kernel with zero duplicated helper definitions.
2. **Completed `F-10B` Part 1 & PMM Hardening — Stateful PMM Core (`bc2efdb0e673a6086f59e5ad0ca1669216f8c604`, `c1ef192b336ba548ac0acb5340d92143bdad7994`):**
   - [`kernel/src/mm/physical_core.zig:1-596`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L1-L596) implements `PhysicalAllocator` (`init`, `initFromSlice`, `allocPage`, `allocPages`, `freePage`, `freePages`, `isPageAllocated`) parameterized by `RegionProvider` / `RegionSource`, `BitmapProvider`, and `PageZeroer`, with zero Limine or HHDM dependencies.
   - [`kernel/src/mm/physical.zig:1-253`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L1-L253) binds `PhysicalAllocator` to `limine.hhdm_request`, `limine.memmap_request` (via module-static `limine_region_ctx` and `mapLimineRegionKind()`), `physToVirt`, and the kernel `@panic` contracts while synchronizing all public PMM globals via `syncGlobals()`.
   - [`tests/pmm_test.zig:1-1049`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L1-L1049) imports `@import("physical_core")` (`build.zig:155-169`) and runs 16 stateful host tests against `physical_core.PhysicalAllocator` using `FakeMemoryBackend` (10 foundational tests from `bc2efdb` plus 6 `F-07`/`F-08`/`F-16`/lifetime regression tests added at `c1ef192`).
3. **Completed `F-10B` Part 2 — Stateful VMM Core (`0156e9102b22a30e3d31e7b09d16dd2f1a3f58b6`):**
   - [`kernel/src/mm/virtual_core.zig:1-285`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual_core.zig#L1-L285) implements `mapPage`, `unmapPage`, `virtToPhys`, `isMapped`, `isCanonical`, `PageTable`, `Flags`, `MapError`, and `UnmapError` over an injected `Backend` (`resolveTableFn`, `allocTableFn`, `freeTableFn`, `invlpgFn`), with zero privileged `CR3` or `invlpg` instructions in the core.
   - [`kernel/src/mm/virtual.zig:1-172`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/virtual.zig#L1-L172) binds `virtual_core` to `cpu.readCr3()`, `pmm.physToVirt()`, `pmm.allocPage()`, `pmm.freePage()`, and `cpu.invlpg()`.
   - [`tests/vmm_test.zig:1-780`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig#L1-L780) imports `@import("virtual_core")` (`build.zig:172-186`) and runs 10 stateful host tests (`VMM A`–`VMM J`, including `F-09` and `F-13` regressions) against `virtual_core` using `FakeVmmBackend` (with `0xA5A5...` poisoned page-table slots).
4. **Completed `F-10B` Part 3 — Stateful Heap Core (`b3cf68bbfc659be339b24cf8b3110be7eb159b53`):**
   - [`kernel/src/mm/heap_core.zig:1-299`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L1-L299) imports `BlockHeader` and `HEADER_SIZE` from `heap_layout.zig` and implements `HeapAllocator` (`create`, `mappedBytes`, `init`, `expandHeap`, `allocate`, `deallocate`, `allocator`, `allocator_vtable`), `PageMapper`, and `FreeError` over configurable `heap_start` and `heap_max_size`.
   - [`kernel/src/mm/heap.zig:1-175`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L1-L175) binds `HeapAllocator` (`HEAP_START`, `HEAP_MAX_SIZE`) to `vmm.getActivePml4()`, `pmm.allocPage()`, `vmm.mapPage(..., vmm.Flags.WRITABLE)`, and `pmm.freePage()`, preserving all public globals (`current_heap_end`, `head_block`, `initialized`, `total_allocated_bytes`, `total_freed_bytes`), `init`, `allocate`, `deallocate`, `vtable`, `allocator`, `testHeap`, and `@panic` strings.
   - [`tests/heap_test.zig:1-631`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L1-L631) imports `@import("heap_core")` (`build.zig:189-203`) and runs 14 stateful host tests (`Heap 01`–`Heap 14`) against `heap_core.HeapAllocator` over page-aligned host buffers (`FakeHeapBackend`) (later extended to 21 tests at `18dabd7`/`0092cf3`).
5. **Unified `zig build test` Target Architecture (`build.zig:123-237`):**
   - `unit_test_step` (`b.step("test", "Run host unit tests")`) depends on all five test artifacts (`run_unit_tests` [**9** tests in `tests/unit_test.zig` at `6aa895d`, expanded from 7], `run_pmm_tests` [**16** tests in `tests/pmm_test.zig`], `run_vmm_tests` [**10** tests in `tests/vmm_test.zig`], `run_heap_tests` [**21** tests in `tests/heap_test.zig` at `0092cf3`, expanded from 14 at `b3cf68b`], and `run_vector_policy_tests` [**11** tests in `tests/vector_policy_test.zig` across `4b3ea6f`/`184784d`/`697f1ff`]) for an aggregate of **67 host unit tests** (note that stateful and interrupt-policy/scanner tests reside in dedicated `pmm_test.zig`, `vmm_test.zig`, `heap_test.zig`, and `vector_policy_test.zig` targets wired into `zig build test` rather than inside `tests/unit_test.zig`).
   - **Provenance Boundary:** Source architecture through `c1ef192b` was independently audited by Argon; `18dabd7`/`0092cf3` heap additions (`54/54` tests), `6aa895d` `sse.zig`/`unit_test` wiring (`56/56` tests), and `4b3ea6f`/`184784d`/`697f1ff` `vectors.zig`/`vector_policy_test`/`build.zig` additions (`67/67` tests) were independently source-reviewed by ChatGPT. ChatGPT did **not** execute tests, builds, or QEMU; execution of `67/67` host tests across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`, 4-mode kernel compilation, `F-01` disassembly (`0` matches), `0` live `kernel/` scanner hits, and `Debug`/`ReleaseSafe` QEMU smoke tests are implementation-agent-reported.

**Historical Evidence (Baseline `c10c05f1`):**
At baseline `c10c05f1`, `tests/unit_test.zig` duplicated 5 pure helpers/structs locally with zero `@import` edges into `kernel/src/`, and stateful PMM, VMM, and Heap algorithms were coupled directly to Limine globals, HHDM pointers, `HEAP_START`, and privileged CPU instructions (`CR3`, `invlpg`).

**Dependencies:**  
Provides the host unit test foundation for memory-management findings `F-06`–`F-09`, `F-11`–`F-13`, `F-16`, and `F-17`.

---

### [F-11] Heap `allocate()` omits alignment padding in `pages_needed` and ignores partial expansion progress in `expandHeap()`

**Status:** FIXED (Independently Source-Reviewed at `0092cf37f8c26cbdcea1c1d5eba98676b2542667` by ChatGPT following `18dabd7c3f62345b4970f8a4baf3016197471e11`; Host Production-Core Regression Tests `Heap 16`–`Heap 18` & Exact-Sequence `Heap 20` Across All 4 Optimization Modes Implementation-Agent-Reported Passing; Host Fake-Backend Coverage Only — Exact 9-Page/Partial-Failure/Init-Retry Permutations Not Triggered Under Normal QEMU Boot)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)), kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)), and heap host test suite ([`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)).

**Source location:**  
- [`kernel/src/mm/heap_core.zig:16-20, 48-52, 103-208, 343-384`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L103-L208)
- [`kernel/src/mm/heap.zig:14, 47-61`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L47-L61)
- [`tests/heap_test.zig:717-902, 955-990`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L955-L990)

**Resolution & Review Evaluation (v1.9, Commits `18dabd7c` & `0092cf37f8c26cbdcea1c1d5eba98676b2542667`):**
1. **Independent Source & Diff Disposition (Reviewed by ChatGPT at `0092cf3`):**
   - **Alignment- & Tail-Aware Expansion Sizing (`heap_core.zig:48-52, 172-208`):** [`coalescingFreeTail()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L172-L187) detects whether the last block is a valid free block whose payload cleanly terminates at `current_heap_end`. [`pagesNeededForExpansion()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L189-L208) computes the exact alignment offset (`alignUpChecked(payload_addr, align_val_u64) - payload_addr`) either from the free tail block's payload (`deficit = total_needed - tail.size`) or from `current_heap_end + HEADER_SIZE` when starting a new trailing block, and rounds up via overflow-safe [`ceilDivU64()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L48-L52).
   - **Clamped Batch Expansion & Partial-Progress Retry (`heap_core.zig:362-383`):** [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L362-L383) verifies `pages_needed <= remaining_pages`, clamps the batch request with `@min(@max(pages_needed, @as(u64, 4)), remaining_pages)` so small remaining headroom (e.g., 2 pages) is mapped cleanly without over-requesting 4 pages, records `end_before = self.current_heap_end`, and retries [`tryAllocateFromFreeList()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L210-L341) non-recursively whenever `expanded_full or self.current_heap_end > end_before`.
   - **Checked Initialization & Partial-Init Resumption (`heap_core.zig:16-20, 106-127`, `heap.zig:14, 47-61`):** [`HeapAllocator.init()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L106-L127) returns `InitError!void` (`InvalidInitialPageCount`, `CapacityExceeded`, `ExpansionFailed`), rejecting zero or over-capacity page counts and leaving `self.initialized = false` (preserving already-mapped pages at `current_heap_end`/`head_block`) if `expandHeap()` fails partway so retries map only `initial_pages_u64 - already_mapped_pages` without remapping earlier virtual addresses. [`kernel/src/mm/heap.zig:47-61`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L47-L61) exposes `tryInit()` and keeps `pub fn init(initial_pages: usize) void` synchronized with explicit `@panic` messages on `InitError`.
2. **Execution Evidence & Provenance Boundary (Implementation-Agent-Reported Only):**
   - **Host Fake-Backend Regression Tests (`tests/heap_test.zig:717-902, 955-990`):** Implementation agent (Hydrogen) reported `54/54` uncached host tests passing across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`:
     - [`"Heap 20"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L955-L990) reproduces the exact documented F-11 sequence (`heap.init(4)` $\to$ `allocate(16320, 16)` $\to$ `allocate(16336, 64)`), verifying the second allocation succeeds cleanly by mapping **5 additional pages (9 total pages)** in one expansion without repeated expansion, preserving alignment, payload integrity, list invariants, and single-block coalescing on free.
     - [`"Heap 16"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L717-L785), [`"Heap 17"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L787-L851), and [`"Heap 18"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L853-L902) cover `16320@128`, coalescing-tail 1-page tight fit, 2-page remaining headroom clamping, partial-expansion success/non-recursive OOM preservation, and `init(0)`/`CapacityExceeded`/partial-`init` retry without remapping.
   - **Kernel Build & QEMU Boot Tests:** Implementation agent reported clean 4-mode kernel builds (`0` SIMD/x87 matches) and passing `Debug`/`ReleaseSafe` QEMU smoke boots executing `heap.init(4)` and `heap.testHeap()` (`[HEAP] Dynamic memory allocator initialized and verified.`); synthetic multi-page expansion/partial-failure/init-retry permutations are verified in host fake-backend unit tests only.

**Historical Evidence (Baseline `c10c05f1` through `c1ef192b`):**
Prior to `18dabd7c`, `allocate()` computed `pages_needed = (aligned_size + HEADER_SIZE + page_size_usize - 1) / page_size_usize` without `align_offset` or tail accounting, passed `@max(pages_needed, 4)` unconditionally, retried only on full `expandHeap() == true`, and `_ = self.expandHeap(initial_pages)` in `init()` ignored expansion failure while unconditionally setting `self.initialized = true`.

**Dependencies:**  
Related to `F-12`; host test harness provided by completed `F-10` (`F-10B` Part 3).

---

### [F-12] Unchecked integer arithmetic overflow and missing power-of-two `alignment` validation in `heap.allocate()`

**Status:** FIXED (Independently Source-Reviewed at `0092cf37f8c26cbdcea1c1d5eba98676b2542667` by ChatGPT; Host Production-Core Regression Tests `Heap 19` & `Heap 21` Across All 4 Optimization Modes Implementation-Agent-Reported Passing; Live Ring 0 `heap.testHeap()` Exercises `align=0` Compatibility and `maxInt(usize)` / `3` / `24` / `HEAP_MAX_SIZE * 2` Non-Mutation Under QEMU, While Corrupted Metadata Guards Are Verified in Host Unit Tests Only)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Kernel heap allocator core ([`kernel/src/mm/heap_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig)), kernel heap adapter ([`kernel/src/mm/heap.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig)), and heap host test suite ([`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)).

**Source location:**  
- [`kernel/src/mm/heap_core.zig:41-52, 210-384, 386-445`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L210-L445)
- [`kernel/src/mm/heap.zig:192-210`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L192-L210)
- [`tests/heap_test.zig:904-953, 992-1033`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L904-L1033)

**Resolution & Review Evaluation (v1.9, Commits `18dabd7c` & `0092cf37f8c26cbdcea1c1d5eba98676b2542667`):**
1. **Independent Source & Diff Disposition (Reviewed by ChatGPT at `0092cf3`):**
   - **Compatibility-Preserving Alignment Validation (`heap_core.zig:346-352`):** [`HeapAllocator.allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L343-L357) rejects nonzero non-power-of-two alignments via `if (alignment != 0 and !std.math.isPowerOfTwo(alignment)) return null;` (rejecting inputs such as `3` and `24`), while **preserving compatibility for `alignment == 0`**, which evaluates through `const align_val_usize: usize = @max(alignment, 16);` to the default 16-byte System V ABI alignment (`0`, `1`, `2`, `4`, `8`, and `16` all enforce 16-byte minimum alignment). `align_val_u64 > self.heap_max_size` returns `null` prior to list traversal.
   - **Checked Sizing & Expansion Arithmetic (`heap_core.zig:41-52, 353-384`):** Added overflow-checked [`alignUpChecked()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L41-L46) and [`ceilDivU64()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L48-L52). [`allocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L354-L356) computes `aligned_size_u64 = alignUpChecked(size, 16)` and checks `aligned_size_u64 <= self.heap_max_size` before traversing blocks or expanding backing memory, guaranteeing invalid requests perform zero heap state mutations.
   - **Checked Free-List Split & Deallocate Boundary Arithmetic (`heap_core.zig:210-341, 386-445`):** In [`tryAllocateFromFreeList()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L210-L341), block header bounds `[heap_start, current_heap_end)`, `block_end = payload_addr + block.size <= current_heap_end`, `user_end = aligned_payload + aligned_size <= block_end`, split address arithmetic (`split_addr`, `split_header_end`, `split_block_end` completely inside `[heap_start, current_heap_end)` and `[payload_addr, block_end]`), and `total_allocated_bytes + allocated_block_size` are all validated with `std.math.add`/`std.math.cast` **before** `@ptrFromInt` or any mutation to `block.next`, `block.prev`, `n.prev`, `block.size`, or accounting counters. [`deallocate()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap_core.zig#L386-L445) likewise validates walked block ranges against `[heap_start, current_heap_end]`, casts `block.align_offset`, checks `payload_start`, `expected_ptr`, and `total_freed_bytes + block.size` via checked arithmetic before mutating state, without weakening `MAGIC_USED`, `CANARY`, or `DoubleFree` checks.
2. **Execution Evidence & Provenance Boundary (Implementation-Agent-Reported Only):**
   - **Host Fake-Backend Regression Tests (`tests/heap_test.zig:904-953, 992-1033`):** Implementation agent (Hydrogen) reported `54/54` uncached host unit tests passing across `Debug`, `ReleaseSafe`, `ReleaseFast`, and `ReleaseSmall`:
     - [`"Heap 19"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L904-L953) explicitly verifies `allocate(64, 0)` succeeds with a 16-byte-aligned pointer, reads/writes/frees cleanly, tests valid powers of two `{0, 1, 2, 4, 8, 16, 32, 64, 256}`, and verifies `0`-size, `maxInt(usize)`, `maxInt(usize) - 7`, nonzero non-power-of-two alignments `3` and `24`, `maxSize() * 2`, `maxSize()`, and `maxSize() - HEADER_SIZE + 16` all return `null` with zero mutation to `mapped_pages`, `map_calls`, `total_allocated_bytes`, `total_freed_bytes`, `current_heap_end`, block count, or poisoned unmapped pages.
     - [`"Heap 21"`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig#L992-L1033) verifies corrupted free/used `block.size` metadata exceeding mapped heap bounds is rejected in `allocate()` and `deallocate()` with zero mutation to free-list links or byte counters.
   - **Kernel Build & QEMU Boot Tests ([`kernel/src/mm/heap.zig:192-210`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/heap.zig#L192-L210)):** Implementation agent reported clean 4-mode kernel compilation (`0` `F-01` matches) and passing `Debug`/`ReleaseSafe` QEMU smoke boots running Ring 0 `heap.testHeap()`, which verifies `allocate(64, 0)` succeeds with 16-byte alignment and verifies `maxInt(usize)`, `3`, `24`, and `HEAP_MAX_SIZE * 2` fail without mutating `total_allocated_bytes` or `current_heap_end`. Corrupted metadata injection (`Heap 21`) is host-test only.

**Historical Evidence (Baseline `c10c05f1` through `18dabd7c`):**
Prior to `18dabd7c`, `allocate()` performed unchecked `size + 15`, `payload_addr + align_val - 1`, and `aligned_size + align_offset` arithmetic and lacked `isPowerOfTwo` checks. Commit `18dabd7c` added checked sizing and power-of-two validation, while temporarily rejecting `alignment == 0`; corrective commit `0092cf3` restored `alignment == 0` -> 16-byte compatibility and added checked split-address, block-range, and `deallocate()` boundary guards.

**Dependencies:**  
Related to `F-06` and `F-11`; host test harness provided by completed `F-10` (`F-10B` Part 3).

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

**Status:** FIXED (Independent Source & Diff Review by ChatGPT: `PASS / FIXED` at Commit `6aa895d419843b106d9773a8b375c501f1530095`; `56/56` 4-Mode Host Unit Tests, 4-Mode Builds, `F-01` Disassembly, and `Debug`/`ReleaseSafe` QEMU Ring 0 Regression Execution Implementation-Agent-Reported)

**Severity:** MEDIUM (Resolved)

**Confidence:** HIGH

**Affected component:**  
Pure SSE control-register helpers ([`kernel/src/arch/x86_64/sse.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/sse.zig)), CPU control register initialization ([`kernel/src/arch/x86_64/cpu.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig)), kernel entry sequence ([`kernel/src/main.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig)), host test wiring ([`build.zig`](file:///home/leevawn/Projects/zig-os/build.zig), [`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig)), and Limine base-revision contract ([`kernel/src/limine.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig)).

**Source location:**  
- [`kernel/src/arch/x86_64/sse.zig:1-44`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/sse.zig#L1-L44)
- [`kernel/src/arch/x86_64/cpu.zig:1-3, 119-170`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L119-L170)
- [`kernel/src/main.zig:17-45`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L17-L45)
- [`build.zig:149-153`](file:///home/leevawn/Projects/zig-os/build.zig#L149-L153)
- [`tests/unit_test.zig:10, 225-289`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig#L225-L289)
- [`kernel/src/limine.zig:8-12`](file:///home/leevawn/Projects/zig-os/kernel/src/limine.zig#L8-L12)

**Resolution & Review Evaluation (v2.0, Commit `6aa895d419843b106d9773a8b375c501f1530095`, `fix(cpu): clear CR0.TS during SSE initialization (F-15)`):**
1. **Production Helper Design ([`kernel/src/arch/x86_64/sse.zig:1-44`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/sse.zig#L1-L44), [`kernel/src/arch/x86_64/cpu.zig:121-127`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L121-L127), [`build.zig:149-153`](file:///home/leevawn/Projects/zig-os/build.zig#L149-L153)):**
   - `computeSseCr0(cr0: u64) u64` clears `CR0.EM` (bit 2, `1 << 2`) and `CR0.TS` (bit 3, `1 << 3`), sets `CR0.MP` (bit 1, `1 << 1`), and preserves all unrelated bits.
   - `computeSseCr4(cr4: u64) u64` sets `CR4.OSFXSR` (bit 9, `1 << 9`) and `CR4.OSXMMEXCPT` (bit 10, `1 << 10`), preserving all unrelated bits.
   - `isSseCr0Valid(cr0: u64) bool` verifies `CR0.EM == 0`, `CR0.TS == 0`, and `CR0.MP == 1`; `isSseCr4Valid(cr4: u64) bool` verifies `CR4.OSFXSR == 1` and `CR4.OSXMMEXCPT == 1`.
   - `cpu.enableSse()` invokes these production helpers directly (`writeCr0(sse.computeSseCr0(readCr0()))` and `writeCr4(sse.computeSseCr4(readCr4()))`).
   - Host unit tests (`tests/unit_test.zig:10, 225-289`) import the exact production `sse.zig` module via `test_mod.addAnonymousImport("sse", ...)` in [`build.zig:149-153`](file:///home/leevawn/Projects/zig-os/build.zig#L149-L153) with zero duplicated bit-mask definitions.
2. **Ring 0 Regression Test ([`kernel/src/arch/x86_64/cpu.zig:131-170`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L131-L170), [`kernel/src/main.zig:39-43`](file:///home/leevawn/Projects/zig-os/kernel/src/main.zig#L39-L43)):**
   Invoked during `_start()` after COM1 serial initialization (`serial.init()` / `[CPU] Architecture: x86_64`) and before IDT initialization (`idt.init()`), `cpu.testSseCr0Init()` performs:
   1. Captures initial control register state (`boot_cr0`, `boot_cr4`) and verifies initial boot `enableSse()` invariants (`isSseCr0Valid` and `isSseCr4Valid`).
   2. Verifies maskable interrupts are disabled (`cli()` and confirms `RFLAGS.IF == 0`).
   3. Sets `CR0.EM` and `CR0.TS` (`writeCr0(baseline_cr0 | sse.CR0_EM_BIT | sse.CR0_TS_BIT)`).
   4. Calls `enableSse()` immediately, with zero intervening FPU/SSE instruction.
   5. Reads back `CR0` and `CR4`.
   6. Verifies `EM == 0`, `TS == 0`, `MP == 1`, `OSFXSR == 1`, and `OSXMMEXCPT == 1`.
   7. Verifies unrelated `CR0`/`CR4` bits are preserved (`cr0_preserved_ok`, `cr4_preserved_ok`).
3. **Provenance Boundary:**
   - **ChatGPT independently reviewed:** Complete source and commit diff at `6aa895d419843b106d9773a8b375c501f1530095`, production helper logic (`sse.zig`), register bitmask preservation, Ring 0 test sequence (`cpu.testSseCr0Init()`), `main.zig` startup integration, and host test target wiring (`build.zig`, `tests/unit_test.zig`), issuing `PASS / FIXED` at source level. ChatGPT did **not** independently execute tests, builds, or QEMU.
   - **Hydrogen implementation-agent-reported execution:**
     - **56/56** uncached host unit tests passing across all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`): `unit_test` (`9`, including synthetic `CR0` cases with both `EM`/`TS` set, `EM`-only set, `TS`-only set, both clear with `MP=0` and `MP=1`, unrelated bit preservation, `MP` always set, `isSseCr0Valid` rejections, and `computeSseCr4`/`isSseCr4Valid`), `pmm_test` (`16`), `vmm_test` (`10`), and `heap_test` (`21`).
     - Four-mode freestanding kernel builds (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) and `F-01` `objdump -d -M intel` disassembly scan reporting `0` prohibited SIMD/x87 matches.
     - `Debug` (`bash scripts/test-boot.sh --optimize Debug`) and `ReleaseSafe` (`python3 tests/test_boot.py --optimize ReleaseSafe`) QEMU smoke tests passing, emitting Ring 0 regression marker `[CPU] SSE/CR0.TS initialization verified.` alongside 3-way ELF SHA-256 provenance verification (`Debug`: ELF `bac556b4525699bff5b6c01514000d0d7f731dd2ca5f576492de17937c102267`, ISO `e064c912ca626b076f0a25b918a2609f7ed5b55200530c76652c2af420a94efe`; `ReleaseSafe`: ELF `2d359beb75cd14d796ad81e9a53a45f2f6dec27cd9f440c43e3d9318a9076c57`, ISO `ce59150a294695600fe5e4ae58a528f6f04ab6ee954d20413d986d2786beb82d`; extracted ELF hashes not recorded separately).

**Historical Evidence (Baseline `c10c05f1` — Resolved at `6aa895d`):**
At baseline `c10c05f1`, [`kernel/src/arch/x86_64/cpu.zig:117-129`](file:///home/leevawn/Projects/zig-os/kernel/src/arch/x86_64/cpu.zig#L117-L129) cleared `CR0.EM` (bit 2) and set `CR0.MP` (bit 1), `CR4.OSFXSR` (bit 9), and `CR4.OSXMMEXCPT` (bit 10), but omitted clearing `CR0.TS` (bit 3):
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

**Technical explanation (Historical Defect Context & Ongoing Invariants):**
1. **Limine Base Revision 3 `CR0` guarantees vs. Base Revision 5+:**
   Per the official Limine Boot Protocol specification (*Entry / Machine State — x86_64*), Limine only guarantees that all unspecified `CR0` bits are cleared to `0` starting with **Base Revision 5 or later**. Under **Base Revision 3** (requested by ZIG-OS), the protocol specifies `CR0.PE = 1`, `CR0.PG = 1`, and `CR0.WP = 1`, and did **not** guarantee `CR0.TS == 0` at handoff.
2. **Architectural Impact Prior to Fix:**
   Per Intel SDM Vol. 3A §2.5 and §13.1.3, whenever `CR0.TS == 1`, executing any x87/MMX/SSE instruction or `FXSAVE`/`FXRSTOR` raises `#NM` (Device Not Available, Vector 7), and executing `WAIT`/`FWAIT` when `CR0.MP == 1` and `CR0.TS == 1` also raises `#NM`. Any compliant Base Revision 3 handoff state with `CR0.TS == 1` would leave `CR0.TS == 1` after baseline `enableSse()`.
3. **Interaction with `F-01` & Phase 2 Scheduling:**
   With `F-01` fixed (`-x87 -mmx -sse -sse2 -avx -avx2 +soft_float`) and `F-15` fixed (`enableSse()` clears both `CR0.EM` and `CR0.TS`), boot leaves `CR0.TS == 0`. In Phase 2 multitasking, eager FPU switching keeps `CR0.TS == 0` continuously, while lazy FPU switching would explicitly toggle `CR0.TS` paired with a Vector 7 (`#NM`) handler.

**Dependencies:**  
Coordinates with `F-01` (SIMD/FPU strategy) and future Phase 2 task FPU context switching.

---

### [F-16] PMM bitmap placement check (`entry.base != 0`) permits placing the bitmap below 1 MiB (`0x100000`)

**Status:** FIXED (Independently Source-Audited at `c1ef192b336ba548ac0acb5340d92143bdad7994` & Reviewed by ChatGPT; Host Production-Core Regression Tests `F-16` Agent-Reported Passing; Live Ring 0 `pmm.testPmm()` Verifies `bitmap_phys >= 0x100000`, Page Alignment, and Full `[bitmap_phys, bitmap_end_phys)` Frame Reservation)

**Severity:** LOW (Resolved)

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)), kernel PMM adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)), and PMM host test suite ([`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:10`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L10), [`kernel/src/mm/physical_core.zig:159-184`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L159-L184), [`kernel/src/mm/physical_core.zig:275-326`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L275-L326), and [`kernel/src/mm/physical_core.zig:388-395`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L388-L395)
- [`kernel/src/mm/physical.zig:25-26, 89-99, 178-185`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L178-L185)
- [`tests/pmm_test.zig:144-188, 214-224, 244-266, 548-564, 900-957`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L900-L957)

**Resolution & Independent Audit Evaluation (v1.8, Commit `c1ef192b336ba548ac0acb5340d92143bdad7994`):**
1. **Independently Reviewed Source Evidence:**
   - **Strict `>= 1 MiB` & Page-Aligned Candidate Selection (`physical_core.zig:10, 163-167, 278-306`):**
     - `LOW_MEMORY_LIMIT: u64 = 0x100000` (`line 10`).
     - In [`initWithSource()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L282-L306), only `region.kind.isUsable()` entries with `region.length > 0` are considered; for each entry, `candidate_start = alignUpPage(@max(region.base, LOW_MEMORY_LIMIT)) orelse continue;` clamps regions starting below `1 MiB` up to `0x100000` and aligns sub-page starts upward to a `PAGE_SIZE` (`4096`) boundary, rejecting regions where `candidate_start >= region_end`.
   - **Complete Page-Rounded Backing Fit & Non-Usable Overlap Rejection (`physical_core.zig:173-184, 275-276, 294-305`):**
     - Computes `bitmap_pages_u64 = bytesToPageCountCeil(@as(u64, @intCast(computed_bitmap_size)))` and `bitmap_backing_bytes = std.math.mul(u64, bitmap_pages_u64, PAGE_SIZE) catch return error.NoUsableBitmapRegion`.
     - Requires `(region_end - candidate_start) >= bitmap_backing_bytes` (so a `.usable` region that holds `computed_bitmap_size` unrounded bytes but fewer than `bitmap_pages_u64` full physical frames is skipped) and rejects candidates where `overlapsNonUsableRegion(source, candidate_start, candidate_end)` is `true`.
   - **Full Backing-Frame Reservation Including Partial Final Pages (`physical_core.zig:321-322, 388-395`):**
     - Stores `bitmap_phys = resolved_bitmap_phys` and `bitmap_end_phys = chosen_bitmap_end` (`candidate_start + bitmap_backing_bytes`), synced to `physical.bitmap_phys` and `physical.bitmap_end_phys` (`physical.zig:25-26, 92-93`).
     - Reserves every frame in `[physToFrame(resolved_bitmap_phys), physToFrame(chosen_bitmap_end))` via `self.setBit(b_frame)` (`lines 389-395`) prior to recounting `used_pages` and `free_pages`, ensuring even a partial final logical bitmap page is marked `USED` and protected against both `allocPage()` and `freePage()` (`error.BitmapOverlap`).
2. **Regression Test & Provenance Boundary (Host Fake-Backend vs. QEMU Runtime):**
   - **Independently Audited Host Regression Tests ([`tests/pmm_test.zig:900-957`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig#L900-L957), plus `lines 144-188, 214-224, 244-266, 548-564`):**
     - `"F-16: bitmap placement strictly enforces >= 1 MiB, alignment, complete multi-page fit, and later fallback"` (`lines 900-957`): Verifies (1) a `.usable` region strictly below `1 MiB` (`[0x1000, 0x100000)`) fails with `error.NoUsableBitmapRegion`; (2) a `.usable` region crossing `1 MiB` (`[0x80000, 0x104000)`) clamps `bitmap_phys` to `0x100000` (`bitmap_end_phys = 0x101000`) while keeping `< 1 MiB` reserved; and (3) a 5,120-byte (2-page = 8,192 B backing) bitmap skips `< 1 MiB` (`0x1000..0x41000`), a crossing region with only `0x800` B above `1 MiB` (`0x80000..0x100800`), a 6,144-byte `.usable` region (`>= 5,120 B` logical size but `< 8,192 B` page-rounded size), and an unaligned `.usable` region (`0x104400..0x106000`, leaving only 1 page after `alignUpPage` to `0x105000`), selecting the later qualifying region `0x108400..0x10C000` at aligned `bitmap_phys = 0x109000` (`bitmap_end_phys = 0x10B000`) while leaving skipped usable frames `0x101000`, `0x105000`, and `0x10B000` free.
   - **In-Kernel QEMU Runtime Coverage vs. Host Simulation:**
     - [`pmm.testPmm()`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L178-L185) in the live Ring 0 QEMU boot path verifies `bitmap_phys >= physical_core.LOW_MEMORY_LIMIT`, `bitmap_phys % PAGE_SIZE == 0`, `bitmap_end_phys > bitmap_phys`, and `isPageAllocated(probe_b)` for every frame in `[bitmap_phys, bitmap_end_phys)`.
     - Multi-candidate `< 1 MiB` / unaligned / insufficient-page-fit skip permutations are verified in host unit tests (`tests/pmm_test.zig`), not under QEMU.

**Historical Evidence (Baseline `c10c05f1` through `b3cf68bb`):**
Prior to `c1ef192b`, `PhysicalAllocator.init()` checked only `region.kind == .usable and region.length >= computed_bitmap_size and region.base != 0`, permitting `< 1 MiB` placement (such as `0x1000`) and checking unrounded byte size rather than page-rounded frame capacity.

**Dependencies:**  
Related to `F-07`, `F-08`, and `F-10` (`F-10B` Part 1).

---

### [F-17] PMM page counters (`usable_pages`, `used_pages`, `free_pages`) have undocumented, differing semantics

**Status:** VERIFIED

**Severity:** INFORMATIONAL

**Confidence:** HIGH

**Affected component:**  
Physical Memory Manager core ([`kernel/src/mm/physical_core.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig)) and kernel adapter ([`kernel/src/mm/physical.zig`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig)).

**Source location:**  
- [`kernel/src/mm/physical_core.zig:188-192`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L188-L192) and [`kernel/src/mm/physical_core.zig:316-320, 353-426`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L353-L426)
- [`kernel/src/mm/physical.zig:19-23, 89-99, 174-252`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L19-L23)

**Evidence:**  
In [`physical_core.zig:316-426`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical_core.zig#L316-L426) and [`physical.zig:19-23`](file:///home/leevawn/Projects/zig-os/kernel/src/mm/physical.zig#L19-L23):
- `usable_pages` is zeroed at `physical_core.zig:317`, incremented at `line 356` for each whole `.usable` frame `>= 0x100000` (and decremented at `line 382` if overlapped by a non-usable region) before the bitmap frames `[bitmap_phys, bitmap_end_phys)` are marked used (`lines 388-395`), and is never read by any kernel subsystem outside `tests/pmm_test.zig`.
- `used_pages` and `free_pages` are recounted over `0..total_pages` at `physical_core.zig:397-426` (so `used_pages` includes all non-usable/reclaimable/kernel frames and `< 1 MiB` frames below `highest_address` plus the bitmap frames, and `used_pages + free_pages == total_pages`), updated on `allocPage()`/`allocPages()`/`freePage()`/`freePages()`, and checked in `pmm.testPmm()` (`physical.zig:174-252`) and `tests/pmm_test.zig`.
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

> **Governance Gate Notice:** This section defines the proposed engineering sequence for **Phase 1 Hardening**. It does **not** authorize Phase 2 (**NOT AUTHORIZED**) and does **not** mark Phase 1 as Human Approved (**Pending Human Review**). Resolving `F-10` (or `F-01`, `F-03`, `F-06`, `F-07`, `F-08`, `F-09`, `F-11`, `F-12`, `F-13`, `F-14`, `F-15`, `F-16`) does not constitute Project Owner approval of Phase 1 or Phase 2. Only the Project Owner may approve milestone gates.

### P0 — Must Fix Before Further Kernel Development (0 Active Findings — All 3 Resolved)

**Included Active Findings:** None (`F-01`, `F-10`, and `F-14` are `FIXED`)
- **`F-01` (`FIXED` at `515aa91`):** Freestanding kernel target in [`build.zig:4-20`](file:///home/leevawn/Projects/zig-os/build.zig#L4-L20) subtracts `.x87`, `.mmx`, `.sse`, `.sse2`, `.avx`, `.avx2` and adds `.soft_float`.
- **`F-14` (`FIXED` at `7711468`):** All public build/run/debug/test entrypoints enforce unconditional fresh builds, `ReleaseSafe` default optimization, a non-recursive Zig build graph, and 3-way kernel ELF SHA-256 provenance verification prior to QEMU launch.
- **`F-10` (`FIXED` across `9df21f8`, `bc2efdb`, `0156e91`, `b3cf68b`, `c1ef192`, `18dabd7`, `0092cf3`, `6aa895d`, `4b3ea6f`, `184784d`, and `697f1ff`):** `zig build test` ([`build.zig:123-237`](file:///home/leevawn/Projects/zig-os/build.zig#L123-L237)) compiles and runs five host test targets directly against production kernel modules with zero test-side algorithm duplication (`67` total host unit tests):
  - `unit_test` ([`tests/unit_test.zig`](file:///home/leevawn/Projects/zig-os/tests/unit_test.zig)): 9 tests importing `paging_math.zig`, `physical_math.zig`, `page_fault.zig`, `heap_layout.zig` (`F-10A`, 7 tests), and `sse.zig` (`F-15` at `6aa895d`, 2 tests).
  - `pmm_test` ([`tests/pmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/pmm_test.zig)): 16 stateful tests importing `physical_core.zig` (`F-10B` Part 1 + `F-07`/`F-08`/`F-16` hardening).
  - `vmm_test` ([`tests/vmm_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vmm_test.zig)): 10 stateful tests importing `virtual_core.zig` (`F-10B` Part 2 + `F-09`/`F-13` hardening).
  - `heap_test` ([`tests/heap_test.zig`](file:///home/leevawn/Projects/zig-os/tests/heap_test.zig)): 21 stateful tests importing `heap_core.zig` (`F-10B` Part 3 [14 tests] + `F-06`/`F-11`/`F-12` hardening [7 tests, `Heap 15`–`Heap 21` at `18dabd7`/`0092cf3`]).
  - `vector_policy_test` ([`tests/vector_policy_test.zig`](file:///home/leevawn/Projects/zig-os/tests/vector_policy_test.zig)): 11 tests importing `vectors.zig` and `build_options` (`F-03` pure vector/PIC/IDT gate invariants [5 tests] + fail-closed and `.S`-preprocessed static forbidden-`INT` scanner across `4b3ea6f`, `184784d`, and `697f1ff` [6 tests]).

---

### P1 — Must Fix Before Phase 2 Authorization (1 Active Finding)

**Included Active Findings:** `F-04`
*(Note: VMM findings `F-09` and `F-13` were resolved at `0156e91` in `virtual_core.zig` and `virtual.zig`; PMM findings `F-07` and `F-08` were resolved at `c1ef192` in `physical_core.zig` and `physical.zig`; Heap findings `F-06`, `F-11`, and `F-12` were resolved at `18dabd7`/`0092cf3` in `heap_layout.zig`, `heap_core.zig`, and `heap.zig`; CPU SSE finding `F-15` was resolved at `6aa895d` in `sse.zig`, `cpu.zig`, and `main.zig`; and interrupt vector protection finding `F-03` was resolved across `4b3ea6f`, `184784d`, and `697f1ff` in `vectors.zig`, `pic.zig`, `idt.zig`, `main.zig`, `build.zig`, and `tests/vector_policy_test.zig`).*

- **Dependencies:** Enabled by completed **P0** foundation (`F-01` SIMD prohibition, `F-10` host-testable core modules, and `F-14` rebuild/provenance pipeline) and completed hardening (`F-03`, `F-06`–`F-09`, `F-11`–`F-13`, `F-15`). `F-04` requires updating/superseding [`ADR-0003`](file:///home/leevawn/Projects/zig-os/docs/adr/0003-limine-gdt-preservation-phase1.md).
- **Required Implementation Tasks:**
  1. **`F-04` (GDT/TSS/IST & Frame Verification):** Building on the completed `F-03` vector partition, legacy 8259 PIC remap/mask (`pic.remapAndMask()`), IDT gate verification (`idt.validateExceptionGates()`), and fail-closed static `INT` scanner, install a kernel-owned GDT and 64-bit TSS (`lgdt`, `ltr`) with a dedicated `IST1` stack for `#DF` (Vector 8).
- **Required Regression Tests:**
  - Three-regime QEMU interrupt frame verification (`F-04`): (a) same-CPL (`IST = 0`) exceptions verifying saved `frame.rsp` and `frame.ss`, (b) `IST1` stack-switched `#DF` verifying `IST1` stack pointer and interrupted `frame.rsp`/`frame.ss`, and (c) `CPL 3 -> CPL 0` privilege transition frame verification once Ring 3 exists.
- **Acceptance Criteria:** All CPU `CR0`/`CR4`, PMM, VMM, Heap, GDT/TSS, and IDT invariants pass host unit tests (`zig build test`) and fresh-build QEMU runtime verification in both `Debug` and `ReleaseSafe` modes.

---

### P2 — Important Hardening That Can Follow (1 Active Finding)

**Included Active Findings:** `F-19`
*(Note: `F-16` was resolved at `c1ef192` in `physical_core.zig` and `physical.zig`).*

- **Dependencies:** `F-19` requires Project Owner selection between Base Revision 3 explicit ACPI mapping vs. Base Revision 4 ADR update.
- **Required Implementation Tasks:**
  1. **`F-19`:** Before Phase 2 ACPI table access, either map `.acpi_reclaimable` / `.acpi_nvs` regions into the HHDM via `vmm.mapPage()` or advance Limine Base Revision to `4` via an approved ADR.
- **Required Regression Tests:**
  - Verify HHDM reachability of `.acpi_reclaimable` frames before ACPI parsing.
- **Acceptance Criteria:** ACPI memory safely mapped prior to Phase 2 MADT discovery.

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
