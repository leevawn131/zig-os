#!/usr/bin/env python3
"""
ZIG-OS Automated Boot Smoke Test Runner.
Delegates directly to the canonical fresh-build boot test script (scripts/test-boot.sh)
so optimization defaults, fresh-build enforcement, provenance verification, and serial checks
cannot drift or be bypassed.
"""

import argparse
import os
import subprocess
import sys

OPTIMIZE_ALIASES = {
    "Debug": "Debug",
    "debug": "Debug",
    "ReleaseSafe": "ReleaseSafe",
    "safe": "ReleaseSafe",
    "ReleaseFast": "ReleaseFast",
    "fast": "ReleaseFast",
    "ReleaseSmall": "ReleaseSmall",
    "small": "ReleaseSmall",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build fresh ZIG-OS ISO, verify artifact provenance, and run QEMU smoke test."
    )
    parser.add_argument(
        "--optimize",
        "-Doptimize",
        dest="optimize",
        default=None,
        help="Optimization mode: Debug, ReleaseSafe (default), ReleaseFast, or ReleaseSmall.",
    )
    return parser.parse_args(argv)


def normalize_optimize(raw: str) -> str:
    canonical = OPTIMIZE_ALIASES.get(raw)
    if canonical is None:
        raise ValueError(
            f"Unsupported optimization mode '{raw}'. Expected Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall."
        )
    return canonical


def main() -> int:
    args = parse_args(sys.argv[1:])

    raw_optimize = args.optimize or os.environ.get("ZIG_OS_OPTIMIZE") or os.environ.get("OPTIMIZE") or "ReleaseSafe"
    try:
        optimize = normalize_optimize(raw_optimize)
    except ValueError as exc:
        print(f"[TEST ERROR] {exc}", file=sys.stderr)
        return 1

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    test_script = os.path.join(repo_root, "scripts", "test-boot.sh")

    if not os.path.isfile(test_script):
        print(f"[TEST ERROR] Canonical smoke-test script missing: {test_script}", file=sys.stderr)
        return 1

    try:
        res = subprocess.run(
            ["bash", test_script, "--optimize", optimize],
            cwd=repo_root,
        )
        return res.returncode
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        print(f"[TEST ERROR] Failed to execute canonical smoke-test script: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
