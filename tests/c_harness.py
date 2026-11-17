"""Build and run freestanding C test programs (pal_start + PAL syscalls + src/ modules) on x86_64 and aarch64.

A harness is a C file defining duop_main(); modules under test are compiled from src/ with the same ABI flags as the
product (Makefile CFLAGS). aarch64 binaries run under qemu-user. Nothing here links libc.
"""

import os
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMON = ["-std=gnu2x", "-Os", "-ffreestanding", "-fno-pic", "-fno-pie", "-fcf-protection=none", "-fno-stack-protector",
          "-fno-asynchronous-unwind-tables", "-fno-unwind-tables", "-fno-ident", "-funsigned-char", "-fno-strict-aliasing",
          "-fno-common", "-ffunction-sections", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include")]
PAL_FILES = ["pal_start", "pal_sys_fd", "pal_sys_path", "pal_sys_proc", "pal_sys_mem", "pal_simd", "pal_os", "pal_file",
             "pal_fault", "pal_time", "pal_pty"]
SHIMS = "tests/harness/pal_shims.c"
ARCHS = {
    "x86_64": dict(cc=["gcc"], extra=["-fno-stack-clash-protection"], as_=["as"], ld=["ld"], run=[]),
    "aarch64": dict(cc=["clang", "--target=aarch64-linux-gnu", "-mno-outline-atomics"], extra=[],
                    as_=["aarch64-linux-gnu-as"], ld=["aarch64-linux-gnu-ld"], run=["qemu-aarch64"]),
}


def available(arch: str) -> bool:
    t = ARCHS[arch]
    return all(shutil.which(x[0]) for x in (t["cc"], t["as_"], t["ld"])) and (not t["run"] or shutil.which(t["run"][0]))


def build(arch: str, work: Path, c_files: list[str], extra_objs: list[Path] | None = None, cflags: list[str] | None = None,
          pal_override: dict[str, Path] | None = None) -> Path:
    """c_files: repo-relative or absolute .c paths (harness + modules under test); extra_objs: prebuilt objects to link too;
    pal_override: PAL file name -> replacement .s (mutation checks of the PAL itself)."""
    t = ARCHS[arch]
    objs: list[str] = []
    pal = ROOT / f"src/os/linux/{arch}"
    for name in PAL_FILES:
        o = work / f"{name}.o"
        subprocess.run([*t["as_"], "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                        str((pal_override or {}).get(name) or pal / f"{name}.s"), "-o", str(o)], check=True, capture_output=True)
        objs.append(str(o))
    for i, c in enumerate([*c_files, SHIMS]):
        src = Path(c) if Path(c).is_absolute() else ROOT / c
        o = work / f"c{i}_{src.stem}.o"
        subprocess.run([*t["cc"], *COMMON, *t["extra"], *(cflags or []), "-c", str(src), "-o", str(o)], check=True, capture_output=True)
        objs.append(str(o))
    objs.extend(str(o) for o in extra_objs or [])
    exe = work / "prog"
    # pal_fault/pal_file reference mem_copy and try_rt helpers in some builds; --unresolved-symbols keeps unused paths gc'd
    subprocess.run([*t["ld"], "-z", "noexecstack", "--gc-sections", *objs, "-o", str(exe)], check=True, capture_output=True)
    return exe


def run(arch: str, exe: Path, args: list[str] | None = None, stdin: bytes = b"", timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run([*ARCHS[arch]["run"], str(exe), *(args or [])], input=stdin, capture_output=True, timeout=timeout)


def workdir() -> tempfile.TemporaryDirectory:
    return tempfile.TemporaryDirectory(prefix="duop_c_")


def rename_defined_globals(objs: list[Path], prefix: str) -> None:
    """Prefix every global symbol *defined* in any of objs (and its references inside objs); externals such as PAL
    functions stay untouched. Used to link a frozen reference .s next to the C module that replaces it."""
    names: set[str] = set()
    for o in objs:
        out = subprocess.run(["nm", "-g", "--defined-only", str(o)], capture_output=True, text=True, check=True).stdout
        names.update(line.split()[-1] for line in out.splitlines() if line.strip())
    args = [a for n in sorted(names) for a in ("--redefine-sym", f"{n}={prefix}{n}")]
    for o in objs:
        subprocess.run(["objcopy", *args, str(o)], check=True)


# ---- shared utilities for differential tests (E8) -------------------------------------------------------------------------------
OPTIONAL_PAL = ("pal_thread", "pal_du")          # PAL files `build(pal_extra=...)` links on request (most harnesses do not need them)


def version_dir(work: Path) -> Path:
    """work/ver with version.inc (asm macros) and version.h (C macro) of the current VERSION: what the Makefile writes into build/."""
    version = (ROOT / "VERSION").read_text().strip()
    ver = work / "ver"
    ver.mkdir(exist_ok=True)
    (ver / "version.inc").write_text(f'.macro DUOP_VER_ASCII\n    .ascii "{version}"\n.endm\n.macro DUOP_VER_ASCIZ\n    .asciz "{version}"\n.endm\n')
    (ver / "version.h").write_text(f'#pragma once\n#define DUOP_VERSION "{version}"\n')
    return ver


def build_with_refs(arch: str, work: Path, c_files: list[str], refs: list[str], cflags: list[str] | None = None,
                    asflags: list[str] | None = None, prefix: str = "ref_", pal_extra: tuple[str, ...] = ()) -> Path:
    """Assemble every frozen reference .s of `refs` (repo-relative) with the product include paths and the real version.inc,
    prefix its defined globals with `prefix`, and link it next to `c_files` (the C replacement keeps the original names)."""
    t = ARCHS[arch]
    ver = version_dir(work)
    objs: list[Path] = []
    for i, ref in enumerate(refs):
        o = work / f"ref{i}_{Path(ref).stem}.o"
        subprocess.run([*t["as_"], *(asflags or []), "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"), "-I", str(ver),
                        str(ROOT / ref), "-o", str(o)], check=True, capture_output=True)
        objs.append(o)
    if objs:
        rename_defined_globals(objs, prefix)
    for name in pal_extra:
        assert name in OPTIONAL_PAL, name
        o = work / f"{name}.o"
        subprocess.run([*t["as_"], "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                        str(ROOT / f"src/os/linux/{arch}/{name}.s"), "-o", str(o)], check=True, capture_output=True)
        objs.append(o)
    return build(arch, work, c_files, objs, cflags=["-I", str(ver), *(cflags or [])])


def snapshot(root: Path, scrub: Callable[[bytes], bytes] | None = None) -> list[tuple]:
    """Deterministic picture of a tree for comparing what two implementations did to identical copies: (relative path, kind,
    mode, content / link target). A FIFO, socket or device is recorded by mode only - opening a FIFO would block forever."""
    snap: list[tuple] = []
    for p in sorted(root.rglob("*")):
        rel, st = str(p.relative_to(root)), p.lstat()
        if p.is_symlink():
            snap.append((rel, "l", os.readlink(p)))
        elif p.is_dir():
            snap.append((rel, "d", oct(st.st_mode & 0o7777)))
        elif not stat.S_ISREG(st.st_mode):
            snap.append((rel, "s", oct(st.st_mode)))
        else:
            data = p.read_bytes()
            snap.append((rel, "f", oct(st.st_mode & 0o7777), scrub(data) if scrub else data))
    return snap


def mutcheck(source: Path, mutants: list[tuple[str, str, str]], detected: Callable[[Path, int], bool], work: Path) -> list[str]:
    """Mutation check: for each (name, old, new) write source with the first `old` replaced by `new` to work/mut<i><suffix> and ask
    `detected(path, i)` whether the test suite notices. Returns the names of surviving mutants (the caller asserts the list is empty,
    or documents each survivor as behaviourally equivalent). A vanished anchor or a mutant identical to the source fails loudly."""
    text = source.read_text()
    survivors: list[str] = []
    for i, (name, old, new) in enumerate(mutants):
        assert old in text, f"mutation anchor vanished: {name}"
        assert old != new, f"mutation '{name}' changes nothing"
        path = work / f"mut{i}{source.suffix}"
        path.write_text(text.replace(old, new, 1))
        if not detected(path, i):
            survivors.append(name)
    return survivors


def run_impl(arch: str, exe: Path, impl: str, *args: str, stdin: bytes = b"", env: dict[str, str] | None = None,
             timeout: int = 120) -> subprocess.CompletedProcess:
    """One run of a script_cli-style harness: argv = [impl, *args], script on stdin, a clean environment plus `env`."""
    e = {"PATH": "/usr/bin:/bin", **(env or {})}
    return subprocess.run([*ARCHS[arch]["run"], str(exe), impl, *args], input=stdin, capture_output=True, env=e, timeout=timeout)


def diff_impls(exe: Path, *args: str, stdin: bytes = b"", env: dict[str, str] | None = None, arch: str = "x86_64",
               impls: tuple[str, str] = ("ref", "c")) -> bytes:
    """Run the oracle and the C implementation (one per process) on the same script and require identical exit status, stdout and
    stderr; the failure message shows the first differing lines. Returns the C implementation's stdout."""
    a = run_impl(arch, exe, impls[0], *args, stdin=stdin, env=env)
    b = run_impl(arch, exe, impls[1], *args, stdin=stdin, env=env)
    assert a.returncode == 0 and b.returncode == 0, (args, a.returncode, a.stderr[-200:], b.returncode, b.stderr[-200:])
    if (a.stdout, a.stderr) != (b.stdout, b.stderr):
        pairs = [(x, y) for x, y in zip(a.stdout.splitlines(), b.stdout.splitlines()) if x != y][:3]
        raise AssertionError(f"{impls[0]} and {impls[1]} differ for {args[:3]}: {pairs or (a.stderr[:200], b.stderr[:200])}")
    return b.stdout
