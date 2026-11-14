#!/usr/bin/env python3
"""Auto-generate docs/SYMBOLS.md from include/**/*.inc and src/**/*.s.
Tracks all structs, OOP classes, vtable contracts, and exported .global APIs
organized by Duop's strict downward architectural layers.

Usage:
  python3 gen_symbols_catalog.py          # regenerate docs/SYMBOLS.md
  python3 gen_symbols_catalog.py --check  # exit 1 if docs/SYMBOLS.md is stale
"""
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
OUT_PATH = os.path.join(ROOT, "docs", "SYMBOLS.md")

LAYERS = [
    ("OS PAL (`src/os/`)", "src/os/"),
    ("Core Runtime (`src/core/`)", "src/core/"),
    ("TUI Engine (`src/tui/`)", "src/tui/"),
    ("Filesystem & Codecs (`src/fs/`)", "src/fs/"),
    ("UI Widgets & Dialogs (`src/ui/`)", "src/ui/"),
    ("App Controller & Entry (`src/app/`, `src/main.s`)", ("src/app/", "src/main.s")),
]


def iter_files(subdir, ext):
    base = os.path.join(ROOT, subdir)
    out = []
    for dp, _, fns in os.walk(base):
        for fn in sorted(fns):
            if fn.endswith(ext):
                out.append(os.path.join(dp, fn))
    return sorted(out)


def parse_includes():
    structs, classes, vtables = [], [], []
    for path in iter_files("include", ".inc"):
        rel = os.path.relpath(path, ROOT)
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        cur_struct = None
        cur_class = None
        cur_vtbl = None
        for ln in lines:
            s = ln.split("#", 1)[0].strip()
            if not s:
                continue
            if s.startswith(".struct"):
                cur_struct = {"file": rel, "name": None, "fields": []}
            elif cur_struct is not None:
                m = re.match(r"^([A-Za-z_]\w*)\.(\w+)\s*:", s)
                if m:
                    if cur_struct["name"] is None:
                        cur_struct["name"] = m.group(1)
                    if m.group(2) == "_size":
                        structs.append(cur_struct)
                        cur_struct = None
                    else:
                        cur_struct["fields"].append(m.group(2))
                elif not s.startswith("."):
                    cur_struct = None
            m_cb = re.match(r"^CLASS_BEGIN\s+([A-Za-z_]\w*)", s)
            if m_cb:
                cur_class = {"file": rel, "name": m_cb.group(1), "parent": "-", "fields": []}
                continue
            if cur_class is not None:
                m_ex = re.match(r"^EXTENDS\s+([A-Za-z_]\w*)", s)
                if m_ex:
                    cur_class["parent"] = m_ex.group(1)
                    continue
                m_fd = re.match(r"^FIELD\s+[^,]+,\s*([A-Za-z_]\w*)", s)
                if m_fd:
                    cur_class["fields"].append(m_fd.group(1))
                    continue
                if s.startswith("CLASS_END"):
                    classes.append(cur_class)
                    cur_class = None
            m_vb = re.match(r"^VTBL_BEGIN\s+([A-Za-z_]\w*)", s)
            if m_vb:
                cur_vtbl = {"file": rel, "name": m_vb.group(1), "parent": "-", "slots": []}
                continue
            m_ve = re.match(r"^VTBL_EXTENDS\s+([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)", s)
            if m_ve:
                cur_vtbl = {"file": rel, "name": m_ve.group(1), "parent": m_ve.group(2), "slots": []}
                continue
            if cur_vtbl is not None:
                m_vs = re.match(r"^VTBL_SLOT\s+([A-Za-z_]\w*)", s)
                if m_vs:
                    cur_vtbl["slots"].append(m_vs.group(1))
                elif s.startswith("VTBL_END"):
                    vtables.append(cur_vtbl)
                    cur_vtbl = None
    return structs, classes, vtables


def parse_asm_module(path):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    globals_list = []
    vtables = []
    sigs = {}
    for i, ln in enumerate(lines):
        m_g = re.match(r"^\s*\.global\s+([A-Za-z_]\w*)", ln)
        if m_g:
            globals_list.append(m_g.group(1))
        m_lbl = re.match(r"^([A-Za-z_]\w*)\s*:", ln)
        if m_lbl:
            sym = m_lbl.group(1)
            if sym.endswith("_vtable"):
                vtables.append(sym)
            sig = ""
            if i > 0 and lines[i - 1].lstrip().startswith("#"):
                sig = lines[i - 1].lstrip("# ").strip()
            sigs[sym] = sig
    return globals_list, vtables, sigs


def classify_layer(rel):
    for title, prefix in LAYERS:
        if isinstance(prefix, tuple):
            if any(rel.startswith(p) or rel == p for p in prefix):
                return title
        elif rel.startswith(prefix):
            return title
    return "Other"


def build_markdown():
    structs, classes, vtables = parse_includes()
    modules = {title: [] for title, _ in LAYERS}
    total_globals = 0
    for path in iter_files("src", ".s"):
        rel = os.path.relpath(path, ROOT)
        g_list, v_list, sigs = parse_asm_module(path)
        total_globals += len(g_list)
        layer = classify_layer(rel)
        modules.setdefault(layer, []).append((rel, g_list, v_list, sigs))

    out = [
        "# Duop Architecture & Symbol Catalog (`docs/SYMBOLS.md`)",
        "",
        "> Auto-generated by `.agents/skills/duop-docs-sync/scripts/gen_symbols_catalog.py` (`make symbols`). Do not edit manually.",
        "",
        "## Summary",
        "",
        f"- **Structs (`.struct`)**: {len(structs)}",
        f"- **OOP Classes (`CLASS_BEGIN`)**: {len(classes)}",
        f"- **Vtable Contracts (`VTBL_*`)**: {len(vtables)}",
        f"- **Exported `.global` Symbols**: {total_globals}",
        "",
        "## Structs (`include/*.inc`)",
        "",
        "| Struct | Defined In | Fields |",
        "|---|---|---|",
    ]
    for st in structs:
        fields = ", ".join(f"`{f}`" for f in st["fields"]) or "-"
        out.append(f"| `{st['name']}` | `{st['file']}` | {fields} |")

    out += ["", "## OOP Classes (`CLASS_BEGIN`)", "", "| Class | Extends | Defined In | Fields |", "|---|---|---|---|"]
    for cl in classes:
        fields = ", ".join(f"`{f}`" for f in cl["fields"]) or "-"
        out.append(f"| `{cl['name']}` | `{cl['parent']}` | `{cl['file']}` | {fields} |")

    out += ["", "## Vtable Contracts (`VTBL_*`)", "", "| Interface | Extends | Defined In | Slots |", "|---|---|---|---|"]
    for vt in vtables:
        slots = ", ".join(f"`{s}`" for s in vt["slots"]) or "-"
        out.append(f"| `{vt['name']}` | `{vt['parent']}` | `{vt['file']}` | {slots} |")

    out += ["", "## Exported Symbols by Layer (`src/`)"]
    for title, _ in LAYERS:
        mods = modules.get(title, [])
        out += ["", f"### {title}", ""]
        for rel, g_list, v_list, sigs in mods:
            if not g_list and not v_list:
                continue
            out.append(f"- **`{rel}`**")
            if v_list:
                out.append("  - Vtables: " + ", ".join(f"`{v}`" for v in v_list))
            for g in g_list:
                sig = sigs.get(g, "")
                out.append(f"  - `{g}`" + (f" — {sig}" if sig else ""))
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="Verify docs/SYMBOLS.md is up to date")
    args = ap.parse_args()
    content = build_markdown()
    if args.check:
        if not os.path.exists(OUT_PATH):
            print("FAIL: docs/SYMBOLS.md does not exist. Run: make symbols", file=sys.stderr)
            return 1
        cur = open(OUT_PATH, encoding="utf-8").read()
        if cur != content:
            print("FAIL: docs/SYMBOLS.md is out of date. Run: make symbols", file=sys.stderr)
            return 1
        print("OK: docs/SYMBOLS.md is up to date.")
        return 0
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Generated {os.path.relpath(OUT_PATH, ROOT)} ({len(content.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
