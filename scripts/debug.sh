#!/usr/bin/env bash
set -euo pipefail

# Canonical public debug entrypoint: always triggers a fresh build via Zig
# before verifying ISO provenance and launching QEMU waiting for GDB on :1234.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"

resolve_optimize_from_args 0 "$@"
cd "${PROJECT_ROOT}"

command -v zig >/dev/null 2>&1 || {
    echo "Error: zig compiler not found" >&2
    exit 1
}

echo "[DEBUG] Triggering fresh build before starting QEMU GDB session (optimization: ${ZIG_OS_SELECTED_OPTIMIZE})..."
zig build -Doptimize="${ZIG_OS_SELECTED_OPTIMIZE}" iso

exec bash "${PROJECT_ROOT}/scripts/lib/qemu-runner.sh" debug --optimize "${ZIG_OS_SELECTED_OPTIMIZE}"
