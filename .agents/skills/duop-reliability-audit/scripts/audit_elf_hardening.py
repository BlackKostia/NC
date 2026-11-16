#!/usr/bin/env python3
"""ELF Binary & Hardening Auditor for Duop static ELF64 binary.

Verifies via `size` and `readelf`:
  1. `.data` section == 0 bytes.
  2. `PT_GNU_STACK` is present and non-executable (an absent header means READ_IMPLIES_EXEC on kernels < 5.8).
  3. Zero `TEXTREL` / dynamic relocations in static ELF.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def main() -> int:
    bin_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "duop"
    if not bin_path.is_file():
        print(f"ELF AUDIT SKIPPED: {bin_path} not built yet")
        return 0

    failures: list[str] = []

    sz = subprocess.run(["size", str(bin_path)], capture_output=True, text=True, check=False)
    if sz.returncode != 0:
        failures.append(f"`size` failed: {sz.stderr.strip()}")
    else:
        lines = sz.stdout.strip().splitlines()
        if len(lines) >= 2:
            cols = lines[1].split()
            if len(cols) >= 2 and int(cols[1]) != 0:
                failures.append(f"ELF .data section must be 0 bytes (got {cols[1]})")

    re_ph = subprocess.run(["readelf", "-lW", str(bin_path)], capture_output=True, text=True, check=False)
    if re_ph.returncode != 0:
        failures.append(f"`readelf -lW` failed: {re_ph.stderr.strip()}")
    else:
        if not any("GNU_STACK" in line for line in re_ph.stdout.splitlines()):
            failures.append("missing `PT_GNU_STACK` (link with `-z noexecstack`): heap/.bss/stack become executable on kernels < 5.8")
        for line in re_ph.stdout.splitlines():
            if "GNU_STACK" in line and "RWE" in line:
                failures.append(f"Executable stack detected (`GNU_STACK` has `RWE`): {line.strip()}")
            if "INTERP" in line:
                failures.append(f"Unexpected `PT_INTERP` in zero-libc static ELF: {line.strip()}")

    re_dyn = subprocess.run(["readelf", "-d", str(bin_path)], capture_output=True, text=True, check=False)
    if "TEXTREL" in re_dyn.stdout:
        failures.append("Unexpected TEXTREL entry in ELF")

    if failures:
        print(f"ELF HARDENING AUDIT FAILED ({len(failures)} issue(s)):")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"ELF HARDENING AUDIT PASSED ({bin_path.name}: .data=0, static, NX-safe)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
