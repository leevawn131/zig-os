#!/usr/bin/env python3
"""
ZIG-OS Automated Boot Smoke Test Runner.
Executes QEMU with the generated bootable ISO and validates COM1 serial output against acceptance criteria.
"""

import os
import subprocess
import sys
import tempfile
import time

EXPECTED_BOOT_STRINGS = [
    "====================================",
    "ZIG-OS v0.1",
    "[BOOT] Limine boot protocol initialized.",
    "[CPU] Architecture: x86_64",
    "[KERNEL] Zig kernel entry reached.",
    "[MEMORY] Bootloader memory map received.",
    "[STATUS] Kernel initialization complete.",
    "zig-os:~$"
]

def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    iso_path = os.path.join(repo_root, "build", "zig-os.iso")

    if not os.path.exists(iso_path):
        print(f"[TEST] ISO not found at {iso_path}. Running build script...")
        build_res = subprocess.run(["bash", os.path.join(repo_root, "scripts", "build.sh")], cwd=repo_root)
        if build_res.returncode != 0:
            print("[TEST ERROR] ISO build failed.", file=sys.stderr)
            return 1

    with tempfile.NamedTemporaryFile(prefix="zig-os-serial-", suffix=".log", delete=False) as tf:
        log_path = tf.name

    print(f"[TEST] Booting ZIG-OS in QEMU (serial log: {log_path})...")

    qemu_cmd = [
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "256M",
        "-cdrom", iso_path,
        "-serial", f"file:{log_path}",
        "-display", "none",
        "-no-reboot"
    ]

    proc = subprocess.Popen(qemu_cmd)
    start_time = time.time()
    success = False

    try:
        while time.time() - start_time < 10.0:
            if os.path.exists(log_path):
                with open(log_path, "r", errors="replace") as f:
                    content = f.read()
                if "zig-os:~$" in content:
                    success = True
                    break

            if proc.poll() is not None:
                print(f"[TEST ERROR] QEMU terminated unexpectedly with code {proc.returncode}!", file=sys.stderr)
                break

            time.sleep(0.2)

        # Verify QEMU is still alive (Criterion F: stability check)
        if proc.poll() is not None:
            print("[TEST FAIL] Criterion F failed: QEMU did not remain running stably.", file=sys.stderr)
            return 1

        with open(log_path, "r", errors="replace") as f:
            captured = f.read()

        print("\n=== Captured Serial Output ===")
        print(captured)
        print("==============================\n")

        missing = []
        for expected in EXPECTED_BOOT_STRINGS:
            if expected not in captured:
                missing.append(expected)

        if missing:
            print(f"[TEST FAIL] Missing required boot markers:\n" + "\n".join(f"  - {m}" for m in missing), file=sys.stderr)
            return 1

        print("[TEST PASS] All Phase 0 Acceptance Criteria verified successfully!")
        return 0

    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        if os.path.exists(log_path):
            os.remove(log_path)

if __name__ == "__main__":
    sys.exit(main())
