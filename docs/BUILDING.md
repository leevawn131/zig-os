# ZIG-OS Build & Execution Guide

## 1. Prerequisites & Toolchain

The following tools are required on the host system:

| Tool | Required Version | Verification Command |
|---|---|---|
| **Zig Compiler** | `0.17.1` | `zig version` |
| **QEMU Emulator** | `>= 8.0` | `qemu-system-x86_64 --version` |
| **xorriso** | `>= 1.5` | `xorriso -version` |
| **GDB** | Any recent | `gdb --version` |
| **Make / GCC** | Host toolchain | `make --version && gcc --version` |

---

## 2. Quick Start

### Build Kernel and Bootable ISO
```bash
./scripts/build.sh
```
Or via the Zig build system:
```bash
zig build iso
```
The resulting hybrid ISO will be generated at `build/zig-os.iso`.

### Run in QEMU
```bash
./scripts/run.sh
```
Or via Zig:
```bash
zig build run
```
*Note: To exit QEMU, press `Ctrl+A` then `X`.*

### Run Automated Smoke Test
```bash
./scripts/test-boot.sh
```
Or via Zig:
```bash
zig build test-boot
```
Or via the Python test harness:
```bash
python3 tests/test_boot.py
```

---

## 3. Kernel Debugging with GDB

1. Launch QEMU paused at the entry point waiting for GDB on port `1234`:
```bash
./scripts/debug.sh
```
2. In a separate terminal, launch GDB and attach:
```bash
gdb -ex "target remote :1234" -ex "symbol-file zig-out/bin/kernel.elf"
```
3. Set breakpoints and continue execution:
```gdb
(gdb) break _start
(gdb) continue
```

---

## 4. Build Artifacts Reference

- `zig-out/bin/kernel.elf`: The linked higher-half x86_64 ELF kernel image.
- `boot/limine/limine`: Compiled Limine host installer utility.
- `build/iso_root/`: Temporary staging directory for the ISO filesystem.
- `build/zig-os.iso`: Hybrid bootable ISO image (supports both BIOS MBR and UEFI).
