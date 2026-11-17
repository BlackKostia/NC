#!/usr/bin/env python3
"""Static modularity, ABI-hygiene, i18n-parity (built-in English table + lang/*.lang packs), and version checker for Duop."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
LINE_LIMIT_WARN = 1800

UI_WIDGET_RE = re.compile(
    r"\b(?:HeaderBar|FunctionBar|StatusBar|FilePane|PreviewPane|"
    r"Dialog|ConfirmDialog|InputDialog|ViewerDialog|HelpDialog|App)_[A-Za-z0-9_]+"
)
TUI_RE = re.compile(r"\b(?:Screen|Input|theme)_[A-Za-z0-9_]+")
I18N_RE = re.compile(r"\bi18n_[A-Za-z0-9_]+")
FS_RE = re.compile(r"\b(?:DirModel|FileOps|file_ops)_[A-Za-z0-9_]+")
RAW_PAL_VIOLATION_RE = re.compile(
    r"\b(?:syscall|svc|SYS_[A-Za-z0-9_]+|OS_SYS_[A-Za-z0-9_]+|"
    r"KSTAT_[A-Za-z0-9_]+|KDIRENT_[A-Za-z0-9_]+|KTERMIOS_[A-Za-z0-9_]+|"
    r"KSIGACTION_[A-Za-z0-9_]+|KSIG_[A-Za-z0-9_]+|POLLFD_[A-Za-z0-9_]+|"
    r"TIMESPEC_[A-Za-z0-9_]+|WINSIZE_[A-Za-z0-9_]+)\b"
)


def strip_asm_comment_and_strings(line: str) -> str:
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


def parse_makefile_var(makefile_path: Path, var_name: str, suffix: str = ".s") -> list[str]:
    text = makefile_path.read_text(encoding="utf-8")
    m = re.search(rf"^{re.escape(var_name)}\s*:=\s*(.*?)(?:\n\n|\n[A-Z_]+\s*[:+]?=)", text, re.S | re.M)
    if not m:
        raise ValueError(f"Could not locate {var_name} := block in Makefile")
    block = m.group(1).replace("\\\n", " ")
    return [tok.strip() for tok in block.split() if tok.strip().endswith(suffix)]


def parse_makefile_srcs(makefile_path: Path) -> tuple[list[str], list[str]]:
    srcs = parse_makefile_var(makefile_path, "SRCS")
    pal_raw = parse_makefile_var(makefile_path, "PAL_SRCS")
    try:
        pal_raw += parse_makefile_var(makefile_path, "PAL_START_SRCS")  # C-main entry stubs (pal_start.s)
    except ValueError:
        pass
    pal_default = [p.replace("$(OS)", "linux").replace("$(ARCH)", "x86_64") for p in pal_raw]
    return srcs, pal_default


C_FORBIDDEN_INCLUDE_RE = re.compile(
    r"^\s*#\s*include\s*<(?:stdio|stdlib|string|strings|unistd|errno|math|fcntl|signal|time|pthread|"
    r"setjmp|locale|wchar|assert|ctype|dirent|poll|termios|dlfcn|sys/[a-z_]+|linux/[a-z_]+|asm/[a-z_]+)\.h>")
C_ASM_SYSCALL_RE = re.compile(r"\b(?:asm|__asm__)\b[^;]*\"\s*(?:syscall|svc|swi|int\s+\$?0x80)\b")
C_COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
C_STRING_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def strip_c(text: str) -> str:
    """Remove comments and string literals but keep line structure (for per-line rule matching)."""
    text = C_COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return C_STRING_RE.sub('""', text)


def check_c_sources(root: Path, errors: list[str]) -> int:
    """Rules for src/**/*.c (freestanding C23 layers): no libc headers, no inline syscalls outside src/os,
    same downward layering and PAL-boundary rules as the assembly modules."""
    c_files = sorted(p.relative_to(root).as_posix() for p in (root / "src").rglob("*.c"))
    for rel in c_files:
        raw_text = (root / rel).read_text(encoding="utf-8")
        raw_lines = raw_text.splitlines()
        lines = strip_c(raw_text).splitlines()
        in_os = rel.startswith("src/os/")
        for idx, (raw, code) in enumerate(zip(raw_lines, lines), start=1):
            if C_FORBIDDEN_INCLUDE_RE.match(raw):
                errors.append(f"{rel}:{idx}: libc/OS header is forbidden in freestanding C; use duop_abi.h")
            if not in_os and C_ASM_SYSCALL_RE.search(raw):
                errors.append(f"{rel}:{idx}: inline-asm syscall outside src/os/; call an os_* PAL function")
            if not in_os:
                pm = RAW_PAL_VIOLATION_RE.search(code)
                if pm:
                    errors.append(f"{rel}:{idx}: direct kernel/PAL symbol '{pm.group(0)}' outside src/os/")
            rules = {
                "src/core/": ((UI_WIDGET_RE, "UI/App symbol"), (TUI_RE, "TUI symbol"), (I18N_RE, "i18n symbol"), (FS_RE, "FS symbol")),
                "src/tui/": ((UI_WIDGET_RE, "UI/App symbol"), (FS_RE, "FS symbol")),
                "src/fs/": ((UI_WIDGET_RE, "UI/App symbol"), (TUI_RE, "TUI rendering/input symbol")),
            }
            for prefix, pats in rules.items():
                if rel.startswith(prefix):
                    for pat, label in pats:
                        m = pat.search(code)
                        if m:
                            errors.append(f"{rel}:{idx}: layer violation in {prefix.split('/')[1]} ({label}: {m.group(0)})")
    mk = root / "Makefile"
    try:
        mk_c = parse_makefile_var(mk, "C_SRCS", ".c")
    except ValueError:
        mk_c = []
    missing = sorted(set(c_files) - set(mk_c))
    ghosts = sorted(set(mk_c) - set(c_files))
    if missing:
        errors.append(f"C modules missing from Makefile C_SRCS: {', '.join(missing)}")
    if ghosts:
        errors.append(f"Makefile C_SRCS reference missing files: {', '.join(ghosts)}")
    return len(c_files)


def check_version_file(root: Path, errors: list[str]) -> str | None:
    ver_path = root / "VERSION"
    if not ver_path.is_file():
        errors.append("Missing VERSION file at repository root")
        return None
    ver = ver_path.read_text(encoding="utf-8").strip()
    if not SEMVER_RE.match(ver):
        errors.append(f"Invalid VERSION '{ver}': expected SemVer X.Y.Z")
        return None
    return ver


def check_i18n_symmetry(root: Path, errors: list[str]) -> None:
    """Every LangStrings slot (include/types.inc) has English text in src/tui/i18n_en.lang (compiled into build/i18n_en.c
    by tools/gen_i18n.py) and a Ukrainian translation in lang/uk.lang; the slot size is a whole number of pointers."""
    types_path = root / "include/types.inc"
    en_path = root / "src/tui/i18n_en.lang"
    if not types_path.is_file() or not en_path.is_file():
        errors.append("Missing include/types.inc or src/tui/i18n_en.lang for i18n check")
        return

    m = re.search(r"LangStrings\.code:.*?LangStrings\._size:", types_path.read_text(encoding="utf-8"), re.S)
    if not m:
        errors.append("Could not parse LangStrings struct in include/types.inc")
        return
    for line in m.group(0).splitlines():
        sm = re.search(r"\.space\s+(\d+)(?:\s*\*\s*(\d+))?", strip_asm_comment_and_strings(line))
        if sm and (int(sm.group(1)) * int(sm.group(2) or 1)) % 8:
            errors.append(f"LangStrings non-8-byte field size: {line.strip()}")
    keys = langstrings_keys(m.group(0))
    seen: list[str] = []
    for idx, raw in enumerate(en_path.read_text(encoding="utf-8").splitlines(), start=1):
        km = re.match(r"^\s*([A-Za-z0-9_.]+)\s*=", raw)
        if km:
            seen.append(km.group(1))
            if km.group(1) not in keys:
                errors.append(f"src/tui/i18n_en.lang:{idx}: unknown key '{km.group(1)}'")
    missing = [k for k in keys if k not in seen]
    if missing:
        errors.append(f"src/tui/i18n_en.lang misses English text for: {', '.join(missing)}")
    if len(seen) != len(set(seen)):
        errors.append("src/tui/i18n_en.lang defines a key twice")
    check_lang_packs(root, keys, errors)


def langstrings_keys(struct_text: str) -> list[str]:
    """Pack keys of every LangStrings slot: field name, or field.1..field.N for arrays."""
    keys: list[str] = []
    for line in struct_text.splitlines():
        fm = re.match(r"LangStrings\.(\w+):\s*\.space\s+(\d+)(?:\s*\*\s*(\d+))?", line)
        if not fm or fm.group(1) == "_size":
            continue
        n = (int(fm.group(2)) * int(fm.group(3)) if fm.group(3) else int(fm.group(2))) // 8
        keys += [fm.group(1)] if n == 1 else [f"{fm.group(1)}.{i + 1}" for i in range(n)]
    return keys


def check_lang_packs(root: Path, keys: list[str], errors: list[str]) -> None:
    """lang/uk.lang (Ukrainian) translates every key and no shipped pack uses an unknown key."""
    packs = sorted((root / "lang").glob("*.lang"))
    if not any(p.name == "uk.lang" for p in packs):
        errors.append("Missing lang/uk.lang (Ukrainian interface pack)")
    for pack in packs:
        seen = set()
        for idx, raw in enumerate(pack.read_text(encoding="utf-8").splitlines(), start=1):
            km = re.match(r"^\s*([A-Za-z0-9_.]+)\s*=", raw)
            if not km or raw.lstrip().startswith("#"):
                continue
            if km.group(1) not in keys:
                errors.append(f"{pack.relative_to(root)}:{idx}: unknown key '{km.group(1)}'")
            seen.add(km.group(1))
        if pack.name == "uk.lang":
            missing = [k for k in keys if k not in seen]
            if missing:
                errors.append(f"lang/uk.lang misses translations for: {', '.join(missing)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Duop modular rules")
    parser.add_argument("--root", default=".", help="Repository root path")
    parser.add_argument("--strict-size", action="store_true", help="Fail if any .s exceeds line limit")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    errors: list[str] = []
    warnings: list[str] = []

    ver = check_version_file(root, errors)

    all_disk_srcs = sorted(p.relative_to(root).as_posix() for p in (root / "src").rglob("*.s"))
    shared_disk_srcs = [p for p in all_disk_srcs if not p.startswith("src/os/")]
    default_pal_disk = [p for p in all_disk_srcs if p.startswith("src/os/linux/x86_64/")]
    try:
        mk_srcs, mk_pal_srcs = parse_makefile_srcs(root / "Makefile")
    except Exception as exc:
        errors.append(str(exc))
        mk_srcs, mk_pal_srcs = [], []

    if mk_srcs:
        missing_in_mk = sorted(set(shared_disk_srcs) - set(mk_srcs))
        missing_on_disk = sorted(set(mk_srcs) - set(shared_disk_srcs))
        if missing_in_mk:
            errors.append(f"Modules missing from Makefile SRCS: {', '.join(missing_in_mk)}")
        if missing_on_disk:
            errors.append(f"Makefile SRCS reference missing files: {', '.join(missing_on_disk)}")
    if mk_pal_srcs:
        missing_pal = sorted(set(default_pal_disk) - set(mk_pal_srcs))
        missing_pal_disk = sorted(set(mk_pal_srcs) - set(default_pal_disk))
        if missing_pal:
            errors.append(f"Default PAL modules missing from Makefile PAL_SRCS: {', '.join(missing_pal)}")
        if missing_pal_disk:
            errors.append(f"Makefile PAL_SRCS reference missing files: {', '.join(missing_pal_disk)}")

    for rel in all_disk_srcs:
        path = root / rel
        lines = path.read_text(encoding="utf-8").splitlines()
        if "/aarch64/" not in rel:
            if not any(strip_asm_comment_and_strings(l).strip() == ".intel_syntax noprefix" for l in lines[:25]):
                errors.append(f"{rel}: missing '.intel_syntax noprefix' in file header")

        in_os_pal = rel.startswith("src/os/")
        for idx, raw in enumerate(lines, start=1):
            code = strip_asm_comment_and_strings(raw).strip()
            if not code:
                continue
            if re.match(r"^(?:\.data\b|\.section\s+\.data\b)", code):
                errors.append(f"{rel}:{idx}: writable '.data' section is forbidden; use .rodata or .bss/mem_alloc")
            if not in_os_pal:
                pm = RAW_PAL_VIOLATION_RE.search(code)
                if pm:
                    errors.append(f"{rel}:{idx}: direct kernel/PAL symbol '{pm.group(0)}' outside src/os/")
                if "linux_sys.inc" in raw:
                    errors.append(f"{rel}:{idx}: forbidden legacy 'linux_sys.inc' include; use pal.inc")
            if in_os_pal:
                for pat, label in (
                    (UI_WIDGET_RE, "UI/App symbol"),
                    (TUI_RE, "TUI symbol"),
                    (I18N_RE, "i18n symbol"),
                    (FS_RE, "FS symbol"),
                ):
                    m = pat.search(code)
                    if m:
                        errors.append(f"{rel}:{idx}: layer violation in os PAL ({label}: {m.group(0)})")
            elif rel.startswith("src/core/"):
                for pat, label in (
                    (UI_WIDGET_RE, "UI/App symbol"),
                    (TUI_RE, "TUI symbol"),
                    (I18N_RE, "i18n symbol"),
                    (FS_RE, "FS symbol"),
                ):
                    m = pat.search(code)
                    if m:
                        errors.append(f"{rel}:{idx}: layer violation in core ({label}: {m.group(0)})")
            elif rel.startswith("src/tui/"):
                for pat, label in ((UI_WIDGET_RE, "UI/App symbol"), (FS_RE, "FS symbol")):
                    m = pat.search(code)
                    if m:
                        errors.append(f"{rel}:{idx}: layer violation in tui ({label}: {m.group(0)})")
            elif rel.startswith("src/fs/"):
                for pat, label in ((UI_WIDGET_RE, "UI/App symbol"), (TUI_RE, "TUI rendering/input symbol")):
                    m = pat.search(code)
                    if m:
                        errors.append(f"{rel}:{idx}: layer violation in fs ({label}: {m.group(0)})")

        if len(lines) > LINE_LIMIT_WARN:
            msg = f"{rel}: {len(lines)} lines (> {LINE_LIMIT_WARN}); extract new features into dedicated modules"
            if args.strict_size:
                errors.append(msg)
            else:
                warnings.append(msg)

    check_i18n_symmetry(root, errors)
    n_c = check_c_sources(root, errors)

    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(
        f"Modularity check passed: {len(all_disk_srcs)} assembly + {n_c} C modules, VERSION={ver}, "
        "PAL boundaries, layers & i18n symmetric, .data-free."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
