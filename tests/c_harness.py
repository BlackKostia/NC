"""Build and run freestanding C test programs (pal_start + PAL syscalls + src/ modules) on x86_64 and aarch64.

A harness is a C file defining duop_main(); modules under test are compiled from src/ with the same ABI flags as the
product (Makefile CFLAGS). aarch64 binaries run under qemu-user. Nothing here links libc.
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMON = ["-std=gnu2x", "-Os", "-ffreestanding", "-fno-pic", "-fno-pie", "-fcf-protection=none", "-fno-stack-protector",
          "-fno-asynchronous-unwind-tables", "-fno-unwind-tables", "-fno-ident", "-funsigned-char", "-fno-strict-aliasing",
          "-fno-common", "-ffunction-sections", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include")]
PAL_FILES = ["pal_start", "pal_sys_fd", "pal_sys_path", "pal_sys_proc", "pal_sys_mem", "pal_simd", "pal_os", "pal_file",
             "pal_fault", "pal_time"]
ARCHS = {
    "x86_64": dict(cc=["gcc"], extra=["-fno-stack-clash-protection"], as_=["as"], ld=["ld"], run=[]),
    "aarch64": dict(cc=["clang", "--target=aarch64-linux-gnu", "-mno-outline-atomics"], extra=[],
                    as_=["aarch64-linux-gnu-as"], ld=["aarch64-linux-gnu-ld"], run=["qemu-aarch64"]),
}


def available(arch: str) -> bool:
    t = ARCHS[arch]
    return all(shutil.which(x[0]) for x in (t["cc"], t["as_"], t["ld"])) and (not t["run"] or shutil.which(t["run"][0]))


def build(arch: str, work: Path, c_files: list[str]) -> Path:
    """c_files: repo-relative or absolute .c paths (harness + modules under test)."""
    t = ARCHS[arch]
    objs: list[str] = []
    pal = ROOT / f"src/os/linux/{arch}"
    for name in PAL_FILES:
        o = work / f"{name}.o"
        subprocess.run([*t["as_"], "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                        str(pal / f"{name}.s"), "-o", str(o)], check=True, capture_output=True)
        objs.append(str(o))
    for i, c in enumerate(c_files):
        src = Path(c) if Path(c).is_absolute() else ROOT / c
        o = work / f"c{i}_{src.stem}.o"
        subprocess.run([*t["cc"], *COMMON, *t["extra"], "-c", str(src), "-o", str(o)], check=True, capture_output=True)
        objs.append(str(o))
    exe = work / "prog"
    # pal_fault/pal_file reference mem_copy and try_rt helpers in some builds; --unresolved-symbols keeps unused paths gc'd
    subprocess.run([*t["ld"], "-z", "noexecstack", "--gc-sections", *objs, "-o", str(exe)], check=True, capture_output=True)
    return exe


def run(arch: str, exe: Path, args: list[str] | None = None, stdin: bytes = b"", timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run([*ARCHS[arch]["run"], str(exe), *(args or [])], input=stdin, capture_output=True, timeout=timeout)


def workdir() -> tempfile.TemporaryDirectory:
    return tempfile.TemporaryDirectory(prefix="duop_c_")
