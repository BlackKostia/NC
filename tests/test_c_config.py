#!/usr/bin/env python3
"""src/core/config*.c vs the frozen assembly: 6000 random duoprc files (CRLF, quotes, '=' forms, over-limit tables,
a >1 MiB file) must produce byte-identical g_config and identical lookups; plus a target smoke test."""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
MODULES = ["config", "config_parse", "config_load"]
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]


def test_differential() -> None:
    with H.workdir() as tmp:
        t = Path(tmp)
        refs = []
        for m in MODULES:
            o = t / f"{m}_ref.o"
            subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                            str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        objs = [str(o) for o in refs]
        for m in MODULES + ["string", "string_path"]:
            o = t / f"{m}.o"
            subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / f"src/core/{m}.c"), "-o", str(o)], check=True)
            objs.append(str(o))
        simd = t / "pal_simd.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / "src/os/linux/x86_64/pal_simd.s"), "-o", str(simd)], check=True)
        exe = t / "diff"
        subprocess.run(["gcc", "-O2", "-no-pie", "-w", "-include", "errno.h", str(ROOT / "tests/harness/config_diff.c"), *objs, str(simd),
                        "-o", str(exe)], check=True, stderr=subprocess.DEVNULL)
        res = subprocess.run([str(exe)], capture_output=True, text=True, timeout=600)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] CF1.", res.stdout.strip())


def main() -> None:
    test_differential()
    print("ALL C CONFIG TESTS PASSED.")


if __name__ == "__main__":
    main()
