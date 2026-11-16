#!/usr/bin/env python3
"""Cross-target kernel ABI audit for include/os/<os>/<arch>/pal_target.inc.

tools/abi_verify.c only runs natively. This tool compiles the same table (tools/abi_entries.def)
with --target=<triple> against the target's Linux/glibc UAPI headers, reads the resulting absolute
symbols with nm (nothing is linked or executed) and compares them with the target's pal_target.inc.

usage: abi_cross.py <x86_64|aarch64|arm> [--inc PATH] [--sysroot DIR]
exit: 0 ok, 1 mismatch, 2 toolchain/headers unavailable (never silently "passes").
"""
import argparse, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "x86_64": ("x86_64-linux-gnu", None, []),
    "aarch64": ("aarch64-linux-gnu", "/usr/aarch64-linux-gnu", ["-mno-outline-atomics"]),
    "arm": ("armv7a-linux-gnueabi", "/usr/arm-linux-gnueabi", ["-mfloat-abi=soft"]),
}


def pal_equs(path: Path) -> dict[str, int]:
    out = {}
    for line in path.read_text().splitlines():
        m = re.match(r"\s*\.equ\s+(\w+)\s*,\s*([-+]?(?:0x[0-9a-fA-F]+|\d+))", line)
        if m:
            txt = m.group(2)
            neg = txt.startswith("-")
            digits = txt.lstrip("+-")
            if len(digits) > 1 and digits[0] == "0" and digits[1] not in "xX":
                val = int(digits, 8)           # GAS: leading 0 = octal
            else:
                val = int(digits, 0)
            out[m.group(1)] = -val if neg else val
    return out


def kernel_facts(arch: str, sysroot: str | None) -> dict[str, int]:
    triple, default_root, extra = TARGETS[arch]
    root = sysroot or default_root
    cmd = ["clang", f"--target={triple}", "-O1", "-c", str(ROOT / "tools/abi_verify.c"),
           "-DABI_EMIT", "-D_GNU_SOURCE", *extra, "-Wno-unused-command-line-argument"]
    if root:
        if not Path(root, "include").is_dir():
            raise FileNotFoundError(f"target headers missing: {root}/include")
        cmd += ["--sysroot", root, "-isystem", f"{root}/include"]
    with tempfile.TemporaryDirectory() as tmp:
        obj = Path(tmp) / "abi.o"
        subprocess.run(cmd + ["-o", str(obj)], check=True, capture_output=True, text=True)
        nm = subprocess.run(["llvm-nm", str(obj)] if Path("/usr/bin/llvm-nm").exists() else ["nm", str(obj)],
                            check=True, capture_output=True, text=True).stdout
    facts = {}
    for line in nm.splitlines():
        m = re.match(r"([0-9a-fA-F]+)\s+[Aa]\s+abi__(\w+)", line)
        if m:
            v = int(m.group(1), 16)
            facts[m.group(2)] = v - (1 << 64) if v >= 1 << 63 else v
    return facts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("arch", choices=TARGETS)
    ap.add_argument("--inc")
    ap.add_argument("--sysroot")
    a = ap.parse_args()
    inc = Path(a.inc) if a.inc else ROOT / f"include/os/linux/{a.arch}/pal_target.inc"
    try:
        facts = kernel_facts(a.arch, a.sysroot)
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        sys.stderr.write(f"ABI-CROSS UNAVAILABLE ({a.arch}): {getattr(e, 'stderr', e)}\n")
        return 2
    pal = pal_equs(inc)
    bad = 0
    for name, want in facts.items():
        if name not in pal:
            sys.stderr.write(f"ABI MISSING: {name} not in {inc}\n"); bad += 1
        elif pal[name] != want:
            sys.stderr.write(f"ABI MISMATCH [{a.arch}]: {name}: pal_target.inc={pal[name]} (0x{pal[name] & (2**64-1):x}) vs kernel={want} (0x{want & (2**64-1):x})\n"); bad += 1
    if bad:
        return 1
    print(f"ABI CROSS AUDIT PASSED [{a.arch}] ({len(facts)} constants verified against target headers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
