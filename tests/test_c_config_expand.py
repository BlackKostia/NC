#!/usr/bin/env python3
"""src/core/config_expand.c vs the frozen assembly (1.5M random templates/values/caps; full output buffers compared)
and semantic spot checks on x86_64 and aarch64 (qemu-user)."""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]


def test_differential() -> None:
    with H.workdir() as tmp:
        t = Path(tmp)
        ref = t / "ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / "tests/harness/config_expand_reference.s"), "-o", str(ref)], check=True)
        H.rename_defined_globals([ref], "ref_")
        c = t / "c.o"
        subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / "src/core/config_expand.c"), "-o", str(c)], check=True)
        exe = t / "diff"
        subprocess.run(["gcc", "-O2", "-no-pie", "-w", str(ROOT / "tests/harness/config_expand_diff.c"), str(ref), str(c),
                        "-o", str(exe)], check=True, stderr=subprocess.DEVNULL)
        res = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] CE1.", res.stdout.strip())


def test_targets() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] CE2-{arch}: toolchain/qemu unavailable")
            continue
        with H.workdir() as tmp:
            exe = H.build(arch, Path(tmp), ["tests/harness/config_expand_cli.c", "src/core/config_expand.c", "src/core/string.c", "src/core/mem_prims.c"])
            lines = H.run(arch, exe).stdout.decode().splitlines()
            assert lines == ["0|echo 'a'\\''b' \"x\\\"y\" 100%", "-36|", "0|ls 'p q' 'r'", "0|sh -c 'echo q'"], lines
        print(f"[PASS] CE2-{arch}: quoting contexts, %% and all-or-nothing overflow")


def main() -> None:
    test_differential()
    test_targets()
    print("ALL C CONFIG EXPAND TESTS PASSED.")


if __name__ == "__main__":
    main()
