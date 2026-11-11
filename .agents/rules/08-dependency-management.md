---
trigger: model_decision
description: "External toolchain, bootloader (Limine), compiler (Zig 0.17.1), emulator (QEMU), or dependency updates, protocol headers, and asset verification."
---

# 08 - Dependency & Toolchain Governance

## 1. Strict Version Pinning
All tools, bootloader assets, and compiler versions must be pinned to exact releases:
- **Zig Compiler**: Version `0.17.1` (never floating `nightly` or `latest`).
- **Limine Bootloader**: Version `12.9.6` (binary assets in `boot/limine/` and protocol structures in `kernel/src/limine.zig`).
- **Target Linker**: LLVM LLD built into Zig.
- **Host OS**: Ubuntu 26.04 LTS (x86_64).

## 2. Bootloader & Protocol Verification
- Follow the official Limine protocol specification:
  - Protocol request structures must use the official 64-bit ID pairs (`0xc7b1dd30df4c8b88`, `0x0a82e883a194f07b`, etc.).
  - Do not invent custom protocol requests or modify Limine struct layouts.
  - Limine response pointers must be read via higher-half virtual addresses.

## 3. Policy on External Libraries & Packages
- **Zero Third-Party Kernel Crates**: No external packages may be added to `build.zig.zon` for kernel-space code without an approved Architecture Decision Record (ADR).
- **Core OS Autonomy**: Never introduce external dependencies to bypass understanding core OS mechanics. Memory allocators, schedulers, virtual filesystems, and device drivers must be implemented from scratch in pure Zig.
- **Vendored Assets**: When external assets (like Limine binary components) are stored in the tree, their version tag, license (`boot/limine/LICENSE`), and upstream repository must be documented in `docs/BUILDING.md`.
