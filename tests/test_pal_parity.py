#!/usr/bin/env python3
"""PAL ABI parity: every global os_*/pf_* symbol of the x86_64 PAL must exist on aarch64 (Етап 1b)."""

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAL_FILES = ["pal_os", "pal_file", "pal_fault", "pal_simd", "pal_uring", "pal_pty", "pal_thread", "pal_du", "pal_time",
             "pal_sys_fd", "pal_sys_path", "pal_sys_proc", "pal_sys_mem"]


def globals_of(arch: str, as_bin: str, nm_bin: str) -> set[str]:
    out: set[str] = set()
    with tempfile.TemporaryDirectory() as tmp:
        for f in PAL_FILES:
            obj = Path(tmp) / f"{f}.o"
            subprocess.run([as_bin, "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                            "-I", str(ROOT / "build"), str(ROOT / f"src/os/linux/{arch}/{f}.s"), "-o", str(obj)],
                           check=True, capture_output=True)
            for line in subprocess.run([nm_bin, "-g", "--defined-only", str(obj)], capture_output=True, text=True,
                                       check=True).stdout.splitlines():
                parts = line.split()
                if len(parts) == 3:
                    out.add(parts[2])
    return out


def main() -> None:
    a64 = shutil.which("aarch64-linux-gnu-as")
    if not a64:
        print("[SKIP] aarch64-linux-gnu-as not installed")
        return
    x86 = globals_of("x86_64", "as", "nm")
    arm = globals_of("aarch64", a64, "aarch64-linux-gnu-nm")
    missing = sorted(x86 - arm)
    assert not missing, f"aarch64 PAL lacks symbols present on x86_64: {missing}"
    print(f"[PASS] PAL parity: {len(x86)} x86_64 globals all present on aarch64")


if __name__ == "__main__":
    main()
