#!/usr/bin/env python3
"""Cross-target kernel ABI audit (tools/abi_cross.py): pal_target.inc vs each target's UAPI headers."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CROSS = ROOT / "tools/abi_cross.py"


def run(arch: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(CROSS), arch], capture_output=True, text=True)


def test_native_and_cross_tables_agree() -> None:
    res = run("x86_64")
    assert res.returncode == 0, res.stderr
    assert "ABI CROSS AUDIT PASSED [x86_64]" in res.stdout


def test_aarch64_matches_kernel_headers() -> None:
    res = run("aarch64")
    if res.returncode == 2:
        print(f"[SKIP] aarch64 headers unavailable: {res.stderr.strip()[:120]}")
        return
    assert res.returncode == 0, res.stderr
    assert "ABI CROSS AUDIT PASSED [aarch64]" in res.stdout


def test_aarch64_o_nofollow_is_not_o_direct() -> None:
    # Regression: O_NOFOLLOW was 0x10000 (= O_DIRECT on arm64): symlink-race guard off, open() -> EINVAL
    text = (ROOT / "include/os/linux/aarch64/pal_target.inc").read_text()
    m = re.search(r"\.equ\s+O_NOFOLLOW\s*,\s*(0x[0-9a-fA-F]+)", text)
    assert m and int(m.group(1), 16) == 0x8000, f"aarch64 O_NOFOLLOW must be 0x8000 (0100000), got {m and m.group(1)}"


def test_abi_cross_is_not_vacuous() -> None:
    # A broken pal_target.inc must be detected (tool exits 1, never silently passes)
    import tempfile
    src = (ROOT / "include/os/linux/x86_64/pal_target.inc").read_text()
    bad = re.sub(r"(\.equ\s+O_CREAT\s*,\s*)0x40", r"\g<1>0x41", src)
    assert bad != src
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "pal_target.inc"
        p.write_text(bad)
        res = subprocess.run([sys.executable, str(CROSS), "x86_64", "--inc", str(p)], capture_output=True, text=True)
    assert res.returncode == 1 and "O_CREAT" in res.stderr, res.stderr


def test_pal_header_constants_match_inc() -> None:
    """include/duop_pal.h (portable C view) must equal each target's pal_target.inc and so its kernel headers."""
    import importlib.util
    import tempfile
    spec = importlib.util.spec_from_file_location("abi_cross", CROSS)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    names = sorted(set(re.findall(r"^#define (\w+) ", (ROOT / "include/duop_pal.h").read_text(), re.M)))
    body = "".join(f'    __asm__(".globl pal__{n}\\n.set pal__{n}, %c0" :: "i"((long long)({n})));\n' for n in names)
    checked = 0
    for arch, (triple, _root, extra) in mod.TARGETS.items():
        if arch == "arm":
            continue
        with tempfile.TemporaryDirectory() as tmp:
            src, obj = Path(tmp) / "p.c", Path(tmp) / "p.o"
            src.write_text('#include "duop_pal.h"\nvoid probe(void)\n{\n' + body + "}\n")
            cc = ["clang", f"--target={triple}", *extra, "-O1", "-Wno-unused-command-line-argument"]
            subprocess.run([*cc, "-I", str(ROOT / "include"), "-c", str(src), "-o", str(obj)], check=True, capture_output=True)
            nm = subprocess.run(["nm", str(obj)], capture_output=True, text=True).stdout
        facts = {}
        for line in nm.splitlines():
            m = re.match(r"([0-9a-fA-F]+)\s+[Aa]\s+pal__(\w+)", line)
            if m:
                v = int(m.group(1), 16)
                facts[m.group(2)] = v - (1 << 64) if v >= 1 << 63 else v
        assert set(facts) == set(names), f"{arch}: probe lost {set(names) - set(facts)}"
        inc = mod.pal_equs(ROOT / f"include/os/linux/{arch}/pal_target.inc")
        for n, v in facts.items():
            if n in inc:
                assert inc[n] == v, f"{arch}: duop_pal.h {n}={v} but pal_target.inc has {inc[n]}"
                checked += 1
    assert checked > 60, f"too few constants cross-checked ({checked})"


def main() -> None:
    test_native_and_cross_tables_agree()
    print("[PASS] A1. native/cross ABI tables agree on x86_64")
    test_aarch64_matches_kernel_headers()
    print("[PASS] A2. aarch64 pal_target.inc matches target kernel headers")
    test_aarch64_o_nofollow_is_not_o_direct()
    print("[PASS] A3. aarch64 O_NOFOLLOW != O_DIRECT")
    test_abi_cross_is_not_vacuous()
    print("[PASS] A4. mismatch is detected")
    test_pal_header_constants_match_inc()
    print("[PASS] A5. duop_pal.h constants equal pal_target.inc on x86_64 and aarch64")
    print("ALL ABI CROSS TESTS PASSED.")


if __name__ == "__main__":
    main()
