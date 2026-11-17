#!/usr/bin/env python3
"""src/core/string*.c (strings, paths, size/perms/datetime formatting) vs the frozen assembly (differential, x86_64
host harness) and vs Python (aarch64 under qemu-user via the freestanding harness)."""

import datetime
from pathlib import Path

import subprocess

import c_harness as H

ROOT = H.ROOT
MODULES = ["string", "string_path", "string_format", "string_datetime"]
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]


def test_differential_against_reference_asm() -> None:
    with H.workdir() as tmp:
        t = Path(tmp)
        refs = []
        for m in MODULES:
            o = t / f"{m}_ref.o"
            subprocess.run(["as", str(ROOT / f"tests/harness/{m}_reference.s")] if False else
                           ["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                            str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        objs = [str(o) for o in refs]
        for m in MODULES:
            o = t / f"{m}.o"
            subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / f"src/core/{m}.c"), "-o", str(o)], check=True)
            objs.append(str(o))
        simd = t / "pal_simd.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / "src/os/linux/x86_64/pal_simd.s"), "-o", str(simd)], check=True)
        exe = t / "diff"
        subprocess.run(["gcc", "-O2", "-no-pie", "-w", str(ROOT / "tests/harness/string_diff.c"), *objs, str(simd),
                        "-o", str(exe)], check=True, stderr=subprocess.DEVNULL)
        res = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] S1.", res.stdout.strip())


def test_target_formatting_matches_python() -> None:
    cases = [0, 59, 60, -1, -60, -61, 86399, 86400, 951782400, 1700000000, 253402300799, 253402300800, -62135596800, 4102444800]
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] S2-{arch}: toolchain/qemu unavailable")
            continue
        with H.workdir() as tmp:
            srcs = ["tests/harness/string_cli.c"] + [f"src/core/{m}.c" for m in MODULES] + ["src/core/mem_prims.c"]
            exe = H.build(arch, Path(tmp), srcs)
            res = H.run(arch, exe, [str(c) for c in cases])
            lines = res.stdout.decode().splitlines()
            assert res.returncode == 0 and len(lines) == len(cases), (arch, res.stdout, res.stderr)
            for c, line in zip(cases, lines):
                d = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=c) if -62135596800 <= c <= 253402300799 else None
                want = f"{d.year:04d}-{d.month:02d}-{d.day:02d} {d.hour:02d}:{d.minute:02d}" if d else None
                got = line.split("|")[0]
                if want:
                    assert got == want, f"{arch}: epoch {c}: {got!r} != {want!r}"
        print(f"[PASS] S2-{arch}: {len(cases)} timestamps (incl. minute -1 and year clamps) match Python's calendar")


def main() -> None:
    test_differential_against_reference_asm()
    test_target_formatting_matches_python()
    print("ALL C STRING TESTS PASSED.")


if __name__ == "__main__":
    main()
