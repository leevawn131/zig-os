# ZIG-OS Master Agent Operating Instructions

> **AUTHORITY**: This document is the master governance instruction file for all AI agents, engineers, and automated tools operating on the **ZIG-OS** repository. It defines inviolable project invariants, workflow requirements, and the rule hierarchy.

---

## 1. Project Mission & Identity

**ZIG-OS** is an independent, production-oriented operating system built from scratch for the `x86_64` (AMD64) architecture using **Zig** as the primary kernel systems language.

This is **NOT** a tutorial, prototype, or educational toy. Every subsystem must be designed, implemented, and verified to production systems standards.

### Pinned Technical Stack
All development must strictly adhere to the following pinned toolchain and host environment. These versions are immutable without formal Architecture Decision Record (ADR) approval:

| Component | Pinned Specification | Invariant Rule |
|---|---|---|
| **Host OS** | Ubuntu 26.04 LTS (x86_64) | Primary continuous development host |
| **Kernel Language** | **Zig 0.17.1** | Verify all APIs against 0.17.1 compiler; no legacy syntax |
| **Target Architecture** | `x86_64` (AMD64) | Target triple: `x86_64-freestanding-none` |
| **Bootloader** | **Limine 12.9.6** | Follow official protocol specification; no invented structs |
| **Emulator** | **QEMU** (`qemu-system-x86_64`) | Primary integration test execution target |
| **Debugger** | **GDB** (`gdb`) | Target remote debugging on port 1234 |
| **Linker** | **LLVM LLD** | Integrated via Zig build system (`use_lld = true`) |
| **Code Model** | `kernel` (`-mcmodel=kernel`) | Higher-half addressing at `0xffffffff80000000` |
| **Stack ABI** | SysV ABI with `-mno-red-zone` | Red zone disabled; 16-byte aligned stack on calls |

---

## 2. Inviolable Core Principles

1. **Pure Zig Kernel Implementation**:
   - Zero C or C++ in kernel source code.
   - Minimal x86_64 assembly is permitted only for low-level architecture stubs (e.g., ISR vector tables, context switching).
2. **Strict Architecture Isolation**:
   - All architecture-dependent code must reside in `kernel/src/arch/<arch>/`.
   - Generic kernel subsystems (VFS, memory manager, scheduler, drivers) must never execute inline assembly or direct model-specific registers.
3. **No Unverified Assumptions**:
   - Never assume physical memory is identity-mapped.
   - Never assume physical addresses can be directly dereferenced as virtual pointers without the Higher Half Direct Map (HHDM).
   - Never assume bootloader memory can be reclaimed before safe kernel takeover.
4. **No Fake or Mock Hardware**:
   - Implement real hardware drivers according to official datasheets and specifications.
   - Placeholder implementations marked as "complete" or stubbed dummy returns are strictly prohibited.
5. **No Destructive Recovery**:
   - Destructive Git operations (`git reset --hard`, `git clean -fd`, force pushing, history rewriting) are forbidden.

---

## 3. Governance Rule Hierarchy

Antigravity automatically discovers specialized engineering rules located in `.agents/rules/`. Before modifying code, future AI agents **MUST** read and obey the applicable rule documents:

```
.agents/rules/
├── 00-project-charter.md           # [always_on] Mission, authority, milestone gate system
├── 01-engineering-workflow.md      # [always_on] Change management, verification labels, git policy
├── 02-zig-kernel-development.md   # [glob: **/*.zig, **/*.zon] Zig 0.17.1 idioms, memory, types
├── 03-x86_64-architecture.md       # [glob: **/arch/**, **/*.s, **/linker.ld] Registers, SSE, ABI
├── 04-memory-management.md         # [glob: **/mm/**, **/limine.zig] PMM, VMM, Heap, HHDM
├── 05-interrupt-and-abi.md         # [glob: **/idt/**, **/interrupts/**, **/gdt/**] IDT, ISRs
├── 06-testing-and-verification.md  # [glob: **/tests/**, **/scripts/**] Test pyramid & evidence
├── 07-security-and-safety.md       # [model_decision] Privilege levels, isolation, canaries
└── 08-dependency-management.md     # [model_decision] Toolchain, bootloader, vendor policies
```

Detailed architectural specifications and decisions are cataloged in:
- `docs/ARCHITECTURE.md` — Active architectural blueprints and memory layouts.
- `docs/ENGINEERING_GOVERNANCE.md` — Extended governance, roles, and review workflows.
- `docs/TESTING_POLICY.md` — Verification standards, test matrix, and evidence logging.
- `docs/adr/` — Architecture Decision Records.

---

## 4. Phase Milestone Gate System

No AI agent may unilaterally advance to an unauthorized project phase or milestone. Development proceeds strictly through gated milestones:

| Phase | Description | Current Status | Gate Status |
|---|---|---|---|
| **Phase 0** | Foundation (Limine boot, COM1 serial, panic, ISO, QEMU) | Agent-Reported Complete | Pending Human Review |
| **Phase 1** | Kernel Core (GDT, IDT, PMM, VMM, Heap Allocator) | Agent-Reported Complete | Pending Human Review |
| **Phase 1.1** | Governance System Establishment | **ACTIVE** | In Progress |
| **Phase 2** | Multitasking & Processes (PCB, TCB, Scheduler, Syscalls) | Planned | **NOT AUTHORIZED** |
| **Phase 3** | Drivers & Hardware Subsystems (PCI, Keyboard, Storage) | Planned | **NOT AUTHORIZED** |
| **Phase 4** | Virtual Filesystem (VFS, RamFS, Storage FS) | Planned | **NOT AUTHORIZED** |
| **Phase 5** | Userland & Interactive Shell (Ring 3, Coreutils) | Planned | **NOT AUTHORIZED** |

> [!CRITICAL]
> Agent-reported completion is **not** human approval. Phase 1.1 is governance-only. Phase 2 must **never** be started without explicit human authorization.

---

## 5. Verification Labels (No Unverified Claims)

Agents must never declare a subsystem working without empirical test logs. Every status assertion must specify one of the following exact verification labels with attached command output:

1. `NOT IMPLEMENTED`: Feature or file does not exist or contains empty stubs.
2. `IMPLEMENTED`: Code is written but has not been compiled or tested.
3. `BUILD VERIFIED`: Successfully compiled with Zig 0.17.1 without warnings or errors.
4. `UNIT TEST VERIFIED`: Verified via host-side unit tests (`zig build test`).
5. `QEMU VERIFIED`: Verified inside QEMU via boot smoke tests with serial log evidence.
6. `HARDWARE VERIFIED`: Verified on bare-metal physical x86_64 hardware.
7. `PRODUCTION READY`: Formally reviewed, fuzz-tested, and audited under all build configurations.

---

## 6. Prohibited Behaviors

Any agent performing the following actions violates engineering governance:
- **Modifying kernel source during a governance task**.
- **Advancing to an unapproved development phase**.
- **Claiming a test passed without running the command and providing output**.
- **Executing destructive Git commands** (`git reset --hard`, `git clean -fd`, `git checkout -- .`).
- **Committing changes automatically without explicit human instruction**.
- **Introducing C or C++ into the kernel codebase**.
- **Reclaiming bootloader memory prematurely**.
- **Using outdated Zig idioms or APIs without verifying against 0.17.1**.
- **Masking kernel panics or page faults with silent catch-all blocks**.
