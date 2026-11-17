#!/usr/bin/env python3
"""PAL walking skeleton: freestanding C self-test (tools/pal_selftest) runs on every available target."""

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def binary(arch: str) -> str:
    return f"build_selftest/{arch}/selftest"


def build_and_run(arch: str, runner: list[str]) -> str:
    build = ["make", "-s", f"ARCH={arch}", binary(arch)]
    res = subprocess.run(build, cwd=ROOT, capture_output=True, text=True)
    assert res.returncode == 0, f"{arch} selftest build failed:\n{res.stdout}{res.stderr}"
    exe = ROOT / binary(arch)
    out = subprocess.run(runner + [str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=60)
    assert out.returncode == 0 and "PAL SELFTEST PASSED" in out.stdout, f"{arch}: rc={out.returncode}\n{out.stdout}{out.stderr}"
    return out.stdout.strip()


def check_static_elf(arch: str, klass: str, machine: str) -> None:
    exe = ROOT / binary(arch)
    hdr = subprocess.run(["readelf", "-h", str(exe)], capture_output=True, text=True).stdout
    assert klass in hdr and machine in hdr, hdr
    segs = subprocess.run(["readelf", "-lW", str(exe)], capture_output=True, text=True).stdout
    assert "INTERP" not in segs and "DYNAMIC" not in segs, f"{arch}: selftest must be a static, libc-free ELF"
    assert "NEEDED" not in subprocess.run(["readelf", "-d", str(exe)], capture_output=True, text=True).stdout, \
        f"{arch}: selftest must not depend on shared libraries"   # initialised .data is allowed


def main() -> None:
    print("[PASS] K1. x86_64:", build_and_run("x86_64", []))
    check_static_elf("x86_64", "ELF64", "X86-64")
    if shutil.which("qemu-aarch64") and shutil.which("aarch64-linux-gnu-ld") and shutil.which("clang"):
        print("[PASS] K2. aarch64 (qemu-user):", build_and_run("aarch64", ["qemu-aarch64"]))
        check_static_elf("aarch64", "ELF64", "AArch64")
    else:
        print("[SKIP] K2. aarch64 toolchain/qemu-aarch64 unavailable")
    print("ALL PAL SELFTEST TESTS PASSED.")


if __name__ == "__main__":
    main()
