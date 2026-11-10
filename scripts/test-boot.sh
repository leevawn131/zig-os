#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${PROJECT_ROOT}/build/zig-os.iso"
LOG_FILE="$(mktemp /tmp/zig-os-boot-XXXXXX.log)"

cleanup() {
    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        kill "${QEMU_PID}" 2>/dev/null || true
        wait "${QEMU_PID}" 2>/dev/null || true
    fi
    rm -f "${LOG_FILE}"
}
trap cleanup EXIT

echo "=================================================="
echo "          ZIG-OS PHASE 0 SMOKE TEST               "
echo "=================================================="

# Ensure ISO exists
if [[ ! -f "${ISO}" ]]; then
    echo "[TEST] Building bootable ISO..."
    "${PROJECT_ROOT}/scripts/build.sh"
fi

echo "[TEST] Launching QEMU in headless mode (serial log: ${LOG_FILE})..."
qemu-system-x86_64 \
    -M q35 \
    -m 256M \
    -cdrom "${ISO}" \
    -serial "file:${LOG_FILE}" \
    -display none \
    -no-reboot &
QEMU_PID=$!

echo "[TEST] Waiting for boot output (timeout 10s)..."
START_TIME=$(date +%s)
FOUND_PROMPT=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if grep -q "zig-os:~$" "${LOG_FILE}" 2>/dev/null; then
        FOUND_PROMPT=1
        break
    fi

    if [[ ${ELAPSED} -ge 10 ]]; then
        break
    fi

    # Verify QEMU is still running (Criterion F: no crashes or immediate reboots)
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "[TEST ERROR] QEMU terminated prematurely!"
        break
    fi

    sleep 0.2
done

echo ""
echo "--- CAPTURED SERIAL OUTPUT ---"
cat "${LOG_FILE}"
echo ""
echo "------------------------------"

# Verify QEMU is still running stably
if kill -0 "${QEMU_PID}" 2>/dev/null; then
    echo "[TEST PASS] Criterion F: QEMU is stably running in quiescent halt loop without crashing."
else
    echo "[TEST FAIL] Criterion F: QEMU exited unexpectedly."
    exit 1
fi

# Verify Acceptance Criteria output strings
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
        echo "[TEST CHECK FAIL] MISSING: '${STR}'"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
done

if [[ ${FAILED_CHECKS} -ne 0 ]]; then
    echo ""
    echo "[TEST RESULT] FAILED: ${FAILED_CHECKS} required strings missing."
    exit 1
fi

echo ""
echo "=================================================="
echo "    >>> ALL PHASE 0 ACCEPTANCE CRITERIA PASSED <<<"
echo "=================================================="
exit 0
