#!/usr/bin/env bash
set -euo pipefail

# Base directories
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
ISO_ROOT="${BUILD_DIR}/iso_root"
OUTPUT_ISO="${BUILD_DIR}/zig-os.iso"
LIMINE_DIR="${PROJECT_ROOT}/boot/limine"
KERNEL_BIN="${PROJECT_ROOT}/zig-out/bin/kernel.elf"

cd "${PROJECT_ROOT}"

echo "[BUILD] Verifying prerequisites..."
command -v zig >/dev/null 2>&1 || { echo "Error: zig compiler not found" >&2; exit 1; }
command -v xorriso >/dev/null 2>&1 || { echo "Error: xorriso not found" >&2; exit 1; }

# Step 1: Ensure host limine installer is built
if [[ ! -x "${LIMINE_DIR}/limine" ]]; then
    echo "[BUILD] Building Limine host installer..."
    make -C "${LIMINE_DIR}"
fi

# Step 2: Compile kernel if needed
if [[ ! -f "${KERNEL_BIN}" || "${1:-}" != "iso" ]]; then
    echo "[BUILD] Compiling ZIG-OS kernel via Zig build system..."
    zig build -Doptimize=ReleaseSafe
fi

if [[ ! -f "${KERNEL_BIN}" ]]; then
    echo "Error: Kernel binary not generated at ${KERNEL_BIN}" >&2
    exit 1
fi

echo "[BUILD] Preparing ISO root filesystem..."
rm -rf "${ISO_ROOT}"
mkdir -p "${ISO_ROOT}/boot/limine"
mkdir -p "${ISO_ROOT}/EFI/BOOT"

# Copy Limine components
cp "${LIMINE_DIR}/limine.conf" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-bios.sys" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-bios-cd.bin" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-uefi-cd.bin" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/BOOTX64.EFI" "${ISO_ROOT}/EFI/BOOT/"

# Copy Kernel
cp "${KERNEL_BIN}" "${ISO_ROOT}/boot/kernel.elf"

echo "[BUILD] Generating hybrid bootable ISO with xorriso..."
mkdir -p "${BUILD_DIR}"
xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "${ISO_ROOT}" -o "${OUTPUT_ISO}" 2>&1 | grep -v "xorriso : NOTE :"

echo "[BUILD] Installing Limine BIOS boot record to ISO..."
"${LIMINE_DIR}/limine" bios-install "${OUTPUT_ISO}"

echo "[BUILD] Successfully generated bootable ISO: ${OUTPUT_ISO}"
ls -lh "${OUTPUT_ISO}"
