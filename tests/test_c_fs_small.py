#!/usr/bin/env python3
"""Small src/fs modules (dir_diff.c ...) versus their frozen assembly on random DirModels (host differential)."""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]
MODULES = ["dir_diff"]


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        refs = []
        for m in MODULES:
            o = t / f"{m}_ref.o"
            subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        objs = [str(o) for o in refs]
        for m in [*MODULES, "../core/string"]:
            o = t / (Path(m).name + ".o")
            subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / f"src/fs/{m}.c"), "-o", str(o)], check=True)
            objs.append(str(o))
        simd = t / "pal_simd.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "src/os/linux/x86_64/pal_simd.s"), "-o", str(simd)], check=True)
        exe = t / "smalldiff"
        link = subprocess.run(["gcc", "-O1", "-no-pie", "-w", "-I", str(ROOT / "include"), str(ROOT / "tests/harness/fs_small_diff.c"), *objs, str(simd), "-o", str(exe)],
                              capture_output=True, text=True)
        assert link.returncode == 0, link.stderr[-1500:]
        res = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
        assert res.returncode == 0, res.stdout + res.stderr
        for line in res.stdout.splitlines():
            print(f"[PASS] FS-SMALL. {line}")
    print("ALL C FS SMALL-MODULE TESTS PASSED.")


if __name__ == "__main__":
    main()
