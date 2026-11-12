#!/usr/bin/env bash
# Shared shell helpers for optimization mode selection and Git provenance metadata.

normalize_optimize_mode() {
    local raw="${1:-}"
    case "${raw}" in
        Debug|debug)
            echo "Debug"
            ;;
        ReleaseSafe|safe)
            echo "ReleaseSafe"
            ;;
        ReleaseFast|fast)
            echo "ReleaseFast"
            ;;
        ReleaseSmall|small)
            echo "ReleaseSmall"
            ;;
        *)
            echo "[ERROR] Unsupported optimization mode '${raw}'. Expected Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall." >&2
            return 1
            ;;
    esac
}

resolve_optimize_from_args() {
    local allow_iso_positional="${1:-0}"
    shift || true

    local raw_opt=""
    local saw_iso=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --optimize|-Doptimize)
                if [[ $# -lt 2 ]]; then
                    echo "[ERROR] Missing value for $1." >&2
                    return 1
                fi
                raw_opt="$2"
                shift 2
                ;;
            --optimize=*)
                raw_opt="${1#--optimize=}"
                shift
                ;;
            -Doptimize=*)
                raw_opt="${1#-Doptimize=}"
                shift
                ;;
            iso)
                if [[ "${allow_iso_positional}" == "1" && "${saw_iso}" -eq 0 ]]; then
                    saw_iso=1
                    shift
                else
                    echo "[ERROR] Unexpected argument: $1" >&2
                    return 1
                fi
                ;;
            *)
                echo "[ERROR] Unrecognized argument: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ -z "${raw_opt}" ]]; then
        raw_opt="${ZIG_OS_OPTIMIZE:-${OPTIMIZE:-ReleaseSafe}}"
    fi

    ZIG_OS_SELECTED_OPTIMIZE="$(normalize_optimize_mode "${raw_opt}")" || return 1
    export ZIG_OS_SELECTED_OPTIMIZE
}

collect_git_metadata() {
    local repo_root="$1"
    ZIG_OS_GIT_COMMIT="unavailable"
    ZIG_OS_GIT_DIRTY="unavailable"

    if command -v git >/dev/null 2>&1 && git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ZIG_OS_GIT_COMMIT="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo 'unknown')"
        if [[ -n "$(git -C "${repo_root}" status --porcelain 2>/dev/null)" ]]; then
            ZIG_OS_GIT_DIRTY="dirty"
        else
            ZIG_OS_GIT_DIRTY="clean"
        fi
    fi

    export ZIG_OS_GIT_COMMIT ZIG_OS_GIT_DIRTY
}
