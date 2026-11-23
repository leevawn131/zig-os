#!/usr/bin/env bash
# Shared ISO and kernel ELF provenance verification helper.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

verify_and_log_provenance() {
    local project_root="$1"
    local optimize_mode="$2"
    local profile="${3:-prod}"

    local kernel_bin iso_root_kernel iso_file tmp_prefix
    local label_bin label_root label_iso
    case "${profile}" in
        prod)
            kernel_bin="${project_root}/zig-out/bin/kernel.elf"
            iso_root_kernel="${project_root}/build/iso_root/boot/kernel.elf"
            iso_file="${project_root}/build/zig-os.iso"
            tmp_prefix="zig-os-provenance-prod"
            label_bin="zig-out/bin/kernel.elf"
            label_root="build/iso_root/boot/kernel.elf"
            label_iso="build/zig-os.iso"
            ;;
        df-test)
            kernel_bin="${project_root}/zig-out/df-test/kernel-df-test.elf"
            iso_root_kernel="${project_root}/build/df-test/iso_root/boot/kernel.elf"
            iso_file="${project_root}/build/zig-os-df-test.iso"
            tmp_prefix="zig-os-provenance-df-test"
            label_bin="zig-out/df-test/kernel-df-test.elf"
            label_root="build/df-test/iso_root/boot/kernel.elf"
            label_iso="build/zig-os-df-test.iso"
            ;;
        *)
            echo "[PROVENANCE ERROR] Unsupported provenance profile '${profile}'. Expected 'prod' or 'df-test'." >&2
            return 1
            ;;
    esac

    command -v xorriso >/dev/null 2>&1 || {
        echo "[PROVENANCE ERROR] xorriso not found in PATH." >&2
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        echo "[PROVENANCE ERROR] sha256sum not found in PATH." >&2
        return 1
    }

    if [[ ! -f "${kernel_bin}" || ! -s "${kernel_bin}" ]]; then
        echo "[PROVENANCE ERROR] Built kernel ELF missing or empty: ${kernel_bin}" >&2
        return 1
    fi
    if [[ ! -f "${iso_file}" || ! -s "${iso_file}" ]]; then
        echo "[PROVENANCE ERROR] Bootable ISO missing or empty: ${iso_file}" >&2
        return 1
    fi
    if [[ ! -f "${iso_root_kernel}" || ! -s "${iso_root_kernel}" ]]; then
        echo "[PROVENANCE ERROR] ISO staging kernel ELF missing or empty: ${iso_root_kernel}" >&2
        return 1
    fi

    # Verify in a subshell so temporary files are always cleaned up before any `exec`.
    (
        set -euo pipefail
        local prov_tmp
        prov_tmp="$(mktemp -d "${TMPDIR:-/tmp}/${tmp_prefix}-XXXXXX")"
        cleanup_prov() {
            rm -rf "${prov_tmp}"
        }
        trap cleanup_prov EXIT

        local extracted_kernel="${prov_tmp}/kernel.elf"
        local xorriso_log="${prov_tmp}/xorriso.log"

        if ! xorriso -osirrox on -indev "${iso_file}" -extract /boot/kernel.elf "${extracted_kernel}" >"${xorriso_log}" 2>&1; then
            echo "[PROVENANCE ERROR] Failed to extract /boot/kernel.elf from ${iso_file} with xorriso:" >&2
            cat "${xorriso_log}" >&2
            exit 1
        fi
        if [[ ! -f "${extracted_kernel}" || ! -s "${extracted_kernel}" ]]; then
            echo "[PROVENANCE ERROR] Extracted /boot/kernel.elf is missing or empty." >&2
            exit 1
        fi

        local hash_zig_out hash_iso_root hash_extracted hash_iso
        hash_zig_out="$(sha256sum "${kernel_bin}" | awk '{print $1}')"
        hash_iso_root="$(sha256sum "${iso_root_kernel}" | awk '{print $1}')"
        hash_extracted="$(sha256sum "${extracted_kernel}" | awk '{print $1}')"
        hash_iso="$(sha256sum "${iso_file}" | awk '{print $1}')"

        collect_git_metadata "${project_root}"

        echo "[PROVENANCE] Profile:                        ${profile}"
        echo "[PROVENANCE] Optimization mode:              ${optimize_mode}"
        echo "[PROVENANCE] Git commit:                     ${ZIG_OS_GIT_COMMIT}"
        echo "[PROVENANCE] Working tree status:            ${ZIG_OS_GIT_DIRTY}"
        echo "[PROVENANCE] SHA-256 ${label_bin}: ${hash_zig_out}"
        echo "[PROVENANCE] SHA-256 ${label_root}: ${hash_iso_root}"
        echo "[PROVENANCE] SHA-256 ISO:/boot/kernel.elf:   ${hash_extracted}"
        echo "[PROVENANCE] SHA-256 ${label_iso}: ${hash_iso}"

        if [[ -z "${hash_zig_out}" || -z "${hash_iso_root}" || -z "${hash_extracted}" || -z "${hash_iso}" ]]; then
            echo "[PROVENANCE ERROR] Empty SHA-256 digest computed." >&2
            exit 1
        fi

        if [[ "${hash_zig_out}" != "${hash_iso_root}" || "${hash_zig_out}" != "${hash_extracted}" ]]; then
            echo "[PROVENANCE ERROR] Kernel ELF SHA-256 mismatch! Refusing to proceed." >&2
            echo "  ${label_bin}  = ${hash_zig_out}" >&2
            echo "  ${label_root} = ${hash_iso_root}" >&2
            echo "  ISO:/boot/kernel.elf = ${hash_extracted}" >&2
            exit 1
        fi

        echo "[PROVENANCE] PASS (${profile}): All three kernel ELF SHA-256 digests match identically."
    )
}
