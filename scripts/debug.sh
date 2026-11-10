#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${PROJECT_ROOT}/build/zig-os.iso"
KERNEL_BIN="${PROJECT_ROOT}/zig-out/bin/kernel.elf"

if [[ ! -f "${ISO}" ]]; then
    echo "[DEBUG] ISO not found. Building first..."
    "${PROJECT_ROOT}/scripts/build.sh"
fi

echo "[DEBUG] Starting QEMU with GDB stub on localhost:1234..."
echo "[DEBUG] To connect with GDB, in another terminal run:"
echo "        gdb -ex \"target remote :1234\" -ex \"symbol-file ${KERNEL_BIN}\""
echo ""

exec qemu-system-x86_64 \
    -M q35 \
    -m 256M \
    -cdrom "${ISO}" \
    -serial stdio \
    -display none \
    -s -S \
    -no-reboot
