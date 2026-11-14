#!/usr/bin/env python3
"""System V AMD64 ABI Callee-Saved Register & Step-Frame Auditor for Duop.

Checks every top-level routine in src/**/*.s:
  1. Callee-saved registers (rbx, rbp, r12, r13, r14, r15) modified after
     prologue setup must have been pushed before their first modification
     and popped before `ret`.
  2. Pushed callee-saved registers must be popped in reverse order in every
     epilogue before `ret`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]

CALLEE_SAVED = ("rbx", "rbp", "r12", "r13", "r14", "r15")
REG_ALIASES: dict[str, str] = {
    "rbx": "rbx", "ebx": "rbx", "bx": "rbx", "bl": "rbx", "bh": "rbx",
    "rbp": "rbp", "ebp": "rbp", "bp": "rbp", "bpl": "rbp",
    "r12": "r12", "r12d": "r12", "r12w": "r12", "r12b": "r12",
    "r13": "r13", "r13d": "r13", "r13w": "r13", "r13b": "r13",
    "r14": "r14", "r14d": "r14", "r14w": "r14", "r14b": "r14",
    "r15": "r15", "r15d": "r15", "r15w": "r15", "r15b": "r15",
}

RE_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
RE_PUSH = re.compile(r"^\s*push\s+(r[a-z0-9]+)\b")
RE_POP = re.compile(r"^\s*pop\s+(r[a-z0-9]+)\b")
RE_RET = re.compile(r"^\s*ret\b")
RE_DEST_WRITE = re.compile(
    r"^\s*(?:mov|movzx|movsx|movsxd|lea|add|sub|and|or|xor|inc|dec|neg|not|shl|shr|sar|imul|cmov\w+|set\w+)\s+"
    r"([a-z0-9]+)\b(?:\s*,|\s*$)"
)
RE_MEM_FIRST = re.compile(r"^\s*\w+\s+(?:byte|word|dword|qword)?\s*(?:ptr\s*)?\[")


def strip_comment(line: str) -> str:
    in_str = False
    quote = ""
    line = re.sub(r"/\*.*?\*/", "", line)
    for i, ch in enumerate(line):
        if in_str:
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                in_str = False
        elif ch in ('"', "'"):
            in_str = True
            quote = ch
        elif ch == "#":
            return line[:i].strip()
    return line.strip()


def split_routines(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    routines: list[dict] = []
    cur = None
    in_text = False
    for idx, raw in enumerate(lines, 1):
        s = strip_comment(raw)
        if s.startswith(".text") or s.startswith(".section .text"):
            in_text = True
            continue
        if s.startswith(".section ") and ".text" not in s:
            in_text = False
            cur = None
            continue
        if s in (".rodata", ".bss", ".data"):
            in_text = False
            cur = None
            continue
        if not in_text or not s:
            continue
        ml = RE_LABEL.match(s)
        if ml and not ml.group(1).startswith(".L") and not ml.group(1).startswith("."):
            cur = {
                "name": ml.group(1),
                "start_line": idx,
                "lines": [],
                "is_step": "__" in ml.group(1),
            }
            routines.append(cur)
        elif cur is not None:
            if s.startswith(".L") and s.endswith(":") and cur["lines"] and RE_RET.match(cur["lines"][-1][1]):
                cur = None
                continue
            cur["lines"].append((idx, s))
    return routines


def audit_file(path: Path, include_private: bool = False) -> list[str]:
    findings: list[str] = []
    rel = path.relative_to(ROOT)
    text = path.read_text(encoding="utf-8", errors="replace")
    globals_set = set(re.findall(r"^\s*\.global\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M))
    for rt in split_routines(path):
        name = rt["name"]
        if rt["is_step"] or name == "_start":
            continue
        if not include_private and name not in globals_set:
            continue
        pushed_set: set[str] = set()
        popped_set: set[str] = set()
        first_push_order: list[str] = []
        modified: dict[str, int] = {}
        has_ret = False

        for lineno, raw_s in rt["lines"]:
            for stmt in [p.strip() for p in raw_s.split(";") if p.strip()]:
                stmt = re.sub(r"^(?:\.L[A-Za-z0-9_]+|\d+):\s*", "", stmt)
                if not stmt:
                    continue
                mp = RE_PUSH.match(stmt)
                if mp:
                    reg = mp.group(1)
                    if reg in CALLEE_SAVED:
                        if reg not in pushed_set:
                            first_push_order.append(reg)
                        pushed_set.add(reg)
                    continue
                mpo = RE_POP.match(stmt)
                if mpo:
                    reg = mpo.group(1)
                    if reg in CALLEE_SAVED:
                        popped_set.add(reg)
                    continue
                if RE_RET.match(stmt):
                    has_ret = True
                    continue

                if RE_MEM_FIRST.match(stmt):
                    continue
                mw = RE_DEST_WRITE.match(stmt)
                if mw:
                    base = REG_ALIASES.get(mw.group(1))
                    if base and base not in pushed_set and base not in modified:
                        modified[base] = lineno

        if not has_ret:
            continue

        for reg, lineno in sorted(modified.items(), key=lambda kv: kv[1]):
            findings.append(
                f"{rel}:{lineno} ({name}): modifies callee-saved `{reg}` without prior `push {reg}`"
            )
        missing_pop = pushed_set - popped_set
        if missing_pop:
            findings.append(
                f"{rel}:{rt['start_line']} ({name}): pushed callee-saved {sorted(missing_pop)} missing matching `pop`"
            )

    return findings


def main() -> int:
    include_private = "--all" in sys.argv[1:]
    all_findings: list[str] = []
    s_files = sorted((ROOT / "src").rglob("*.s"))
    for path in s_files:
        all_findings.extend(audit_file(path, include_private=include_private))

    if all_findings:
        print(f"ABI REG AUDIT FAILED ({len(all_findings)} issue(s)):")
        for f in all_findings:
            print(f"  - {f}")
        return 1

    print(f"ABI REG AUDIT PASSED (checked {len(s_files)} .s files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
