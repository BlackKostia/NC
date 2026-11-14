#!/usr/bin/env python3
"""Silent truncation at recursion / capacity caps.

Finds `cmp <reg>, <NAME>` against MAX/CAP/LIMIT constants followed by a conditional jump and
classifies what happens at the cap: an error code / flag (ok) or a plain success return with a
partial result (WARN: data silently missing, e.g. Disk Usage ignoring folders deeper than N).
"""

from __future__ import annotations

import re
import sys

from asm_index import ROOT, rel, routines, sources

CAP_RE = re.compile(r"^cmp\s+\w+\s*,\s*(\w*(?:MAX|CAP|LIMIT)\w*)\b")
EQU_RE = re.compile(r"^\.equ\s+(\w+)\s*,\s*(.+)$")


def constants() -> dict[str, str]:
    out = {}
    for p in list(sources()) + sorted((ROOT / "include").rglob("*.inc")):
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            m = EQU_RE.match(raw.strip())
            if m:
                out.setdefault(m.group(1), m.group(2).split("#")[0].strip())
    return out


def main() -> int:
    consts = constants()
    rows = []
    for p in sources():
        if "/src/ui/" in p.as_posix():
            continue                                  # widget layout clamps are not data loss
        for name, _, body in routines(p):
            for i, (ln, ins) in enumerate(body):
                m = CAP_RE.match(ins)
                if m and re.search(r"_W_|PX_|_H_", m.group(1)):
                    continue
                if not m or i + 1 >= len(body):
                    continue
                jmp = body[i + 1][1]
                if not jmp.startswith("j"):
                    continue
                target = jmp.split()[-1]
                tail = []
                for k, (_, t) in enumerate(body):
                    if t.startswith(target + ":") or (k and body[k - 1][1].endswith(target + ":")):
                        tail = [x for _, x in body[k:k + 6]]
                        break
                text = " ; ".join(tail)
                error = re.search(r"-E[A-Z]+|mov\s+\w+,\s*-\d|or\s+.*FLAG|TRUNC|overflow", text)
                rows.append((rel(p), ln, name, m.group(1), consts.get(m.group(1), "?"),
                             "error/flag" if error else "SILENT?"))
    silent = [r for r in rows if r[5] == "SILENT?"]
    for f, ln, name, cap, val, kind in rows:
        tag = "WARN" if kind == "SILENT?" else "ok  "
        print(f"{tag}: {f}:{ln}: {name}: cap {cap} = {val} -> {kind}")
    print(f"DEPTH/CAP AUDIT: {len(rows)} caps, {len(silent)} may truncate silently (review)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
