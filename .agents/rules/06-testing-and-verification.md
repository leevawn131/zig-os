---
trigger: glob
globs: "**/tests/**, **/scripts/**, **/build.zig"
---

# 06 - Testing & Verification Standards

## 1. Testing Pyramid & Verification Levels
Quality assurance for ZIG-OS requires a multi-layered verification strategy:

```
          [ Hardware Verification ]        (Bare-metal test machines)
        [ QEMU Integration Tests ]        (Headless boot smoke tests)
      [ In-Kernel Boot Self-Tests ]       (Runtime PMM/VMM/Heap checks)
    [ Host-Side Unit Tests (Zig) ]        (Pure logic & arithmetic)
  [ Compilation & Static Analysis ]       (Clean build, zero warnings)
```

1. **Compilation**: Every subsystem must build cleanly with LLVM LLD under `Debug` and `ReleaseSafe`.
2. **Host Unit Tests (`tests/unit_test.zig`)**: Verify address calculations, bitmap index math, bitfield decoding, and data structure invariants in a host environment (`zig build test`).
3. **In-Kernel Boot Self-Tests**: Execute non-destructive sanity tests (e.g., PMM single/multi-page allocation, VMM mapping/unmapping, Heap allocation/free/coalescing) during early boot.
4. **QEMU Integration Tests (`scripts/test-boot.sh`, `tests/test_boot.py`)**: Execute headless QEMU runs to capture COM1 serial output, assert expected markers, and verify quiescent CPU halt without crashes or reboots.

## 2. Test Execution & Reporting Standards
Whenever reporting test results, agents must provide empirical logs with:
- **Exact Command Executed**: (e.g., `zig build test && ./scripts/test-boot.sh`).
- **Exit Status**: Exit code 0 or explicit failure code.
- **Captured Serial Output**: Relevant log snippets demonstrating expected milestones.
- **Expected vs. Actual Outcome**: Clear comparison.
- **Known Limitations**: Any edge cases not exercised by the test.

## 3. Host vs. Freestanding Kernel Distinction
- Passing a host unit test **does not** prove the code runs correctly in freestanding x86_64 mode.
- Host tests execute with host OS virtual memory, standard C/POSIX runtimes, and unrestricted CPU privileges.
- Always validate kernel-space behavior within QEMU.

## 4. Controlled Fault Testing Policy
- Test-only fault injections (such as software breakpoints or controlled `#PF` tests) must be strictly isolated to non-fatal test hooks.
- **Never intentionally crash the kernel** or trigger unhandled faults during normal production boot.
- The default boot path must always terminate cleanly at the prompt (`zig-os:~$`) in a quiescent halt loop.
