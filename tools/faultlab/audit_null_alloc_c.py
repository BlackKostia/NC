#!/usr/bin/env python3
"""Allocation results used without a NULL check in freestanding C (out-of-memory -> SIGSEGV instead of an error).

C counterpart of audit_null_alloc.py (which reads assembly). For every `X = mem_alloc(..)` / `mem_realloc` /
`Object_alloc` / `nav_strdup` / `*_new(..)` in a function, the first following use of the lvalue X decides:

  DEREF   X[..], X->.., *X or memcpy-like use before any test      -> crash on OOM (exit 1)
  STORED  X written into another object / global before any test   -> latent crash at a later use (exit 1)
  (ok)    tested (`!X`, `X == nullptr`, `if (X)`, `X &&` ...), freed (mem_free is NULL-safe) or returned

Heuristic by design (line based, no preprocessor): it errs on the side of reporting. A deliberate exception carries
the comment `/* null-ok */` on the allocation line.

    audit_null_alloc_c.py [files...]        default: every src/**/*.c
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOC = re.compile(r"(?P<lv>[A-Za-z_][\w.\[\]>-]*)\s*=\s*(?:\([^)]*\)\s*)?(?P<fn>mem_alloc|mem_realloc|Object_alloc|nav_strdup|nav_tabs_alloc|\w+_new)\s*\(")
FUNC_END = re.compile(r"^\}")


def strip(line: str) -> str:
    line = re.sub(r"/\*.*?\*/", "", line)
    return line.split("//", 1)[0]


def tested(x: str, line: str) -> bool:
    e = re.escape(x)
    return bool(re.search(rf"(!\s*\(?\s*{e}\b|\b{e}\s*(?:==|!=)\s*(?:nullptr|NULL|0)\b|(?:nullptr|NULL)\s*(?:==|!=)\s*{e}\b|\bif\s*\(\s*{e}\s*\)|\b{e}\s*(?:&&|\|\|)|(?:&&|\|\|)\s*{e}\b|\?\s*{e}\b|\bwhile\s*\(\s*{e}\b)", line))


def classify(x: str, line: str) -> str | None:
    e = re.escape(x)
    if re.search(rf"\bmem_free\s*\(\s*{e}\s*\)", line) or re.search(rf"\breturn\s+{e}\s*;", line):
        return "ok"
    if tested(x, line):
        return "ok"
    if re.search(rf"\b{e}\s*(?:\[|->|\+\+|--)", line) or re.search(rf"(?<![\w)])\*\s*\(?\s*{e}\b", line):
        return "DEREF"
    if re.search(rf"[=]\s*{e}\s*[;,]", line) and not re.search(rf"\b{e}\s*=", line):
        return "STORED"                               # something_else = X;
    return None


def audit_file(path: Path) -> list[str]:
    try:
        shown = str(path.relative_to(ROOT))
    except ValueError:
        shown = str(path)
    return audit_text(path.read_text(encoding="utf-8"), shown)


def audit_text(text: str, name: str) -> list[str]:
    findings: list[str] = []
    raw = text.splitlines()
    lines = [strip(ln) for ln in raw]
    for i, line in enumerate(lines):
        m = ALLOC.search(line)
        if not m or "null-ok" in raw[i] or m.group("fn").endswith("_nodiscard"):
            continue
        before = line[: m.start()]
        if re.search(r"\b(?:if|while)\s*\(\s*!?\s*\(?\s*$", before):
            continue                                   # `if (!(p = mem_alloc(..)))`: tested in place
        x = m.group("lv")
        if x.startswith(("*", "&")):
            continue
        # statements after the allocation on the same line, then the following lines of the function
        tail = line[m.end():].split(";", 1)[1:]
        stream = [(i, stmt) for stmt in (tail[0].split(";") if tail else [])] + [(j, lines[j]) for j in range(i + 1, min(i + 60, len(lines)))]
        for j, text in stream:
            if FUNC_END.match(text) or re.search(rf"(?<![\w*.>\]])\b{re.escape(x)}\s*=(?!=)", text):          # reassigned (not `*x = ..`)
                break
            kind = classify(x, text)
            if kind == "ok":
                break
            if kind in ("DEREF", "STORED"):
                findings.append(f"{kind:6} {name}:{j + 1}: {x} from {m.group('fn')}() (line {i + 1}) used before a NULL test")
                break
    return findings


def main(argv: list[str]) -> int:
    files = [ROOT / a for a in argv] if argv else sorted((ROOT / "src").rglob("*.c"))
    files = [f if f.is_absolute() else ROOT / f for f in files]
    findings = [f for p in files if p.is_file() for f in audit_file(p)]
    for f in findings:
        print(f)
    print(f"audit_null_alloc_c: {len(findings)} unchecked allocation use(s) in {len(files)} C file(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
