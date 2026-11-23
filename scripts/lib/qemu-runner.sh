#!/usr/bin/env bash
set -euo pipefail

# Shared QEMU launcher and automated smoke / standalone Double Fault test runner.
# Runs provenance verification on the selected profile's packaged ISO immediately prior to invoking QEMU.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/provenance.sh
source "${SCRIPT_LIB_DIR}/provenance.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <run|debug|test-boot|test-df> [--optimize <mode>]" >&2
    exit 1
fi

MODE="$1"
shift
resolve_optimize_from_args 0 "$@"

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "[QEMU ERROR] qemu-system-x86_64 not found in PATH." >&2
    exit 1
}

case "${MODE}" in
    run|debug|test-boot)
        PROFILE="prod"
        ISO="${PROJECT_ROOT}/build/zig-os.iso"
        KERNEL_BIN="${PROJECT_ROOT}/zig-out/bin/kernel.elf"
        ;;
    test-df)
        PROFILE="df-test"
        ISO="${PROJECT_ROOT}/build/zig-os-df-test.iso"
        KERNEL_BIN="${PROJECT_ROOT}/zig-out/df-test/kernel-df-test.elf"
        ;;
    *)
        echo "[QEMU ERROR] Unknown mode '${MODE}'. Expected run, debug, test-boot, or test-df." >&2
        exit 1
        ;;
esac

verify_and_log_provenance "${PROJECT_ROOT}" "${ZIG_OS_SELECTED_OPTIMIZE}" "${PROFILE}"

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
        echo "          ZIG-OS PHASE 0/1 SMOKE TEST             "
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
            "[GDT] Kernel GDT, 64-bit TSS, and IST1-IST3 stacks initialized and verified."
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
        echo "    >>> ALL BOOT ACCEPTANCE CRITERIA PASSED <<<   "
        echo "=================================================="
        exit 0
        ;;
    test-df)
        command -v python3 >/dev/null 2>&1 || {
            echo "[DF-TEST ERROR] python3 is required for QMP HLT verification and serial forensic parsing." >&2
            exit 1
        }

        LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/zig-os-df-test-XXXXXX.log")"
        QMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zig-os-df-qmp-XXXXXX")"
        QMP_SOCK="${QMP_DIR}/qmp.sock"
        QEMU_PID=""

        cleanup_df() {
            if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
                kill "${QEMU_PID}" 2>/dev/null || true
                wait "${QEMU_PID}" 2>/dev/null || true
            fi
            rm -rf "${LOG_FILE}" "${QMP_DIR}"
        }
        trap cleanup_df EXIT

        echo "=================================================="
        echo "     ZIG-OS STANDALONE DOUBLE FAULT (#DF) TEST    "
        echo "=================================================="
        echo "[DF-TEST] Launching isolated QEMU (ISO: ${ISO}, serial log: ${LOG_FILE})..."

        qemu-system-x86_64 \
            -M q35 \
            -m 256M \
            -cdrom "${ISO}" \
            -serial "file:${LOG_FILE}" \
            -qmp "unix:${QMP_SOCK},server=on,wait=off" \
            -display none \
            -no-reboot &
        QEMU_PID=$!

        echo "[DF-TEST] Waiting for standalone #DF outcome (timeout 10s)..."
        START_TIME="$(date +%s)"
        while true; do
            CURRENT_TIME="$(date +%s)"
            ELAPSED=$((CURRENT_TIME - START_TIME))

            if grep -F -q "[DF-TEST] PASS:" "${LOG_FILE}" 2>/dev/null || \
               grep -F -q "[DF-TEST] FAIL:" "${LOG_FILE}" 2>/dev/null || \
               grep -F -q "[DF-TEST] INCONCLUSIVE:" "${LOG_FILE}" 2>/dev/null || \
               grep -F -q "[FATAL]" "${LOG_FILE}" 2>/dev/null; then
                sleep 0.3
                break
            fi

            if [[ ${ELAPSED} -ge 10 ]]; then
                echo "[DF-TEST ERROR] Timed out waiting for [DF-TEST] serial marker." >&2
                break
            fi

            if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
                echo "[DF-TEST ERROR] QEMU terminated prematurely (possible Triple Fault under -no-reboot)!" >&2
                break
            fi

            sleep 0.1
        done

        echo ""
        echo "--- CAPTURED DF-TEST SERIAL OUTPUT ---"
        cat "${LOG_FILE}" 2>/dev/null || true
        echo ""
        echo "--------------------------------------"

        FAILED_DF=0

        # Assertion A: QEMU process alive (`kill -0` ONLY proves host process survival, never guest HLT).
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            echo "[DF-TEST CHECK] QEMU process alive (kill -0): PASS"
            QEMU_ALIVE=1
        else
            echo "[DF-TEST CHECK] QEMU process alive (kill -0): FAIL" >&2
            QEMU_ALIVE=0
            FAILED_DF=$((FAILED_DF + 1))
        fi

        # Assertions B & C via QMP (VM runstate & QEMU 10.2.1 version-validated CPU#0 HLT/CPL/TR check).
        if [[ ${QEMU_ALIVE} -eq 1 ]]; then
            if ! python3 - "${QMP_SOCK}" <<'PYEOF'
import json
import os
import re
import socket
import sys
import time

sock_path = sys.argv[1]

def qmp_cmd(fp, obj):
    fp.write(json.dumps(obj) + "\n")
    fp.flush()
    while True:
        line = fp.readline()
        if not line:
            raise RuntimeError("QMP connection closed unexpectedly")
        msg = json.loads(line)
        if "event" not in msg:
            return msg

def parse_cpu0_halted_state(hmp_text):
    if not isinstance(hmp_text, str):
        return False, "HMP output is not a string"
    if not hmp_text.strip():
        return False, "empty HMP output"

    # Fail closed on non-printable/control or non-ASCII characters that could mask ambiguous tokens.
    for ch in hmp_text:
        code = ord(ch)
        if ch not in ("\r", "\n", "\t") and not (0x20 <= code <= 0x7E):
            return False, f"unexpected non-printable/non-ASCII character 0x{code:02x} in HMP output"

    lines = hmp_text.splitlines()
    cpu_heading_re = re.compile(r"^\s*CPU#(0|[1-9]\d*)\s*$")
    any_cpu_like_re = re.compile(r"^\s*CPU\b", re.IGNORECASE)
    headings = []
    for idx, line in enumerate(lines):
        m = cpu_heading_re.match(line)
        if m:
            headings.append((idx, m.group(1)))
        elif any_cpu_like_re.match(line) or "CPU#" in line.upper():
            return False, f"malformed or inline CPU heading at line {idx + 1}: {line.strip()!r}"

    if not headings:
        return False, "missing CPU#0 block (no CPU headings found)"

    if any(line.strip() for line in lines[: headings[0][0]]):
        return False, "unexpected non-empty content before first CPU heading"

    cpu0_indices = [idx for idx, cid in headings if cid == "0"]
    if len(cpu0_indices) != 1:
        return False, f"expected exactly 1 CPU#0 heading, found {len(cpu0_indices)}"

    start_idx = cpu0_indices[0] + 1
    end_idx = len(lines)
    for idx, _cid in headings:
        if idx > cpu0_indices[0]:
            end_idx = idx
            break

    block_lines = lines[start_idx:end_idx]
    if not any(line.strip() for line in block_lines):
        return False, "empty CPU#0 register block"

    # Reject split HLT/CPL/TR field aliases (e.g. "H LT=", "H L T=", "C P L=", "T R=", "T R =")
    # anywhere inside CPU#0 while requiring explicit left token boundaries so unrelated names/text match safely.
    split_field_patterns = (
        ("HLT", re.compile(r"(?<![A-Za-z0-9_])(?:H\s+L\s*T|H\s*L\s+T)\s*[:=]", re.IGNORECASE)),
        ("CPL", re.compile(r"(?<![A-Za-z0-9_])(?:C\s+P\s*L|C\s*P\s+L)\s*[:=]", re.IGNORECASE)),
        ("TR", re.compile(r"(?<![A-Za-z0-9_])T\s+R\s*[:=]", re.IGNORECASE)),
    )
    block_text = "\n".join(block_lines)
    for field_name, split_re in split_field_patterns:
        m_split = split_re.search(block_text)
        if m_split:
            return False, f"malformed whitespace-split {field_name} field inside CPU#0 block: {m_split.group(0).strip()!r}"

    token_tr_re = re.compile(r"(?<![A-Za-z])TR(?![A-Za-z])", re.IGNORECASE)
    tr_line_re = re.compile(r"^\s*TR\s*=\s*(.+)$")
    tr_sel_re = re.compile(r"^[0-9A-Fa-f]{4}$")
    hex16_re = re.compile(r"^[0-9A-Fa-f]{16}$")
    hex8_re = re.compile(r"^[0-9A-Fa-f]{8}$")
    dpl_re = re.compile(r"^DPL=[0-3]$")
    seg_type_re = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")

    hlt_re = re.compile(r"^HLT=([01])$")
    cpl_re = re.compile(r"^CPL=([0-3])$")
    rip_re = re.compile(r"^RIP=([0-9A-Fa-f]{16})$")
    rfl_re = re.compile(r"^RFL=([0-9A-Fa-f]{8})$")

    hlt_vals = []
    cpl_vals = []
    tr_vals = []
    rip_vals = []
    rfl_vals = []

    token_32bit_re = re.compile(r"(?<![A-Za-z])(?:EIP|EFL)(?![A-Za-z])", re.IGNORECASE)
    token_field_checks = (
        ("RIP", re.compile(r"(?<![A-Za-z])RIP(?![A-Za-z])", re.IGNORECASE), rip_re, rip_vals),
        ("RFL", re.compile(r"(?<![A-Za-z])RFL(?![A-Za-z])", re.IGNORECASE), rfl_re, rfl_vals),
        ("HLT", re.compile(r"(?<![A-Za-z])HLT(?![A-Za-z])", re.IGNORECASE), hlt_re, hlt_vals),
        ("CPL", re.compile(r"(?<![A-Za-z])CPL(?![A-Za-z])", re.IGNORECASE), cpl_re, cpl_vals),
    )

    for rel_idx, raw_line in enumerate(block_lines, 1):
        stripped = raw_line.strip()
        if not stripped:
            continue
        if "=" not in stripped:
            return False, f"unrecognized non-register line inside CPU#0 block (line {rel_idx}): {stripped!r}"

        if token_tr_re.search(raw_line):
            m_tr = tr_line_re.match(raw_line)
            if not m_tr:
                return False, f"malformed or non-leading TR field inside CPU#0 block: {stripped!r}"
            rest = m_tr.group(1)
            if token_tr_re.search(rest):
                return False, f"duplicate or unexpected TR token on TR line inside CPU#0 block: {stripped!r}"
            rest_tokens = rest.split()
            if not rest_tokens or not tr_sel_re.fullmatch(rest_tokens[0]):
                return False, f"malformed TR selector value inside CPU#0 block: {stripped!r}"
            if len(rest_tokens) == 1:
                pass
            elif len(rest_tokens) in (4, 5, 6):
                if not (
                    hex16_re.fullmatch(rest_tokens[1])
                    and hex8_re.fullmatch(rest_tokens[2])
                    and hex8_re.fullmatch(rest_tokens[3])
                ):
                    return False, f"malformed TR segment descriptor fields inside CPU#0 block: {stripped!r}"
                if len(rest_tokens) >= 5 and not dpl_re.fullmatch(rest_tokens[4]):
                    return False, f"malformed TR DPL field inside CPU#0 block: {stripped!r}"
                if len(rest_tokens) == 6 and not seg_type_re.fullmatch(rest_tokens[5]):
                    return False, f"malformed TR segment type inside CPU#0 block: {stripped!r}"
            else:
                return False, f"unexpected trailing tokens on TR line inside CPU#0 block: {stripped!r}"
            tr_vals.append(rest_tokens[0])
            continue

        for tok in stripped.split():
            if token_32bit_re.search(tok):
                return False, f"unsupported 32-bit/real-mode token inside CPU#0 block: {tok!r}"
            if token_tr_re.search(tok):
                return False, f"malformed or non-leading TR token inside CPU#0 block: {tok!r}"
            for field_name, match_re, token_re, bucket in token_field_checks:
                if match_re.search(tok):
                    m = token_re.fullmatch(tok)
                    if not m:
                        return False, f"malformed {field_name} token inside CPU#0 block: {tok!r}"
                    bucket.append(m.group(1))

    if len(rip_vals) != 1:
        return False, f"expected exactly 1 valid 64-bit RIP= field inside CPU#0 block, found {len(rip_vals)}"
    if len(rfl_vals) != 1:
        return False, f"expected exactly 1 valid 64-bit RFL= field inside CPU#0 block, found {len(rfl_vals)}"

    if len(hlt_vals) != 1:
        return False, f"expected exactly 1 HLT= field inside CPU#0 block, found {len(hlt_vals)} ({hlt_vals})"
    if hlt_vals[0] != "1":
        return False, f"unexpected HLT value inside CPU#0 block: HLT={hlt_vals[0]}"

    if len(cpl_vals) != 1:
        return False, f"expected exactly 1 CPL= field inside CPU#0 block, found {len(cpl_vals)} ({cpl_vals})"
    if cpl_vals[0] != "0":
        return False, f"unexpected CPL value inside CPU#0 block: CPL={cpl_vals[0]}"

    if len(tr_vals) != 1:
        return False, f"expected exactly 1 TR= field inside CPU#0 block, found {len(tr_vals)} ({tr_vals})"
    if tr_vals[0].lower() != "0048":
        return False, f"unexpected TR= selector inside CPU#0 block: TR={tr_vals[0]}"

    return True, "HLT=1, CPL=0, TR=0048"

sock = None
for _ in range(40):
    if os.path.exists(sock_path):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3.0)
            s.connect(sock_path)
            sock = s
            break
        except OSError:
            pass
    time.sleep(0.05)

if sock is None:
    print("[DF-TEST CHECK] QEMU VM runstate: FAIL (unable to connect to QMP socket)", file=sys.stderr)
    print("[DF-TEST CHECK] Guest BSP vCPU halted in expected state: FAIL (no QMP connection)", file=sys.stderr)
    sys.exit(1)

try:
    fp = sock.makefile("rw", encoding="utf-8", newline="\n")
    greeting = json.loads(fp.readline())
    qemu_ver = greeting.get("QMP", {}).get("version", {}).get("qemu", {})
    major = qemu_ver.get("major")
    minor = qemu_ver.get("minor")
    micro = qemu_ver.get("micro")

    cap_resp = qmp_cmd(fp, {"execute": "qmp_capabilities"})
    if "return" not in cap_resp:
        print(f"[DF-TEST CHECK] QEMU VM runstate: FAIL (qmp_capabilities error: {cap_resp})", file=sys.stderr)
        print("[DF-TEST CHECK] Guest BSP vCPU halted in expected state: FAIL (QMP handshake failed)", file=sys.stderr)
        sys.exit(1)

    status_resp = qmp_cmd(fp, {"execute": "query-status"})
    status_ret = status_resp.get("return", {})
    vm_running = (status_ret.get("running") is True and status_ret.get("status") == "running")

    cpus_resp = qmp_cmd(fp, {"execute": "query-cpus-fast"})
    cpus_ret = cpus_resp.get("return", [])
    has_bsp = any(c.get("cpu-index") == 0 and c.get("target") == "x86_64" for c in cpus_ret)

    if vm_running and has_bsp:
        print("[DF-TEST CHECK] QEMU VM runstate (QMP query-status=running, BSP cpu-index=0): PASS")
    else:
        print(
            f"[DF-TEST CHECK] QEMU VM runstate: FAIL (status={status_ret}, bsp={has_bsp})",
            file=sys.stderr,
        )
        print("[DF-TEST CHECK] Guest BSP vCPU halted in expected state: FAIL (VM runstate invalid)", file=sys.stderr)
        sys.exit(1)

    # Exact allowlist policy: only QEMU 10.2.1 is verified for HMP `info registers` parsing.
    try:
        if type(major) is not int or type(minor) is not int or type(micro) is not int:
            raise AssertionError(f"malformed QEMU version tuple: {qemu_ver}")
        assert major == 10
        assert minor == 2
        assert micro == 1
        if major != 10 or minor != 2 or micro != 1:
            raise AssertionError("unsupported QEMU version")
    except AssertionError:
        print(
            f"[DF-TEST CHECK] Guest BSP vCPU halted in expected state: FAIL (unsupported QEMU version {major}.{minor}.{micro}; allowlist requires exact QEMU 10.2.1)",
            file=sys.stderr,
        )
        sys.exit(1)

    # Poll briefly until BSP reaches HLT=1 in `cpu.haltLoop()`.
    last_reason = "no poll attempts completed"
    for _ in range(25):
        hmp_resp = qmp_cmd(fp, {"execute": "human-monitor-command", "arguments": {"command-line": "info registers"}})
        if "return" not in hmp_resp or not isinstance(hmp_resp.get("return"), str):
            print(
                f"[DF-TEST CHECK] Guest BSP vCPU halted in expected state (QEMU 10.2.1 HMP CPU#0 block): FAIL (malformed QMP HMP response: {hmp_resp})",
                file=sys.stderr,
            )
            sys.exit(1)
        ok, detail = parse_cpu0_halted_state(hmp_resp["return"])
        if ok:
            print(f"[DF-TEST CHECK] Guest BSP vCPU halted in expected state (QEMU 10.2.1 HMP CPU#0 block: {detail}): PASS")
            sys.exit(0)
        last_reason = detail
        if detail != "unexpected HLT value inside CPU#0 block: HLT=0":
            print(
                f"[DF-TEST CHECK] Guest BSP vCPU halted in expected state (QEMU 10.2.1 HMP CPU#0 block): FAIL ({detail})",
                file=sys.stderr,
            )
            sys.exit(1)
        time.sleep(0.1)

    print(
        f"[DF-TEST CHECK] Guest BSP vCPU halted in expected state (QEMU 10.2.1 HMP CPU#0 block): FAIL ({last_reason})",
        file=sys.stderr,
    )
    sys.exit(1)
finally:
    sock.close()
PYEOF
            then
                FAILED_DF=$((FAILED_DF + 1))
            fi
        else
            echo "[DF-TEST CHECK] QEMU VM runstate: FAIL (QEMU process exited)" >&2
            echo "[DF-TEST CHECK] Guest BSP vCPU halted in expected state: FAIL (QEMU process exited)" >&2
        fi

        # Serial forensic assertions
        if ! python3 - "${LOG_FILE}" <<'PYEOF'
import re
import sys

log_path = sys.argv[1]
text = open(log_path, "r", encoding="utf-8", errors="replace").read()

required = [
    "[DF-TEST] PASS: Double Fault caught on IST1 stack.",
    "[EXCEPTION] Vector: 8 (#DF: Double Fault)",
    "Error Code: 0x0000000000000000",
]
errors = []
for marker in required:
    if marker in text:
        print(f"[DF-TEST CHECK] Serial contains '{marker}': PASS")
    else:
        print(f"[DF-TEST CHECK] Serial MISSING '{marker}': FAIL", file=sys.stderr)
        errors.append(marker)

for forbidden in ["[DF-TEST] FAIL:", "[DF-TEST] INCONCLUSIVE:", "[FATAL]"]:
    if forbidden in text:
        print(f"[DF-TEST CHECK] Serial contains forbidden marker '{forbidden}': FAIL", file=sys.stderr)
        errors.append(forbidden)

df_idx = text.find("[DF-TEST]")
if df_idx == -1:
    print("[DF-TEST CHECK] Missing '[DF-TEST]' section in serial log: FAIL", file=sys.stderr)
    errors.append("no_df_section")
else:
    tail = text[df_idx:]
    for bad in ["#UD", "#PF", "Vector: 6 ", "Vector: 14 "]:
        if bad in tail:
            print(f"[DF-TEST CHECK] Forbidden '{bad}' appeared after '[DF-TEST]': FAIL", file=sys.stderr)
            errors.append(bad)

    m_cr2 = re.search(r"\[DF-TEST\] Faulting Linear Address \(CR2\):\s*(0x[0-9a-fA-F]+)", tail)
    if not m_cr2:
        print("[DF-TEST CHECK] Missing DF-TEST CR2 value: FAIL", file=sys.stderr)
        errors.append("missing_cr2")
    else:
        cr2 = int(m_cr2.group(1), 16)
        if 0x00000042000107D0 <= cr2 < 0x0000004200010800:
            print(f"[DF-TEST CHECK] DF-TEST CR2={hex(cr2)} in expected single-page window: PASS")
        else:
            print(f"[DF-TEST CHECK] DF-TEST CR2={hex(cr2)} out of expected window [0x42000107d0, 0x4200010800): FAIL", file=sys.stderr)
            errors.append("bad_cr2")

    m_rsp = re.search(r"RSP:\s*(0x[0-9a-fA-F]+)", tail)
    if not m_rsp:
        print("[DF-TEST CHECK] Missing saved RSP in #DF frame: FAIL", file=sys.stderr)
        errors.append("missing_rsp")
    else:
        rsp = int(m_rsp.group(1), 16)
        if 0x00000042000107D0 <= rsp <= 0x0000004200010800:
            print(f"[DF-TEST CHECK] Saved RSP={hex(rsp)} in expected single-page window: PASS")
        else:
            print(f"[DF-TEST CHECK] Saved RSP={hex(rsp)} out of expected window [0x42000107d0, 0x4200010800]: FAIL", file=sys.stderr)
            errors.append("bad_rsp")

sys.exit(1 if errors else 0)
PYEOF
        then
            FAILED_DF=$((FAILED_DF + 1))
        fi

        if [[ ${FAILED_DF} -ne 0 ]]; then
            echo ""
            echo "[DF-TEST RESULT] FAILED (${FAILED_DF} check group(s) failed)." >&2
            exit 1
        fi

        echo ""
        echo "=================================================="
        echo "    >>> ALL STANDALONE DF-TEST CRITERIA PASSED <<<"
        echo "=================================================="
        exit 0
        ;;
esac
