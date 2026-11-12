#!/usr/bin/env bash
set -euo pipefail

# Shared QEMU launcher and Phase 0 smoke-test runner.
# Runs provenance verification on the packaged ISO immediately prior to invoking QEMU.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
ISO="${PROJECT_ROOT}/build/zig-os.iso"
KERNEL_BIN="${PROJECT_ROOT}/zig-out/bin/kernel.elf"

# shellcheck source=scripts/lib/provenance.sh
source "${SCRIPT_LIB_DIR}/provenance.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <run|debug|test-boot> [--optimize <mode>]" >&2
    exit 1
fi

MODE="$1"
shift
resolve_optimize_from_args 0 "$@"

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "[QEMU ERROR] qemu-system-x86_64 not found in PATH." >&2
    exit 1
}

verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}"

case "${MODE}" in
    run)
        echo "[RUN] Launching QEMU (COM1 serial on stdio, Optimization: ${ZIG_OS_SELECTED_OPTIMIZE})..."
        echo "Press Ctrl+A then X to exit QEMU."

        DISPLAY_ARGS=(-display none)
        if [[ -n "${DISPLAY:-}" && "${FORCE_HEADLESS:-0}" == "0" ]]; then
            DISPLAY_ARGS=()
        fi

        exec qemu-system-x86_64 \
            -M q35 \
            -m 256M \
            -cdrom "${ISO}" \
            -serial stdio \
            "${DISPLAY_ARGS[@]}" \
            -no-reboot
        ;;
    debug)
        echo "[DEBUG] Starting QEMU with GDB stub on localhost:1234 (Optimization: ${ZIG_OS_SELECTED_OPTIMIZE})..."
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
        ;;
    test-boot)
        LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/zig-os-boot-XXXXXX.log")"
        QEMU_PID=""

        cleanup() {
            if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
                kill "${QEMU_PID}" 2>/dev/null || true
                wait "${QEMU_PID}" 2>/dev/null || true
            fi
            rm -f "${LOG_FILE}"
        }
        trap cleanup EXIT

        echo "=================================================="
        echo "          ZIG-OS PHASE 0 SMOKE TEST               "
        echo "=================================================="
        echo "[TEST] Launching QEMU in headless mode (Optimization: ${ZIG_OS_SELECTED_OPTIMIZE}, serial log: ${LOG_FILE})..."

        qemu-system-x86_64 \
            -M q35 \
            -m 256M \
            -cdrom "${ISO}" \
            -serial "file:${LOG_FILE}" \
            -display none \
            -no-reboot &
        QEMU_PID=$!

        echo "[TEST] Waiting for boot output (timeout 10s)..."
        START_TIME="$(date +%s)"
        FOUND_PROMPT=0

        while true; do
            CURRENT_TIME="$(date +%s)"
            ELAPSED=$((CURRENT_TIME - START_TIME))

            if grep -F -q "zig-os:~$" "${LOG_FILE}" 2>/dev/null; then
                FOUND_PROMPT=1
                sleep 0.2
                break
            fi

            if [[ ${ELAPSED} -ge 10 ]]; then
                break
            fi

            if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
                echo "[TEST ERROR] QEMU terminated prematurely!" >&2
                break
            fi

            sleep 0.2
        done

        echo ""
        echo "--- CAPTURED SERIAL OUTPUT ---"
        cat "${LOG_FILE}" 2>/dev/null || true
        echo ""
        echo "------------------------------"

        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            echo "[TEST PASS] Criterion F: QEMU is stably running in quiescent halt loop without crashing."
        else
            echo "[TEST FAIL] Criterion F: QEMU exited unexpectedly." >&2
            exit 1
        fi

        if [[ ${FOUND_PROMPT} -ne 1 ]]; then
            echo "[TEST WARN] Boot prompt did not appear before timeout check." >&2
        fi

        REQUIRED_STRINGS=(
            "===================================="
            "ZIG-OS v0.1"
            "[BOOT] Limine boot protocol initialized."
            "[CPU] Architecture: x86_64"
            "[KERNEL] Zig kernel entry reached."
            "[MEMORY] Bootloader memory map received."
            "[IDT] 256 interrupt gates configured and verified."
            "[PMM] Physical frame allocator initialized and verified."
            "[VMM] 4-level paging and translation primitives verified."
            "[HEAP] Dynamic memory allocator initialized and verified."
            "[STATUS] Kernel initialization complete."
            "zig-os:~$"
        )

        FAILED_CHECKS=0
        for STR in "${REQUIRED_STRINGS[@]}"; do
            if grep -F -q "${STR}" "${LOG_FILE}"; then
                echo "[TEST CHECK PASS] Found: '${STR}'"
            else
                echo "[TEST CHECK FAIL] MISSING: '${STR}'" >&2
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
            fi
        done

        if [[ ${FAILED_CHECKS} -ne 0 ]]; then
            echo ""
            echo "[TEST RESULT] FAILED: ${FAILED_CHECKS} required strings missing." >&2
            exit 1
        fi

        echo ""
        echo "=================================================="
        echo "    >>> ALL PHASE 0 ACCEPTANCE CRITERIA PASSED <<<"
        echo "=================================================="
        exit 0
        ;;
    *)
        echo "[QEMU ERROR] Unknown mode '${MODE}'. Expected run, debug, or test-boot." >&2
        exit 1
        ;;
esac
