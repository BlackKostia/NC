#!/usr/bin/env python3
"""Lean-module gate for Duop: keeps every module short, single-purpose and well structured.

Budgets (lines incl. comments/blank lines):
  src/**/*.s        module <= 600, top-level routine <= 120, exported symbols <= 24
  include/**/*.inc  header <= 400
  tests/*.py        suite  <= 700, def <= 150

Legacy offenders are frozen in lean_baseline.json as a *ratchet*: a listed file / routine may
shrink but never grow; anything new must meet the budgets. When a legacy item shrinks the
baseline is tightened with --update (it can never be loosened by the tool).

Usage:
  check_lean.py [--root DIR]            full check (exit 1 on violations)
  check_lean.py --file PATH [--lines N] check one file (optionally with a prospective size)
  check_lean.py --staged                check the staged (index) versions of staged files (pre-commit)
  check_lean.py --update                tighten baseline to current sizes (never raises)
  check_lean.py --report                show the largest modules / routines
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parents[1]
BASELINE = SKILL_DIR / "scripts" / "lean_baseline.json"

BUDGET = {
    ".s": {"file": 600, "func": 120, "exports": 24},
    ".inc": {"file": 400},
    ".py": {"file": 700, "func": 150},
}

ASM_LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
ASM_GLOBAL_RE = re.compile(r"^\s*\.global\s+(.+)$")
PY_DEF_RE = re.compile(r"^(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)")


def scanned_files(root: Path) -> list[Path]:
    out = sorted((root / "src").rglob("*.s")) + sorted((root / "include").rglob("*.inc"))
    out += sorted(p for p in (root / "tests").glob("*.py") if p.name != "__init__.py")
    return out


def rel(root: Path, p: Path) -> str:
    return p.resolve().relative_to(root.resolve()).as_posix()


def asm_routines(lines: list[str]) -> list[tuple[str, int]]:
    """Top-level (non .L) labels in .text and the length of the code that follows each."""
    starts: list[tuple[str, int]] = []
    section = ".text"
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith(".section"):
            section = s.split()[1] if len(s.split()) > 1 else section
        elif s in (".text", ".data", ".bss"):
            section = s
        m = ASM_LABEL_RE.match(ln)
        if m and section.startswith(".text"):
            starts.append((m.group(1), i))
        elif m or s.startswith(".section"):
            starts.append(("", i))  # data label / section switch ends the previous routine
    out = []
    for k, (name, i) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(lines)
        if name:
            out.append((name, end - i))
    return out


def py_routines(lines: list[str]) -> list[tuple[str, int]]:
    starts = [(m.group(1), i) for i, ln in enumerate(lines) if (m := PY_DEF_RE.match(ln))]
    out = []
    for k, (name, i) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(lines)
        out.append((name, end - i))
    return out


def measure(path: Path, text: str | None = None) -> dict:
    if text is None:
        text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    m = {"lines": len(lines), "funcs": [], "exports": 0}
    if path.suffix == ".s":
        m["funcs"] = asm_routines(lines)
        m["exports"] = sum(len([t for t in g.group(1).split(",") if t.strip()])
                           for ln in lines if (g := ASM_GLOBAL_RE.match(ln)))
    elif path.suffix == ".py":
        m["funcs"] = py_routines(lines)
    return m


def load_baseline() -> dict:
    if BASELINE.is_file():
        return json.loads(BASELINE.read_text(encoding="utf-8"))
    return {"files": {}, "funcs": {}, "exports": {}}


def check_one(rp: str, path: Path, base: dict, text: str | None = None) -> list[str]:
    bud = BUDGET.get(path.suffix)
    if not bud:
        return []
    m = measure(path, text)
    errs = []
    lim = max(bud["file"], base["files"].get(rp, 0))
    if m["lines"] > lim:
        how = "frozen legacy size" if rp in base["files"] else "module budget"
        errs.append(f"{rp}: {m['lines']} lines > {lim} ({how}). Split it: move a cohesive "
                    f"subsystem into a new focused module (see duop-lean-modules).")
    if "func" in bud:
        for name, n in m["funcs"]:
            key = f"{rp}:{name}"
            flim = max(bud["func"], base["funcs"].get(key, 0))
            if n > flim:
                errs.append(f"{key}: {n} lines > {flim}. Extract helper routines "
                            f"(one responsibility per routine).")
    if "exports" in bud:
        elim = max(bud["exports"], base["exports"].get(rp, 0))
        if m["exports"] > elim:
            errs.append(f"{rp}: {m['exports']} exported symbols > {elim}. "
                        f"Narrow the public API or split the module.")
    return errs


def full_check(root: Path) -> list[str]:
    base = load_baseline()
    errs: list[str] = []
    for p in scanned_files(root):
        errs += check_one(rel(root, p), p, base)
    return errs


def staged_check(root: Path) -> list[str]:
    """Commit gate: judge exactly what is being committed (index content), nothing else."""
    out = subprocess.run(["git", "-C", str(root), "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                         text=True, capture_output=True, check=False).stdout.split()
    base = load_baseline()
    errs: list[str] = []
    for rp in out:
        p = root / rp
        top = rp.split("/", 1)[0]
        if p.suffix not in BUDGET or top not in ("src", "include", "tests"):
            continue
        if top == "tests" and rp.count("/") != 1:
            continue
        blob = subprocess.run(["git", "-C", str(root), "show", f":{rp}"], text=True,
                              capture_output=True, check=False).stdout
        errs += check_one(rp, p, base, blob)
    return errs


def update_baseline(root: Path) -> None:
    """Tighten (never loosen) the ratchet: shrink entries, drop compliant ones."""
    base = load_baseline()
    new = {"files": {}, "funcs": {}, "exports": {}}
    for p in scanned_files(root):
        rp = rel(root, p)
        bud = BUDGET.get(p.suffix)
        if not bud:
            continue
        m = measure(p)
        old = base["files"].get(rp)
        if old is not None and m["lines"] > bud["file"]:
            new["files"][rp] = min(old, m["lines"])
        if "func" in bud:
            for name, n in m["funcs"]:
                key = f"{rp}:{name}"
                o = base["funcs"].get(key)
                if o is not None and n > bud["func"]:
                    new["funcs"][key] = min(o, n)
        if "exports" in bud:
            o = base["exports"].get(rp)
            if o is not None and m["exports"] > bud["exports"]:
                new["exports"][rp] = min(o, m["exports"])
    BASELINE.write_text(json.dumps(new, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Baseline tightened: {len(new['files'])} legacy files, {len(new['funcs'])} legacy routines.")


def report(root: Path) -> None:
    rows, funcs = [], []
    for p in scanned_files(root):
        rp = rel(root, p)
        m = measure(p)
        rows.append((m["lines"], rp))
        funcs += [(n, f"{rp}:{name}") for name, n in m["funcs"]]
    print("Largest modules:")
    for n, rp in sorted(rows, reverse=True)[:12]:
        print(f"  {n:6d}  {rp}")
    print("Largest routines:")
    for n, k in sorted(funcs, reverse=True)[:12]:
        print(f"  {n:6d}  {k}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Duop lean-module gate")
    ap.add_argument("--root", default=str(SKILL_DIR.parents[2]))
    ap.add_argument("--file")
    ap.add_argument("--text-from", help="read prospective file content from this path ('-' = stdin)")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--staged", action="store_true")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    root = Path(a.root).resolve()

    if a.update:
        update_baseline(root)
        return 0
    if a.report:
        report(root)
        return 0
    if a.staged:
        errs = staged_check(root)
    elif a.file:
        p = Path(a.file)
        if not p.is_absolute():
            p = root / p
        text = None
        if a.text_from:
            text = sys.stdin.read() if a.text_from == "-" else Path(a.text_from).read_text(encoding="utf-8")
        errs = check_one(rel(root, p), p, load_baseline(), text)
    else:
        errs = full_check(root)

    for e in errs:
        print(f"LEAN: {e}", file=sys.stderr)
    if errs:
        return 1
    print("Lean-module check passed (module, routine and API budgets respected).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
