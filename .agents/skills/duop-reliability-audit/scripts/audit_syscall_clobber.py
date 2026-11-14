#!/usr/bin/env python3
"""Syscall Clobber Auditor for Duop x86-64 assembly.

On Linux x86-64, the `syscall` instruction (and any `OS_*` macro that expands
to `syscall`) overwrites `rcx` and `r11`. This auditor flags straight-line
code inside a routine where `rcx` or `r11` is set as a live value before
an `OS_*` / `syscall` instruction and then read immediately after without
being reloaded first.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]

RE_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
RE_OS_SYSCALL = re.compile(r"^(?:OS_[A-Z0-9_]+|syscall)\b")
RE_WRITE_CLOB = re.compile(
    r"^(?:mov|movzx|movsx|movsxd|lea|add|sub|and|or|xor|inc|dec|pop|imul|shl|shr)\s+"
    r"(r11[dwb]?|rcx|ecx|cx|cl|ch)\b"
)
RE_READ_RCX = re.compile(r"\b(?:rcx|ecx|cx|cl|ch)\b")
RE_READ_R11 = re.compile(r"\b(?:r11|r11d|r11w|r11b)\b")


def strip_comment(line: str) -> str:
    return line.split("#", 1)[0].strip()


def audit_file(path: Path) -> list[str]:
    findings: list[str] = []
    rel = path.relative_to(ROOT)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    # Track per-block live clobbered regs after OS_* / syscall
    clobbered: dict[str, tuple[int, str]] = {}
    written_before: dict[str, int] = {}

    for idx, raw in enumerate(lines, 1):
        s = strip_comment(raw)
        if not s:
            continue
        for stmt in [p.strip() for p in s.split(";") if p.strip()]:
            if re.match(r"^(?:\.?[A-Za-z_][A-Za-z0-9_]*|\d+):", stmt):
                clobbered.clear()
                written_before.clear()
                continue
            if re.match(r"^(?:jmp|j\w+|ret|call)\b", stmt):
                clobbered.clear()
                if stmt.startswith("call "):
                    written_before.clear()
                continue

            if RE_OS_SYSCALL.match(stmt):
                for reg, line_set in written_before.items():
                    clobbered[reg] = (idx, stmt)
                written_before.clear()
                continue

            mw = RE_WRITE_CLOB.match(stmt)
            dest_reg = None
            if mw:
                r = mw.group(1)
                dest_reg = "r11" if r.startswith("r11") else "rcx"
                # Check if source operand reads the clobbered reg before overwriting it
                src_part = stmt.split(",", 1)[1] if "," in stmt else ""
                if dest_reg in clobbered and (
                    (dest_reg == "rcx" and RE_READ_RCX.search(src_part))
                    or (dest_reg == "r11" and RE_READ_R11.search(src_part))
                ):
                    cline, cstmt = clobbered[dest_reg]
                    findings.append(
                        f"{rel}:{idx}: reads `{dest_reg}` clobbered by `{cstmt}` at line {cline} (`{stmt}`)"
                    )
                clobbered.pop(dest_reg, None)
                written_before[dest_reg] = idx
                continue

            if "rcx" in clobbered and RE_READ_RCX.search(stmt):
                cline, cstmt = clobbered.pop("rcx")
                findings.append(
                    f"{rel}:{idx}: reads `rcx` clobbered by `{cstmt}` at line {cline} (`{stmt}`)"
                )
            if "r11" in clobbered and RE_READ_R11.search(stmt):
                cline, cstmt = clobbered.pop("r11")
                findings.append(
                    f"{rel}:{idx}: reads `r11` clobbered by `{cstmt}` at line {cline} (`{stmt}`)"
                )

    return findings


def main() -> int:
    findings: list[str] = []
    s_files = sorted((ROOT / "src").rglob("*.s"))
    for p in s_files:
        findings.extend(audit_file(p))
    if findings:
        print(f"SYSCALL CLOBBER AUDIT FAILED ({len(findings)} issue(s)):")
        for f in findings:
            print(f"  - {f}")
        return 1
    print(f"SYSCALL CLOBBER AUDIT PASSED (checked {len(s_files)} .s files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
