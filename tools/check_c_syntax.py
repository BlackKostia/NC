#!/usr/bin/env python3
"""Fast portability gate for freestanding C modules: syntax-check each given .c file with the project's real CFLAGS
(taken from `make -n`, so they can never drift from the Makefile) for x86_64 (gcc) and, when the cross toolchain is
installed, aarch64 (clang). Catches -Werror warnings, -Wframe-larger-than, missing prototypes and ABI-width mistakes in
about a second per file, long before the full build or the qemu run.

    check_c_syntax.py src/fs/foo.c [more.c ...]       exit 1 on the first failing file / arch
    check_c_syntax.py --arch x86_64 src/fs/foo.c      one architecture only
Used by .githooks/pre-commit, verify_build.sh and the agent lifecycle hook (after an Edit of a .c file)."""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARCHS = {"x86_64": ("build", "gcc", None), "aarch64": ("build_aarch64", "clang", "aarch64-linux-gnu-ld")}


def compile_command(rel: str, arch: str) -> list[str] | None:
    """The compiler command line `make` would run for src/<x>.c on `arch`, or None when make cannot tell."""
    build, _, _ = ARCHS[arch]
    obj = f"{build}/{rel[len('src/'):-2]}.o"
    res = subprocess.run(["make", "-n", "-B", f"ARCH={arch}", obj], cwd=ROOT, capture_output=True, text=True, check=False)
    for line in res.stdout.splitlines():
        if line.split(" ", 1)[0] in ("gcc", "clang") and " -c " in line:
            return shlex.split(line)
    return None


def to_syntax_only(cmd: list[str]) -> list[str]:
    out, skip = [], False
    for i, tok in enumerate(cmd):
        if skip:
            skip = False
        elif tok == "-o":
            skip = True
        elif tok in ("-c", "-MMD", "-MP", "-g"):
            continue
        else:
            out.append(tok)
    return out + ["-fsyntax-only"]


def check_one(rel: str, arch: str) -> int:
    """0 when src/<x>.c compiles warning-free for `arch` (or the toolchain is absent), else 1."""
    _, cc, ld = ARCHS[arch]
    if not shutil.which(cc) or (ld and not shutil.which(ld)):
        print(f"check_c_syntax: {arch} toolchain missing, skipped", file=sys.stderr)
        return 0
    cmd = compile_command(rel, arch)
    if cmd is None:
        print(f"check_c_syntax: no compile rule for {rel} [{arch}]", file=sys.stderr)
        return 1
    res = subprocess.run(to_syntax_only(cmd), cwd=ROOT, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        print(f"C-SYNTAX FAILED [{arch}] {rel}:\n{(res.stderr or res.stdout).strip()}", file=sys.stderr)
        return 1
    return 0


def check(files: list[str], archs: list[str]) -> int:
    for arch in archs:                                    # generated headers every module may include (version.h, i18n_slots.h)
        build = ARCHS[arch][0]
        subprocess.run(["make", "-s", f"ARCH={arch}", f"{build}/version.h", f"{build}/i18n_slots.h"], cwd=ROOT, check=False, capture_output=True)
    tasks = [(rel, arch) for rel in files if rel.startswith("src/") and rel.endswith(".c") and (ROOT / rel).is_file() for arch in archs]
    with ThreadPoolExecutor(max_workers=min(len(tasks), os.cpu_count() or 4) or 1) as pool:      # make -n + the compiler: independent processes
        failed = sum(pool.map(lambda t: check_one(*t), tasks))
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--arch", choices=sorted(ARCHS), action="append", help="architecture(s) to check (default: all installed)")
    a = ap.parse_args()
    rc = check(a.files, a.arch or list(ARCHS))
    if rc == 0:
        print(f"C syntax OK ({len([f for f in a.files if f.endswith('.c')])} file(s))")
    return rc


if __name__ == "__main__":
    sys.exit(main())
