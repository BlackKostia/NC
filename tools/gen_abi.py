#!/usr/bin/env python3
"""gen_abi.py - C structs from the assembler layouts (docs/HYBRID_PORTABILITY_PLAN.md, phase P1 / E3).

The `.inc` files stay the source of truth until the last `.s` consumer is gone; this tool turns every
`CLASS_BEGIN ... FIELD ... CLASS_END` class and every `.struct 0` block of include/classes.inc (and what it includes)
into a C struct, so the C ports of src/ui and src/app share the exact layout of the assembler.

* Offsets and sizes are evaluated by `as` (symbolic sizes such as PATH_MAX or 4*HitZone._size resolve there), never guessed.
* A field is `uint8_t/16/32/64_t` by size, `uint8_t name[N]` otherwise; a trailing comment `@c <ctype>` overrides it
  (`# @c DirModel *`, `# @c char[256]`) - how a pointer gets its type when a module migrates.
* A class with `EXTENDS P` embeds `P base;` first. A struct whose natural C layout would differ from the assembler's
  (unaligned field, trailing padding) is emitted `__attribute__((packed))`.
* Structs already written by hand in include/duop_*.h (full body) are skipped; every emitted struct carries
  `_Static_assert`s of its size and every field offset, so a drifting `.inc` fails the C build, not a runtime test.
* LP64 only (pointers 8 bytes): the 4-byte ARM32 pointer variant is stage 5 of the plan.

  gen_abi.py --out build/duop_classes.h [--source classes.inc] [-I DIR]... [--handwritten GLOB] [--json FILE]
"""

from __future__ import annotations

import argparse
import glob
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEYWORDS = {
    "alignas", "alignof", "auto", "bool", "break", "case", "char", "const", "constexpr", "continue", "default", "do", "double", "else",
    "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int", "long", "nullptr", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "static_assert", "struct", "switch", "thread_local", "true", "typedef", "typeof", "union", "unsigned",
    "void", "volatile", "while",
}
INT_TYPES = {1: "uint8_t", 2: "uint16_t", 4: "uint32_t", 8: "uint64_t"}


class GenError(Exception):
    pass


@dataclass
class Field:
    asm: str                       # name after `Class.`
    size_expr: str
    comment: str = ""
    offset: int = 0
    size: int = 0
    ctype: str = ""                # C type (array suffix in `array`)
    array: str = ""

    @property
    def name(self) -> str:
        return self.asm + "_" if self.asm in KEYWORDS else self.asm


@dataclass
class Struct:
    name: str
    parent: str | None = None
    fields: list[Field] = field(default_factory=list)
    size: int = 0
    parent_size: int = 0
    packed: bool = False
    source: str = ""


def split_comment(line: str) -> tuple[str, str]:
    """Code and comment of one asm line (`# ...` or `/* ... */`)."""
    m = re.search(r"/\*(.*?)\*/", line)
    if m:
        return (line[:m.start()] + line[m.end():]).strip(), m.group(1).strip()
    if "#" in line:
        code, _, com = line.partition("#")
        return code.strip(), com.strip()
    return line.strip(), ""


def parse_text(text: str, source: str) -> tuple[list[Struct], list[str]]:
    """(structs, nested `.include` names) of one .inc file."""
    structs: list[Struct] = []
    includes: list[str] = []
    cur: Struct | None = None
    block: str | None = None              # `.struct 0` block being read: expected struct name (or "" before the first label)
    for no, raw in enumerate(text.splitlines(), 1):
        code, com = split_comment(raw)
        where = f"{source}:{no}"
        if (m := re.match(r'\.include\s+"([^"]+)"', code)):
            includes.append(m.group(1))
        elif (m := re.match(r"CLASS_BEGIN\s+(\w+)\s*$", code)):
            cur = Struct(m.group(1), source=where)
        elif cur and (m := re.match(r"EXTENDS\s+(\w+)\s*$", code)):
            cur.parent = m.group(1)
        elif cur and code.startswith("FIELD"):
            m = re.match(r"FIELD\s+(\w+)\.(\w+)\s*,\s*(\S+)\s*$", code)
            if not m or m.group(1) != cur.name:
                raise GenError(f"{where}: cannot parse FIELD line: {raw.strip()!r}")
            cur.fields.append(Field(m.group(2), m.group(3), com))
        elif cur and re.match(r"CLASS_END\s+" + cur.name + r"\s*$", code):
            structs.append(cur)
            cur = None
        elif re.match(r"\.struct\s+0\s*$", code):
            block = ""
        elif block is not None and (m := re.match(r"(\w+)\.(\w+)\s*:\s*(.*)$", code)):
            name, fld, rest = m.groups()
            if block == "":
                block = name
                cur = Struct(name, source=where)
            if name != block:
                raise GenError(f"{where}: field of {name} inside the block of {block}")
            if fld == "_size":
                structs.append(cur)
                cur, block = None, None
                continue
            sm = re.match(r"\.space\s+(\S+)\s*$", rest)
            if not rest.strip():                       # `Name.tail:` with nothing after it: flexible array member
                cur.fields.append(Field(fld, "0", com))
            elif not sm:
                raise GenError(f"{where}: cannot parse {name}.{fld} (only `.space N` is supported): {raw.strip()!r}")
            else:
                cur.fields.append(Field(fld, sm.group(1), com))
    return structs, includes


def collect(sources: list[str], incdirs: list[Path]) -> list[Struct]:
    out: list[Struct] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        for d in incdirs:
            if (d / name).is_file():
                found, nested = parse_text((d / name).read_text(encoding="utf-8"), name)
                break
        else:
            return                        # not ours (e.g. a target header): no structs to read
        for inc in nested:                # included files are defined before the includer continues
            visit(inc)
        out.extend(found)

    for s in sources:
        visit(s)
        if not any((d / s).is_file() for d in incdirs):
            raise GenError(f"source {s} not found in {[str(d) for d in incdirs]}")
    return out


def offending_lines(stderr: str) -> str:
    """The source lines the assembler complained about (it names files and line numbers, not the symbol)."""
    shown: list[str] = []
    for m in re.finditer(r"^(\S+):(\d+): (?:Error|Info)", stderr, re.M):
        path, no = Path(m.group(1)), int(m.group(2))
        if path.is_file():
            text = path.read_text(encoding="utf-8").splitlines()
            if no <= len(text) and f"{path.name}:{no}: {text[no - 1].strip()}" not in shown:
                shown.append(f"{path.name}:{no}: {text[no - 1].strip()}")
    return ("\noffending source lines:\n  " + "\n  ".join(shown)) if shown else ""


def evaluate(structs: list[Struct], sources: list[str], incdirs: list[Path]) -> None:
    """Fill in offsets and sizes with the assembler."""
    syms: list[str] = []
    for s in structs:
        syms += [f"{s.name}.{f.asm}" for f in s.fields] + [f"{s.name}._size"]
        if s.parent:
            syms.append(f"{s.parent}._size")
    syms = sorted(set(syms))
    with tempfile.TemporaryDirectory() as t:
        src = Path(t) / "layout.s"
        body = "".join(f'.include "{s}"\n' for s in sources)
        src.write_text(".intel_syntax noprefix\n" + body + ".section .text\n" +
                       "".join(f".globl V_{i}\n.set V_{i}, {n}\n" for i, n in enumerate(syms)))
        cmd = ["as", *[a for d in incdirs for a in ("-I", str(d))], str(src), "-o", str(Path(t) / "layout.o")]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise GenError("assembler rejected the layout:\n" + res.stderr.strip() + offending_lines(res.stderr))
        vals: dict[str, int] = {}
        for line in subprocess.run(["nm", str(Path(t) / "layout.o")], capture_output=True, text=True, check=True).stdout.splitlines():
            m = re.match(r"([0-9a-fA-F]+)\s+[aAnN]\s+V_(\d+)$", line)
            if m:
                vals[syms[int(m.group(2))]] = int(m.group(1), 16)
    for s in structs:
        s.size = vals[f"{s.name}._size"]
        for f in s.fields:
            f.offset = vals[f"{s.name}.{f.asm}"]
        for i, f in enumerate(s.fields):
            nxt = s.fields[i + 1].offset if i + 1 < len(s.fields) else s.size
            f.size = nxt - f.offset
            if f.size < 0 or (f.size == 0 and (i + 1 < len(s.fields) or f.size_expr != "0")):
                raise GenError(f"{s.source}: {s.name}.{f.asm} has size {f.size}")
        if s.parent:
            s.parent_size = vals[f"{s.parent}._size"]
            if s.fields and s.fields[0].offset != s.parent_size:
                raise GenError(f"{s.source}: {s.name}.{s.fields[0].asm} starts at {s.fields[0].offset}, parent {s.parent} ends at {s.parent_size}")


def apply_types(s: Struct) -> None:
    for f in s.fields:
        m = re.search(r"@c\s+(.+?)\s*$", f.comment)
        if m:
            t = m.group(1)
            am = re.match(r"^(.*?)\s*(\[[^\]]*\])$", t)
            f.ctype, f.array = (am.group(1), am.group(2)) if am else (t, "")
        elif f.size == 0:
            f.ctype, f.array = "uint8_t", "[]"
        elif f.size in INT_TYPES:
            f.ctype, f.array = INT_TYPES[f.size], ""
        else:
            f.ctype, f.array = "uint8_t", f"[{f.size}]"


def field_align(f: Field) -> int:
    """Alignment plain C gives the field (an array has its element's; unknown struct types are guessed by size)."""
    if f.array:
        return 1                                   # uint8_t[N], char[N]
    if f.ctype in INT_TYPES.values():
        return f.size
    if "*" in f.ctype:
        return 8
    return next(a for a in (8, 4, 2, 1) if f.size % a == 0)


def natural_layout(s: Struct, aligns: dict[str, int]) -> int | None:
    """Alignment of the plain C struct when it reproduces the assembler layout exactly, else None (emit it packed).
    A hand-written parent is assumed 8-aligned (Object holds a pointer); `_Static_assert`s catch a wrong guess."""
    off, amax = (s.parent_size, aligns.get(s.parent, 8)) if s.parent else (0, 1)
    for f in s.fields:
        a = field_align(f)
        amax = max(amax, a)
        off = (off + a - 1) // a * a
        if off != f.offset:
            return None
        off += f.size
    return amax if (off + amax - 1) // amax * amax == s.size else None


def handwritten(globs: list[str]) -> dict[str, str]:
    """name -> header for every struct with a full body in the given headers."""
    out: dict[str, str] = {}
    for g in globs:
        for h in sorted(glob.glob(g)):
            text = Path(h).read_text(encoding="utf-8")
            for n in set(re.findall(r"\bstruct\s+(\w+)\s*\{", text)) | set(re.findall(r"\}\s*(\w+)\s*;", text)):
                out.setdefault(n, Path(h).name)
    return out


def emit(structs: list[Struct], hand: dict[str, str], sources: list[str]) -> str:
    gen = {s.name for s in structs}
    need = {"duop_abi.h"} | {hand[s.parent] for s in structs if s.parent and s.parent not in gen and s.parent in hand}
    for s in structs:
        if s.parent and s.parent not in gen and s.parent not in hand:
            raise GenError(f"{s.source}: parent {s.parent} of {s.name} is neither generated nor hand-written")
    lines = [f"/* Generated by tools/gen_abi.py from {', '.join(sources)} - DO NOT EDIT. LP64 only (8-byte pointers). */",
             "#pragma once"] + [f'#include "{h}"' for h in sorted(need)]
    lines += ['', '_Static_assert(sizeof(void *) == 8, "duop_classes.h describes the LP64 layouts (ARM32 pointers: plan stage 5)");', '']
    for s in order(structs):
        attr = " __attribute__((packed))" if s.packed else ""
        lines.append(f"struct{attr} {s.name} {{")
        if s.parent:
            lines.append(f"    {s.parent} base;")
        for f in s.fields:
            com = f"  /* {f.comment.replace('*/', '* /')} */" if f.comment and "@c" not in f.comment else ""
            lines.append(f"    {f.ctype} {f.name}{f.array};{com}")
        lines.append("};")
        lines.append(f"typedef struct {s.name} {s.name};")
        lines.append(f'_Static_assert(sizeof({s.name}) == {s.size}, "{s.name} size differs from the assembler");')
        for f in s.fields:
            lines.append(f'_Static_assert(offsetof({s.name}, {f.name}) == {f.offset}, "{s.name}.{f.asm} offset differs from the assembler");')
        lines.append("")
    return "\n".join(lines)


def order(structs: list[Struct]) -> list[Struct]:
    """Parents before children, otherwise declaration order."""
    done: list[Struct] = []
    names = {s.name: s for s in structs}

    def add(s: Struct) -> None:
        if s in done:
            return
        if s.parent in names:
            add(names[s.parent])
        done.append(s)

    for s in structs:
        add(s)
    return done


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", action="append", default=None, help="top-level .inc (default: classes.inc)")
    ap.add_argument("-I", dest="incdirs", action="append", default=None, help="include dirs (default: include, include/os/linux/x86_64)")
    ap.add_argument("--handwritten", action="append", default=None, help="glob of headers whose structs are hand-written (default include/duop_*.h)")
    ap.add_argument("--json", help="also dump the evaluated layout")
    a = ap.parse_args()
    sources = a.source or ["classes.inc"]
    incdirs = [Path(d) for d in (a.incdirs or [str(ROOT / "include"), str(ROOT / "include/os/linux/x86_64")])]
    hand = handwritten(a.handwritten or [str(ROOT / "include/duop_*.h")])
    try:
        structs = collect(sources, incdirs)
        names = [s.name for s in structs]
        dup = {n for n in names if names.count(n) > 1}
        if dup:
            raise GenError(f"struct defined twice: {sorted(dup)}")
        evaluate(structs, sources, incdirs)
        structs = [s for s in structs if s.name not in hand]
        aligns: dict[str, int] = {}
        for s in order(structs):
            apply_types(s)
            aligns[s.name] = natural_layout(s, aligns) or 1
            s.packed = natural_layout(s, aligns) is None
        text = emit(structs, hand, sources)
    except GenError as e:
        print(f"gen_abi: {e}", file=sys.stderr)
        return 1
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(text + "\n", encoding="utf-8")
    if a.json:
        Path(a.json).write_text(json.dumps({"structs": [
            {"name": s.name, "parent": s.parent, "size": s.size, "packed": s.packed,
             "fields": [{"name": f.name, "asm": f.asm, "offset": f.offset, "size": f.size, "ctype": f.ctype + f.array} for f in s.fields]}
            for s in order(structs)]}, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
