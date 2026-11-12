#!/usr/bin/env bash
set -euo pipefail

# Dedicated ISO packaging helper invoked by the Zig build graph after kernel installation.
# Does not invoke `zig build` recursively.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
ISO_ROOT="${BUILD_DIR}/iso_root"
OUTPUT_ISO="${BUILD_DIR}/zig-os.iso"
LIMINE_DIR="${PROJECT_ROOT}/boot/limine"
KERNEL_BIN="${PROJECT_ROOT}/zig-out/bin/kernel.elf"

# shellcheck source=scripts/lib/provenance.sh
source "${PROJECT_ROOT}/scripts/lib/provenance.sh"

resolve_optimize_from_args 0 "$@"
cd "${PROJECT_ROOT}"

echo "[ISO] Verifying packaging prerequisites (Optimization mode: ${ZIG_OS_SELECTED_OPTIMIZE})..."
command -v xorriso >/dev/null 2>&1 || { echo "Error: xorriso not found" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Error: sha256sum not found" >&2; exit 1; }
command -v make >/dev/null 2>&1 || { echo "Error: make not found" >&2; exit 1; }

if [[ ! -x "${LIMINE_DIR}/limine" ]]; then
    echo "[ISO] Building Limine host installer..."
    make -C "${LIMINE_DIR}"
fi

if [[ ! -f "${KERNEL_BIN}" || ! -s "${KERNEL_BIN}" ]]; then
    echo "Error: Kernel binary not found or empty at ${KERNEL_BIN}" >&2
    exit 1
fi

collect_git_metadata "${PROJECT_ROOT}"
echo "[ISO] Build metadata: commit=${ZIG_OS_GIT_COMMIT} tree=${ZIG_OS_GIT_DIRTY} optimize=${ZIG_OS_SELECTED_OPTIMIZE}"

# Refresh only build/iso_root rather than destroying all of build/.
if [[ "${ISO_ROOT}" != "${BUILD_DIR}/iso_root" ]]; then
    echo "Error: Refusing to clean unexpected ISO_ROOT path: ${ISO_ROOT}" >&2
    exit 1
fi

echo "[ISO] Preparing ISO root filesystem..."
rm -rf "${ISO_ROOT}"
mkdir -p "${ISO_ROOT}/boot/limine"
mkdir -p "${ISO_ROOT}/EFI/BOOT"
mkdir -p "${BUILD_DIR}"

cp "${LIMINE_DIR}/limine.conf" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-bios.sys" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-bios-cd.bin" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/limine-uefi-cd.bin" "${ISO_ROOT}/boot/limine/"
cp "${LIMINE_DIR}/BOOTX64.EFI" "${ISO_ROOT}/EFI/BOOT/"
cp "${KERNEL_BIN}" "${ISO_ROOT}/boot/kernel.elf"

PKG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/zig-os-pkg-XXXXXX")"
cleanup_pkg() {
    rm -rf "${PKG_TMP}"
}
trap cleanup_pkg EXIT

TMP_ISO="${PKG_TMP}/zig-os.iso"

echo "[ISO] Generating hybrid bootable ISO with xorriso..."
xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "${ISO_ROOT}" -o "${TMP_ISO}" 2>&1 | { grep -v "xorriso : NOTE :" || [[ $? -eq 1 ]]; }

echo "[ISO] Installing Limine BIOS boot record to ISO..."
"${LIMINE_DIR}/limine" bios-install "${TMP_ISO}"

mv -f "${TMP_ISO}" "${OUTPUT_ISO}"

echo "[ISO] Successfully generated bootable ISO: ${OUTPUT_ISO}"
ls -lh "${OUTPUT_ISO}"

verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}"
