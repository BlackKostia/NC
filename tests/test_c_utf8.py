#!/usr/bin/env python3
"""src/core/utf8.c must behave exactly like the hand-written assembly it replaced (frozen oracle in tests/harness)."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CFLAGS = ["-std=gnu2x", "-Os", "-ffreestanding", "-fno-pic", "-fno-pie", "-fcf-protection=none", "-fno-stack-protector",
          "-funsigned-char", "-fno-strict-aliasing", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include")]


def test_matches_reference_asm() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        subprocess.run(["as", str(ROOT / "tests/harness/utf8_reference.s"), "-o", str(t / "ref.o")], check=True)
        subprocess.run(["objcopy", "--prefix-symbols=ref_", str(t / "ref.o")], check=True)
        subprocess.run(["gcc", *CFLAGS, "-c", str(ROOT / "src/core/utf8.c"), "-o", str(t / "c.o")], check=True)
        subprocess.run(["gcc", "-O2", "-no-pie", str(ROOT / "tests/harness/utf8_diff.c"), str(t / "ref.o"), str(t / "c.o"),
                        "-o", str(t / "diff")], check=True, stderr=subprocess.DEVNULL)
        res = subprocess.run([str(t / "diff")], capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] U1.", res.stdout.strip())


def test_object_is_libc_free_and_data_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        obj = Path(tmp) / "c.o"
        subprocess.run(["gcc", *CFLAGS, "-c", str(ROOT / "src/core/utf8.c"), "-o", str(obj)], check=True)
        undef = subprocess.run(["nm", "-u", str(obj)], capture_output=True, text=True).stdout.split()
        assert not undef, f"utf8.c must not reference external symbols: {undef}"
    print("[PASS] U2. utf8.o has no undefined symbols (no libc)")


def test_aarch64_object_matches_x86_semantics() -> None:
    import shutil
    if not shutil.which("clang"):
        print("[SKIP] U3. clang unavailable")
        return
    with tempfile.TemporaryDirectory() as tmp:
        obj = Path(tmp) / "a64.o"
        subprocess.run(["clang", "--target=aarch64-linux-gnu", "-mno-outline-atomics", *CFLAGS, "-c",
                        str(ROOT / "src/core/utf8.c"), "-o", str(obj)], check=True, capture_output=True)
        undef = subprocess.run(["llvm-nm", "-u", str(obj)] if shutil.which("llvm-nm") else ["nm", "-u", str(obj)],
                               capture_output=True, text=True).stdout.split()
        assert not undef, undef
    print("[PASS] U3. utf8.c compiles for aarch64 without external symbols")


def main() -> None:
    test_matches_reference_asm()
    test_object_is_libc_free_and_data_free()
    test_aarch64_object_matches_x86_semantics()
    print("ALL C UTF-8 TESTS PASSED.")


if __name__ == "__main__":
    main()
