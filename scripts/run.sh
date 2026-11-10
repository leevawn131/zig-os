#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${PROJECT_ROOT}/build/zig-os.iso"

if [[ ! -f "${ISO}" ]]; then
    echo "[RUN] ISO not found. Building first..."
    "${PROJECT_ROOT}/scripts/build.sh"
fi

echo "[RUN] Launching QEMU (COM1 serial on stdio)..."
echo "Press Ctrl+A then X to exit QEMU."

DISPLAY_OPT="-display none"
if [[ -n "${DISPLAY:-}" && "${FORCE_HEADLESS:-0}" == "0" ]]; then
    # If X11/Wayland display is available and not forced headless, allow standard window
    DISPLAY_OPT=""
fi

exec qemu-system-x86_64 \
    -M q35 \
    -m 256M \
    -cdrom "${ISO}" \
    -serial stdio \
    ${DISPLAY_OPT} \
    -no-reboot
