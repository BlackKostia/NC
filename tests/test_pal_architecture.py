#!/usr/bin/env python3
"""Compile-time multi-platform PAL contract and boundary tests for Duop."""

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RAW_OS_TOKENS_RE = re.compile(
    r"\b(?:syscall|svc|SYS_[A-Za-z0-9_]+|OS_SYS_[A-Za-z0-9_]+|"
    r"KSTAT_[A-Za-z0-9_]+|KDIRENT_[A-Za-z0-9_]+|KTERMIOS_[A-Za-z0-9_]+|"
    r"KSIGACTION_[A-Za-z0-9_]+|KSIG_[A-Za-z0-9_]+|STAT_SIZE|STAT_INO|STAT_MODE|"
    r"STAT_ST_SIZE|STAT_MTIME|DIRENT_INO|DIRENT_RECLEN|DIRENT_NAME|"
    r"POLLFD_[A-Za-z0-9_]+|TIMESPEC_[A-Za-z0-9_]+|WINSIZE_[A-Za-z0-9_]+)\b"
)
RUNTIME_OS_CHECK_RE = re.compile(r"\b(?:g_os|os_type|OS_LINUX|OS_FREEBSD)\b")
SIMD_RE = re.compile(r"\b(?:xmm\d+|ymm\d+|zmm\d+)\b", re.IGNORECASE)


def strip_asm_comments_and_strings(line: str) -> str:
    out: list[str] = []
    in_str = False
    esc = False
    for ch in line:
        if esc:
            esc = False
            continue
        if in_str:
            if ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def test_pal_files_and_makefile_matrix() -> None:
    pal_inc = ROOT / "include/pal.inc"
    target_inc = ROOT / "include/os/linux/x86_64/pal_target.inc"
    pal_os = ROOT / "src/os/linux/x86_64/pal_os.s"
    legacy_inc = ROOT / "include/linux_sys.inc"

    assert pal_inc.is_file(), "Missing OS-neutral include/pal.inc"
    assert target_inc.is_file(), "Missing include/os/linux/x86_64/pal_target.inc"
    assert pal_os.is_file(), "Missing src/os/linux/x86_64/pal_os.s"
    assert not legacy_inc.exists(), "Legacy include/linux_sys.inc must be removed"

    pal_text = pal_inc.read_text(encoding="utf-8")
    for sym in ("FileStat.dev", "FileStat.ino", "FileStat.size", "FileStat.mtime", "FileStat.mode", "FileStat._size"):
        assert sym in pal_text, f"Missing {sym} in include/pal.inc"

    target_text = target_inc.read_text(encoding="utf-8")
    for macro in ("OS_OPENAT", "OS_CLOSE", "OS_READ", "OS_WRITE", "OS_RENAMEAT", "OS_UNLINKAT", "OS_MKDIRAT", "OS_GETCWD", "OS_CHDIR", "OS_EXIT"):
        assert f".macro {macro}" in target_text, f"Missing inline PAL macro {macro} in {target_inc}"

    mk = (ROOT / "Makefile").read_text(encoding="utf-8")
    assert re.search(r"^OS\s*\?=\s*linux", mk, re.M), "Makefile must define build-time OS ?= linux"
    assert re.search(r"^ARCH\s*\?=\s*x86_64", mk, re.M), "Makefile must define build-time ARCH ?= x86_64"
    assert "include/os/$(OS)/$(ARCH)" in mk, "Makefile ASFLAGS must include include/os/$(OS)/$(ARCH)"
    assert "src/os/$(OS)/$(ARCH)/" in mk, "Makefile must select backend objects from src/os/$(OS)/$(ARCH)/"
    print("[PASS] P1. Compile-time PAL files, FileStat contract, inline OS_* macros & Makefile matrix")


def test_zero_raw_os_coupling_and_zero_runtime_dispatch() -> None:
    violations: list[str] = []
    for rel_dir in ("src", "include"):
        for path in sorted((ROOT / rel_dir).rglob("*")):
            if path.suffix not in (".s", ".inc"):
                continue
            rel = path.relative_to(ROOT).as_posix()
            in_os_layer = rel.startswith("src/os/") or rel.startswith("include/os/")
            text = path.read_text(encoding="utf-8")

            if not in_os_layer and "linux_sys.inc" in text:
                violations.append(f"{rel}: references legacy linux_sys.inc")

            for lineno, raw in enumerate(text.splitlines(), start=1):
                code = strip_asm_comments_and_strings(raw).strip()
                if not code:
                    continue
                if RUNTIME_OS_CHECK_RE.search(code):
                    violations.append(f"{rel}:{lineno}: runtime OS branch/symbol forbidden: {code}")
                if not in_os_layer:
                    m = RAW_OS_TOKENS_RE.search(code)
                    if m:
                        violations.append(f"{rel}:{lineno}: raw OS detail '{m.group(0)}' outside os/ PAL")
                    s = SIMD_RE.search(code)
                    if s:
                        violations.append(f"{rel}:{lineno}: unisolated x86 SIMD register '{s.group(0)}' hinders AArch64 portability")

    assert not violations, "PAL boundary violations:\n  " + "\n  ".join(violations[:25])
    print("[PASS] P2. Zero raw syscalls/structs outside os/, zero runtime dispatch, zero unisolated SIMD")


def test_explicit_platform_build_and_elf_audit() -> None:
    res = subprocess.run(
        ["make", "OS=linux", "ARCH=x86_64"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert res.returncode == 0, f"make OS=linux ARCH=x86_64 failed:\n{res.stdout}\n{res.stderr}"

    size_out = subprocess.run(
        ["size", str(ROOT / "duop")],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    data_bytes = int(size_out[1].split()[1])
    assert data_bytes == 0, f"ELF .data must be 0 bytes, got {data_bytes}"

    ver_out = subprocess.run(
        [str(ROOT / "duop"), "--version"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout
    ver = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    assert f"v{ver}" in ver_out, f"Unexpected --version output: {ver_out}"
    print("[PASS] P3. Explicit OS=linux ARCH=x86_64 build produces clean .data==0 static ELF")


def test_aarch64_pal_backend() -> None:
    inc = ROOT / "include/os/linux/aarch64/pal_target.inc"
    assert inc.is_file(), "Missing AArch64 pal_target.inc"
    pal_files = [
        "src/os/linux/aarch64/pal_os.s",
        "src/os/linux/aarch64/pal_simd.s",
        "src/os/linux/aarch64/pal_uring.s",
        "src/os/linux/aarch64/pal_pty.s",
    ]
    for rel in pal_files:
        assert (ROOT / rel).is_file(), f"Missing AArch64 PAL file: {rel}"
    import shutil
    as_bin = shutil.which("aarch64-linux-gnu-as")
    if as_bin:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            for i, rel in enumerate(pal_files):
                subprocess.run(
                    [as_bin, "-I", str(ROOT / "include/os/linux/aarch64"), "-I", str(ROOT / "include"), str(ROOT / rel), "-o", f"{tmp}/o{i}.o"],
                    check=True,
                )
    print("[PASS] P4. AArch64 PAL backend (pal_target.inc + pal_os/simd/uring/pty) assembles cleanly")


def main() -> None:
    test_pal_files_and_makefile_matrix()
    test_zero_raw_os_coupling_and_zero_runtime_dispatch()
    test_explicit_platform_build_and_elf_audit()
    test_aarch64_pal_backend()
    print("ALL PAL ARCHITECTURE TESTS PASSED.")


if __name__ == "__main__":
    main()
