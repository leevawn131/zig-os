# ZIG-OS Testing & Quality Assurance Policy

## 1. Quality Mission & Invariants
In **ZIG-OS**, no subsystem is considered functional based on source code presence alone. Passing compilation does not prove kernel correctness, and host-side execution does not prove freestanding bare-metal behavior. Every functional claim must be backed by empirical test logs.

---

## 2. The Verification Pyramid

Testing in ZIG-OS is structured across five distinct verification tiers:

```mermaid
flowchart TD
    T5["Tier 5: Hardware Verification<br/>(Bare-metal physical x86_64 execution)"]
    T4["Tier 4: QEMU Integration & Smoke Tests<br/>(Headless boot, serial parsing, stability checks)"]
    T3["Tier 3: In-Kernel Boot Self-Tests<br/>(Runtime sanity tests during kernel initialization)"]
    T2["Tier 2: Host-Side Unit Tests<br/>(Algorithmic, bitwise, and structure tests in Zig)"]
    T1["Tier 1: Static Analysis & Compilation<br/>(Compiler type checks, zero warnings, linter)"]

    T1 --> T2
    T2 --> T3
    T3 --> T4
    T4 --> T5
```

---

## 3. Standard Verification Labels

Every status assertion, milestone claim, and documentation update must utilize one of these standardized verification labels:

| Verification Label | Strict Technical Definition | Permitted Claim Scope |
|---|---|---|
| `NOT IMPLEMENTED` | File or function does not exist or contains empty signatures/stubs. | No claims permitted. |
| `IMPLEMENTED` | Code has been authored, but has not yet been compiled or executed. | Syntax written only; no functionality implied. |
| `BUILD VERIFIED` | Successfully compiled with Zig 0.17.1 and LLVM LLD without errors or warnings. | Syntactically and type valid; runtime behavior unverified. |
| `UNIT TEST VERIFIED` | Verified by executing host-side unit tests via `zig build test`. | Logic, mathematics, and algorithms verified in host userspace. |
| `QEMU VERIFIED` | Successfully booted inside QEMU with serial log evidence and quiescent CPU halt. | Verified within virtualized freestanding execution environment. |
| `HARDWARE VERIFIED` | Verified on physical x86_64 bare-metal hardware. | Verified on target silicon with real peripherals. |
| `PRODUCTION READY` | Formally code-reviewed, fuzz-tested, stress-tested, and audited. | Production quality across all build modes. |

---

## 4. Test Categories & Execution Protocols

### 4.1 Host-Side Unit Tests (`tests/unit_test.zig`, `tests/pmm_test.zig`, `tests/vmm_test.zig`, `tests/heap_test.zig`, `tests/vector_policy_test.zig`)
- **Execution Command**: `zig build test`
- **Scope**: Memory calculations, paging address decomposition, bitfield encoding/decoding, bitmap frame indexing, allocator chunk header integrity, pure GDT/TSS descriptor encoding (`gdt_model.zig`), bounded UART TX polling (`serial.waitForTxReady`), overflow-safe frame range validation (`isFrameWithinStack`, `isFrameDisjointFromStack`), atomic CAS `DfStateMachine` + `#DF` forensics (`vectors.zig`), interrupt vector reservation & PIC offset policy, and static source scanning of `kernel/` (`.zig`, `.s`, `.S`, `.asm`) to forbid `int <n>` on error-code and non-breakpoint reserved exception vectors.
- **Limitation**: Executes under host Linux virtual memory. Does **not** verify privileged CPU instructions, hardware interrupts, or physical MMIO.

### 4.2 In-Kernel Runtime Self-Tests
- **Scope**: Executed during early boot sequence before handing off to userland:
  - Legacy PIC remap & mask verification: `pic.remapAndMask()` remaps 8259 PICs to `0x20–0x2F` and verifies IMRs read back `0xFF`/`0xFF` (`[PIC]` marker).
  - Kernel-owned GDT/TSS/IST validation: `gdt.testGdtAndTss()` verifies `sgdt`, `str() == 0x48`, post-load Accessed (`0x9B`/`0x93`) & Busy (`0x8B`) bits, active selectors (`0x28`/`0x30`), and three disjoint 16-byte-aligned IST stacks (`[GDT]` marker).
  - IDT dispatch & IST stack-switch self-tests: `idt.testExceptionDispatch()` (`ist = 0`) and `idt.testIstStackSwitch()` (`IST1`–`IST3`) trigger controlled `int $3` with zero RIP skip adjustment, verifying next-instruction continuation, exact pre/post `RSP`, and overflow-safe frame placement before `idt.enableIstGates()`.
  - IDT gate validation: `idt.validateExceptionGates()` verifies `0x8E` (Present, DPL=0, 64-bit Interrupt Gate), expected IST indices (`8->1, 2->2, 18->3`, others `0`), kernel CS `0x28`, cleared reserved fields, and distinct exception stub addresses across vectors `0..31` (and all 256 gates).
  - Page Fault self-test: Controlled `#PF` test hook validating CR2 linear address and error flags (exclusively on Vector 14).
  - PMM self-test: Single and multi-page allocation, free, re-allocation, and double-free rejection.
  - VMM self-test: Virtual-to-physical translation (`virtToPhys`), dynamic table allocation, page unmapping, and TLB flush (`invlpg`).
  - Heap self-test: Small/large allocations, chunk alignment, header canary verification (`0xCAFEBABE`), and free coalescing.
- **Safety Policy**: Self-tests must be strictly non-destructive and must not crash or halt the system during normal production boot.

### 4.3 Headless QEMU Smoke Tests (`scripts/test-boot.sh`, `tests/test_boot.py`) & Isolated `test-df`
- **Production Boot (`./scripts/test-boot.sh` or `python3 tests/test_boot.py`)**: Boots `build/zig-os.iso` (F-14 3-way SHA-256 verified) in headless QEMU, captures COM1 serial output, asserts required boot strings (`[GDT]`, `[IDT] 256 interrupt gates configured and verified.`, etc.), and monitors process state to confirm stability under `-no-reboot`.
- **Isolated Double Fault Test (`zig build test-df`)**: Uses a strictly isolated build/ISO/provenance pipeline (`zig-out/df-test/kernel-df-test.elf`, `build/df-test/iso_root`, `build/zig-os-df-test.iso`, never overwriting production artifacts) to trigger a real unmapped-stack `#PF -> #DF` escalation onto `IST1`. Verifies serial forensic evidence (`[DF-TEST] PASS`, Vector 8 `#DF`, `Error Code: 0`, `CR2`/`RSP` window), process survival (`kill -0`), VM runstate (QMP `query-status`), and guest BSP halt state (`HLT=1`, `CPL=0`, `TR=0048`) via an exact QEMU `10.2.1` version-validated multi-line `CPU#0` HMP parser.
- **Criteria for Success**:
  1. All expected serial markers are present in exact chronological sequence.
  2. QEMU executes without triggering triple faults, reboot loops, or unhandled CPU exceptions.
  3. CPU remains stable in a low-power `hlt` quiescent loop.

### 4.4 Hardware Bare-Metal Testing
- **Protocol**: Flash hybrid ISO (`build/zig-os.iso`) to USB drive via `dd` or deploy via PXE.
- **Validation**: Capture serial output via physical RS-232 COM port or UEFI screen framebuffer.

---

## 5. Failure Reporting & Evidence Standards

Every test failure report must include:
1. **Command Executed**: Full command string including flags.
2. **Exit Code**: Exact return code.
3. **Captured Output**: Raw console or serial logs.
4. **Root Cause Analysis**: Technical hypothesis explaining the defect.
5. **Remediation Plan**: Non-destructive, incremental correction steps.

```markdown
### Test Execution Evidence Example
- **Command**: `./scripts/test-boot.sh`
- **Exit Status**: 0
- **Log Snippet**:
  ```
  [IDT] 256 interrupt gates configured and verified.
  [PMM] Physical frame allocator initialized and verified.
  [VMM] 4-level paging and translation primitives verified.
  [HEAP] Dynamic memory allocator initialized and verified.
  [STATUS] Kernel initialization complete.
  zig-os:~$
  ```
- **Result**: ALL CHECKS PASSED. QEMU process 1252884 stable in hlt loop.
```
