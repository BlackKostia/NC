#!/usr/bin/env python3
"""Split an over-long x86-64 GAS module into cohesive sibling modules (mechanical, link-safe).

The file is cut into *units* (a top-level label + body + its leading comments/.align), then:
  * units that fall through into each other, share `.L` labels, or use label-relative `.equ`
    constants are kept together;
  * `Parent__step` helpers stay with `Parent`;
  * data units follow the code that uses them (shared data stays in the first module);
  * every symbol defined in one part and used in another gets a `.global`;
  * the prelude (.include/.equ/.macro/.struct) is copied into each part;
  * new parts are registered in the Makefile right after the original.

Usage:
  split_module.py FILE [--max-lines 380] [--name SUFFIX=Routine,Routine ...] [--dry-run]
Without --name, consecutive routine groups are packed into parts named after their largest
routine (e.g. file_pane.s -> file_pane_render.s, file_pane_on_mouse.s).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from split_routine import Line, mnemonic, split_code  # noqa: E402

POSITIONAL: list[str] = []
TOP_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
LBL_RE = re.compile(r"^\s*(\.L[\w$.]*):")
SYM_RE = re.compile(r"(?<![\w.$])([A-Za-z_][\w$]*)(?![\w$.])")
LREF_RE = re.compile(r"(?<![\w.$])(\.L[\w$.]*)")
SECTION_RE = re.compile(r"^\s*(\.section\s+\S+.*|\.text|\.data|\.bss)\s*$")


class Unit:
    def __init__(self, section: str, sec_line: str):
        self.section = section
        self.sec_line = sec_line
        self.lines: list[str] = []
        self.name = ""
        self.defs: set[str] = set()
        self.ldefs: set[str] = set()
        self.equ_lbl: set[str] = set()  # label-relative .equ defined here

    def code(self):
        for t in self.lines:
            yield split_code(t)[0]

    @property
    def is_text(self):
        return self.section.startswith(".text")


def parse(lines: list[str]):
    """Return (prelude_defs, header, units, globals)."""
    header: list[str] = []
    defs: list[str] = []          # .include/.equ/.macro/.struct blocks (copied to every part)
    units: list[Unit] = []
    globals_: set[str] = set()
    section, sec_line = None, None
    pending: list[str] = []
    i = 0
    in_struct = False
    while i < len(lines):
        t = lines[i]
        s = t.strip()
        code = split_code(t)[0].strip()
        if code.startswith(".macro"):
            j = i
            while not lines[j].strip().startswith(".endm"):
                j += 1
            defs.extend(pending + lines[i:j + 1])
            pending = []
            i = j + 1
            continue
        if code.startswith(".if"):
            depth_if, j = 0, i
            while True:
                c2 = split_code(lines[j])[0].strip()
                depth_if += c2.startswith(".if")
                depth_if -= c2.startswith(".endif")
                if depth_if == 0:
                    break
                j += 1
            defs.extend(pending + lines[i:j + 1])
            pending = []
            i = j + 1
            continue
        if code.startswith(".extern"):
            defs.append(t)
            i += 1
            continue
        if code.startswith(".struct"):
            in_struct = True
            defs.extend(pending + [t])
            pending = []
            i += 1
            continue
        m_sec = SECTION_RE.match(code) if code else None
        if m_sec:
            in_struct = False
            section = code.split()[1] if code.startswith(".section") else code
            sec_line = code
            i += 1
            continue
        if in_struct:
            defs.append(t)
            i += 1
            continue
        if code.startswith(".global") or code.startswith(".globl"):
            for g in code.split(None, 1)[1].split(","):
                globals_.add(g.strip())
            i += 1
            continue
        if code.startswith((".intel_syntax", ".include")) or (
                code.startswith((".equ", ".set")) and not re.search(r"(?<![\w$])\.(?![\w])", code)):
            if section is None:
                header.extend(pending)
                pending = []
            defs.append(t)
            i += 1
            continue
        if section is None:
            if code:
                raise SystemExit(f"unexpected code before first section: {t}")
            header.append(t)
            i += 1
            continue
        m = TOP_RE.match(t) or (LBL_RE.match(t) if not section.startswith(".text") else None)
        if m:
            u = Unit(section, sec_line)
            u.name = m.group(1)
            u.lines = pending + [t]
            pending = []
            units.append(u)
            i += 1
            continue
        is_align = code.startswith((".align", ".p2align", ".balign"))
        if not code or is_align and (not section.startswith(".text") or not units_open_body(lines, i)):
            pending.append(t)
            i += 1
            continue
        if not units:
            raise SystemExit(f"code outside any unit: {t}")
        units[-1].lines.extend(pending + [t])
        pending = []
        if code.startswith((".equ", ".set")):
            units[-1].equ_lbl.add(code.split()[1].rstrip(","))
        i += 1
    if pending:
        if units:
            units[-1].lines.extend(pending)
        else:
            header.extend(pending)
    for u in units:
        u.defs.add(u.name)
        for c in u.code():
            if (m := LBL_RE.match(c)):
                u.ldefs.add(m.group(1))
    return header, defs, units, globals_


def units_open_body(lines, i):
    """An .align line belongs to the next unit if the next code line is a top-level label."""
    j = i + 1
    while j < len(lines) and not split_code(lines[j])[0].strip():
        j += 1
    return not (j < len(lines) and TOP_RE.match(lines[j]))


def falls_through(u: Unit) -> bool:
    if not u.is_text:
        return False
    last = ""
    for c in u.code():
        st = Line(c).stmts
        if st:
            last = st[-1]
    mn = mnemonic(last)[0] if last else ""
    return mn not in ("jmp", "ret", "ud2", "OS_EXIT")


def groups(units: list[Unit]) -> list[list[int]]:
    """Union units that must stay in the same module."""
    parent = list(range(len(units)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        parent[find(a)] = find(b)

    owner_l = {lb: k for k, u in enumerate(units) for lb in u.ldefs}
    owner_e = {e: k for k, u in enumerate(units) for e in u.equ_lbl}
    by_name = {u.name: k for k, u in enumerate(units)}
    for k, u in enumerate(units):
        if falls_through(u) and k + 1 < len(units):
            union(k, k + 1)
        if "__" in u.name and u.name.split("__")[0] in by_name:
            union(k, by_name[u.name.split("__")[0]])
        for c in u.code():
            for m in LREF_RE.finditer(c):
                if m.group(1) in owner_l:
                    union(k, owner_l[m.group(1)])
            for m in SYM_RE.finditer(c):
                if m.group(1) in owner_e:
                    union(k, owner_e[m.group(1)])
    out: dict[int, list[int]] = {}
    for k in range(len(units)):
        out.setdefault(find(k), []).append(k)
    return sorted(out.values(), key=lambda g: g[0])


def refs_of(u: Unit, names: set[str]) -> set[str]:
    out = set()
    for c in u.code():
        c = re.sub(r'"(?:[^"\\]|\\.)*"', "", c)
        for m in SYM_RE.finditer(c):
            if m.group(1) in names and m.group(1) != u.name:
                out.add(m.group(1))
    return out


def plan_parts(units, grps, max_lines, named: dict[str, list[str]], base: str, overhead: int):
    text_groups = [g for g in grps if any(units[k].is_text for k in g)]
    data_groups = [g for g in grps if not any(units[k].is_text for k in g)]
    size = lambda g: sum(len(units[k].lines) for k in g)  # noqa: E731
    assign: dict[int, str] = {}
    if named:
        for suffix, rnames in named.items():
            for gi, g in enumerate(text_groups):
                if any(units[k].name in rnames for k in g):
                    assign[gi] = suffix
    parts: list[tuple[str, list[int]]] = [(base, [])]
    cur = parts[0]
    budget = max_lines - overhead - 12
    for gi, g in enumerate(text_groups):
        if gi in assign:
            continue
        if size(cur[1]) + size(g) > budget and cur[1]:
            cur = ("", [])
            parts.append(cur)
        cur[1].extend(g)
    for suffix in dict.fromkeys(assign.values()):
        ks = [k for gi, g in enumerate(text_groups) if assign.get(gi) == suffix for k in g]
        parts.append((suffix, ks))
    # name unnamed parts after their largest routine
    named_parts = []
    for i, (suffix, ks) in enumerate(parts):
        if i and not suffix and i - 1 < len(POSITIONAL):
            suffix = POSITIONAL[i - 1]
        if i and not suffix:
            big = max(ks, key=lambda k: len(units[k].lines))
            nm = units[big].name.split("__")[0]
            nm = nm.split("_", 1)[1] if "_" in nm and nm[0].isupper() else nm
            suffix = re.sub(r"(?<=[a-z])(?=[A-Z])", "_", nm).lower()
        named_parts.append((suffix, ks))
    # data follows its users (code or other data, resolved to a fixpoint); most references win
    pending = list(data_groups)
    for _ in range(8):
        left = []
        for g in pending:
            gnames = {units[d].name for d in g}
            score: dict[int, int] = {}
            for pi, (_, ks) in enumerate(named_parts):
                for k in ks:
                    if refs_of(units[k], gnames):
                        score[pi] = score.get(pi, 0) + 1
            if score:
                target = max(sorted(score), key=lambda pi: score[pi])
                named_parts[target][1].extend(g)
            else:
                left.append(g)
        if len(left) == len(pending):
            break
        pending = left
    for g in pending:
        named_parts[0][1].extend(g)
    return named_parts


def render(header, defs, units, ks, globals_):
    out = list(header) + list(defs) + [""]
    secs = {}
    for k in sorted(ks):
        u = units[k]
        secs.setdefault(u.sec_line if not u.is_text else ".section .text", []).append(u)
    order = sorted(secs, key=lambda s: (".text" in s, s))
    for s in order:
        out.append(s)
        if ".text" in s:
            gl = [u.name for u in secs[s] if u.name in globals_]
            gl += [u.name for k in sorted(ks) for u in [units[k]] if not u.is_text and u.name in globals_]
            out.extend(f".global {g}" for g in gl)
            out.append("")
        for u in secs[s]:
            out.extend(u.lines)
        out.append("")
    if ".section .text" not in secs:
        gl = [units[k].name for k in sorted(ks) if units[k].name in globals_]
        if gl:
            out.insert(len(header) + len(defs) + 1, "\n".join(f".global {g}" for g in gl))
    while out and not out[-1].strip():
        out.pop()
    text = "\n".join(out) + "\n"
    return re.sub(r"\n{3,}", "\n\n", text)  # collapse blank-line runs left by moved units


def run(path: Path, max_lines: int, named: dict[str, list[str]], dry: bool) -> list[Path]:
    lines = path.read_text().rstrip("\n").split("\n")
    header, defs, units, globals_ = parse(lines)
    grps = groups(units)
    stem = path.stem
    parts = plan_parts(units, grps, max_lines, named, stem, len(header) + len(defs))
    part_of = {k: pi for pi, (_, ks) in enumerate(parts) for k in ks}
    names = {u.name: k for k, u in enumerate(units)}
    need_global = set(globals_)
    for k, u in enumerate(units):
        for r in refs_of(u, set(names)):
            if part_of[names[r]] != part_of[k]:
                need_global.add(r)
    outs = []
    title = (header[0] if header and header[0].startswith("#") else f"# {stem}").rstrip()
    for pi, (suffix, ks) in enumerate(parts):
        if not ks:
            continue
        p = path if pi == 0 else path.with_name(
            f"{suffix}.s" if suffix in POSITIONAL or suffix.startswith(stem) else f"{stem}_{suffix}.s")
        hdr = list(header)
        if pi:
            hdr = [f"{title} — {suffix.replace('_', ' ')} (split from {path.name})"] + \
                [h for h in header[1:] if not h.startswith("#")]
        text = render(hdr, defs, units, ks, need_global)
        outs.append((p, text))
    seen = set()
    for p, _ in outs:
        if p in seen:
            raise SystemExit(f"duplicate part name {p}: pass --name to choose distinct names")
        seen.add(p)
    for (p, text), (suffix, ks) in zip(outs, [x for x in parts if x[1]]):
        n = text.count("\n")
        rs = [units[k].name for k in sorted(ks) if units[k].is_text and "__" not in units[k].name]
        print(f"  {p}: {n} lines  [{', '.join(rs)}]")
        if not dry:
            p.write_text(text)
    if not dry:
        register(path, [p for p, _ in outs[1:]])
    return [p for p, _ in outs]


def register(orig: Path, new: list[Path]):
    root = orig
    while not (root / "Makefile").exists():
        root = root.parent
    mk = root / "Makefile"
    text = mk.read_text()
    rel = orig.resolve().relative_to(root.resolve()).as_posix()
    entry = f"\t{rel} \\\n"
    if entry not in text:
        raise SystemExit(f"{rel} not found in Makefile")
    add = "".join(f"\t{p.resolve().relative_to(root.resolve()).as_posix()} \\\n" for p in new)
    mk.write_text(text.replace(entry, entry + add, 1))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--max-lines", type=int, default=380)
    ap.add_argument("--name", action="append", default=[], help="SUFFIX=Routine,Routine")
    ap.add_argument("--names", default="", help="comma list of file names for parts 2..n")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    POSITIONAL.extend(x for x in a.names.split(",") if x)
    named = {}
    for n in a.name:
        suf, rs = n.split("=", 1)
        named[suf] = rs.split(",")
    run(Path(a.file), a.max_lines, named, a.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
