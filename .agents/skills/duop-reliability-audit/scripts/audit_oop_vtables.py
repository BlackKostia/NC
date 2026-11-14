#!/usr/bin/env python3
"""OOP Class & VTable Integrity Auditor for Duop.

Parses VTBL_BEGIN/VTBL_EXTENDS/VTBL_SLOT and *_VTBL_SLOTS macros from
include/classes.inc and include/oop.inc, then verifies every vtable
instantiation in src/**/*.s matches its expected slot count and order.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]

RE_VTBL_BEGIN = re.compile(r"^\s*VTBL_BEGIN\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_VTBL_EXTENDS = re.compile(r"^\s*VTBL_EXTENDS\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_VTBL_SLOT = re.compile(r"^\s*VTBL_SLOT\s+([A-Za-z0-9_.]+)")
RE_VTBL_END = re.compile(r"^\s*VTBL_END\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_VTBL_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*_vtable)\s*:")
RE_MACRO_CALL = re.compile(r"^\s*(OBJECT_VTBL_SLOTS|WIDGET_VTBL_SLOTS|DIALOG_VTBL_SLOTS)\b")


def strip_comment(line: str) -> str:
    in_str = False
    quote = ""
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


def parse_vtbl_specs() -> dict[str, int]:
    """Return {VtblName: slot_count} from include/classes.inc."""
    classes_inc = ROOT / "include/classes.inc"
    vtbls: dict[str, int] = {}
    cur_name: str | None = None
    cur_slots = 0
    for raw in classes_inc.read_text(encoding="utf-8", errors="replace").splitlines():
        s = strip_comment(raw)
        if not s:
            continue
        mb = RE_VTBL_BEGIN.match(s)
        if mb:
            cur_name = mb.group(1)
            cur_slots = 0
            continue
        if cur_name:
            me = RE_VTBL_EXTENDS.match(s)
            if me:
                cur_slots += vtbls.get(me.group(1), 0)
                continue
            if RE_VTBL_SLOT.match(s):
                cur_slots += 1
                continue
            mend = RE_VTBL_END.match(s)
            if mend:
                vtbls[cur_name] = cur_slots
                cur_name = None
    return vtbls


def check_vtable_defs(vtbls: dict[str, int]) -> list[str]:
    findings: list[str] = []
    macro_slots = {
        "OBJECT_VTBL_SLOTS": vtbls.get("ObjectVtbl", 4),
        "WIDGET_VTBL_SLOTS": vtbls.get("WidgetVtbl", 10),
        "DIALOG_VTBL_SLOTS": vtbls.get("DialogVtbl", 12),
    }

    for path in sorted((ROOT / "src").rglob("*.s")):
        rel = path.relative_to(ROOT)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        cur_vtbl: str | None = None
        cur_line = 0
        slot_count = 0
        expected_min = vtbls.get("ObjectVtbl", 4)

        def finish() -> None:
            nonlocal cur_vtbl
            if cur_vtbl is None:
                return
            if slot_count < expected_min:
                findings.append(
                    f"{rel}:{cur_line} ({cur_vtbl}): only {slot_count} slots (expected >= {expected_min})"
                )
            cur_vtbl = None

        for idx, raw in enumerate(lines, 1):
            s = strip_comment(raw)
            if not s:
                continue
            ml = RE_VTBL_LABEL.match(s)
            if ml:
                finish()
                cur_vtbl = ml.group(1)
                cur_line = idx
                slot_count = 0
                expected_min = vtbls.get("ObjectVtbl", 4)
                continue
            if cur_vtbl:
                if s.startswith(".") and not s.startswith(".quad") and not s.startswith(".align"):
                    finish()
                    continue
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", s):
                    finish()
                    continue
                mm = RE_MACRO_CALL.match(s)
                if mm:
                    mname = mm.group(1)
                    slot_count += macro_slots[mname]
                    expected_min = max(expected_min, macro_slots[mname])
                    continue
                if s.startswith(".quad"):
                    slot_count += len([x for x in s[5:].split(",") if x.strip()])
        finish()
    return findings


def main() -> int:
    vtbls = parse_vtbl_specs()
    findings = check_vtable_defs(vtbls)
    if findings:
        print(f"OOP VTABLE AUDIT FAILED ({len(findings)} issue(s)):")
        for f in findings:
            print(f"  - {f}")
        return 1
    print(f"OOP VTABLE AUDIT PASSED (Object={vtbls.get('ObjectVtbl')}, Widget={vtbls.get('WidgetVtbl')}, Dialog={vtbls.get('DialogVtbl')} slots)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
