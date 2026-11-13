#!/usr/bin/env python3
"""Static modularity, ABI-hygiene, i18n-parity, and version checker for Duop."""

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


def parse_makefile_var(makefile_path: Path, var_name: str) -> list[str]:
    text = makefile_path.read_text(encoding="utf-8")
    m = re.search(rf"^{re.escape(var_name)}\s*:=\s*(.*?)(?:\n\n|\n[A-Z_]+\s*[:+]?=)", text, re.S | re.M)
    if not m:
        raise ValueError(f"Could not locate {var_name} := block in Makefile")
    block = m.group(1).replace("\\\n", " ")
    return [tok.strip() for tok in block.split() if tok.strip().endswith(".s")]


def parse_makefile_srcs(makefile_path: Path) -> tuple[list[str], list[str]]:
    srcs = parse_makefile_var(makefile_path, "SRCS")
    pal_raw = parse_makefile_var(makefile_path, "PAL_SRCS")
    pal_default = [p.replace("$(OS)", "linux").replace("$(ARCH)", "x86_64") for p in pal_raw]
    return srcs, pal_default


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
    types_path = root / "include/types.inc"
    i18n_path = root / "src/tui/i18n.s"
    if not types_path.is_file() or not i18n_path.is_file():
        errors.append("Missing include/types.inc or src/tui/i18n.s for i18n check")
        return

    types_text = types_path.read_text(encoding="utf-8")
    m = re.search(
        r"LangStrings\.code:.*?LangStrings\._size:", types_text, re.S
    )
    if not m:
        errors.append("Could not parse LangStrings struct in include/types.inc")
        return

    expected_slots = 0
    for line in m.group(0).splitlines():
        clean = strip_asm_comment_and_strings(line)
        sm = re.search(r"\.space\s+(\d+(?:\s*\*\s*\d+)?)", clean)
        if sm:
            expr = sm.group(1).replace(" ", "")
            if "*" in expr:
                a, b = expr.split("*", 1)
                bytes_sz = int(a) * int(b)
            else:
                bytes_sz = int(expr)
            if bytes_sz % 8 != 0:
                errors.append(f"LangStrings non-8-byte field size: {bytes_sz}")
            expected_slots += bytes_sz // 8

    i18n_text = i18n_path.read_text(encoding="utf-8")
    for tbl in ("lang_en_table", "lang_ua_table"):
        tm = re.search(
            rf"{tbl}:\s*(.*?)\.if\s*\(\.\s*-\s*{tbl}\)\s*!=\s*LangStrings\._size",
            i18n_text,
            re.S,
        )
        if not tm:
            errors.append(
                f"Missing {tbl} or compile-time size guard (.if (. - {tbl}) != LangStrings._size) in src/tui/i18n.s"
            )
            continue
        ptrs = 0
        for line in tm.group(1).splitlines():
            clean = strip_asm_comment_and_strings(line).strip()
            if clean.startswith(".quad"):
                items = [x.strip() for x in clean[5:].split(",") if x.strip()]
                ptrs += len(items)
        if ptrs != expected_slots:
            errors.append(
                f"{tbl} has {ptrs} pointers, but LangStrings has {expected_slots} pointer slots"
            )


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

    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(
        f"Modularity check passed: {len(all_disk_srcs)} assembly modules, VERSION={ver}, "
        "PAL boundaries, layers & i18n symmetric, .data-free."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
