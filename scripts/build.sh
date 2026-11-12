#!/usr/bin/env bash
set -euo pipefail

# Canonical public build entrypoint: always compiles kernel via Zig build graph
# and packages a fresh verified ISO with consistent optimization selection.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"

resolve_optimize_from_args 1 "$@"
cd "${PROJECT_ROOT}"

command -v zig >/dev/null 2>&1 || {
    echo "Error: zig compiler not found" >&2
    exit 1
}

echo "[BUILD] Invoking Zig build pipeline (step: iso, optimization: ${ZIG_OS_SELECTED_OPTIMIZE})..."
exec zig build -Doptimize="${ZIG_OS_SELECTED_OPTIMIZE}" iso
