#!/usr/bin/env python3
"""Mechanically decompose over-long x86-64 GAS routines into frame-sharing step helpers.

A contiguous block [a, b) of a routine body is moved into a new local routine and replaced by
`call <Routine>__<step>`.  The helper runs on the caller's stack frame:

    Routine__step:
        lea rsp, [rsp - 8]          # keep 16-byte alignment (return address + pad)
        <block, every rsp-relative operand shifted by +16>
    .LRoutine__step_ret:
        lea rsp, [rsp + 8]
        ret
    .LRoutine__step_x1:            # exit stub: drop the helper frame, continue in the caller
        lea rsp, [rsp + 16]
        jmp <original target>

`call`/`lea`/`ret` never touch flags and every general-purpose register flows through the block
unchanged, so the transformation is semantics-preserving when the block is *valid*:
  * no label inside the block is referenced from outside it (entry only at the top);
  * the block keeps a balanced stack (push/pop, sub/add rsp) and only leaves it at depth 0;
  * no ret/leave/indirect jmp, no rsp writes (mov/and/xchg rsp), no red-zone access, no data;
  * numeric local labels resolve inside the block; loop/jrcxz never leave the block.

Usage:
  split_routine.py FILE [--routine NAME ...] [--max-func 80] [--dry-run]
Without --routine every top-level routine longer than --max-func is decomposed.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

LABEL_RE = re.compile(r"^\s*((?:\.L[\w$.]*|[A-Za-z_][\w.$]*|\d+)):(?!:)")
TOP_LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
LOCAL_REF_RE = re.compile(r"(?<![\w.$])(\.L[\w$.]*)")
NUM_REF_RE = re.compile(r"(?<![\w.$])(\d+)([bf])\b")
RSP_RE = re.compile(r"(?<![\w.$])(rsp|esp|spl|sp)(?![\w$])")
MEM_RE = re.compile(r"\[([^\]]*)\]")
STEP_RE = re.compile(r"[A-Za-z_]\w*__\w+")
COND_SHORT = {"loop", "loope", "loopne", "loopz", "loopnz", "jrcxz", "jecxz", "jcxz"}
DATA_DIRS = (".byte", ".word", ".short", ".long", ".int", ".quad", ".ascii", ".asciz",
             ".string", ".space", ".zero", ".fill", ".octa", ".section", ".data", ".bss")

MAX_SEG = 60
MIN_SEG = 6


def split_code(line: str) -> tuple[str, str]:
    """Return (code, comment) honouring quotes."""
    q = None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            # GAS char literal 'x' or 'x (unterminated) — treat 'x' as a 3-char token
            if c == "'" and i + 2 < len(line) and line[i + 2] == "'":
                i += 3
                continue
            if c == "'" and i + 1 < len(line):
                i += 2
                continue
            q = c
        elif c == "#":
            return line[:i], line[i:]
        i += 1
    return line, ""


def statements(code: str) -> list[str]:
    out, q, cur, i = [], None, "", 0
    while i < len(code):
        c = code[i]
        if q:
            cur += c
            if c == "\\" and i + 1 < len(code):
                cur += code[i + 1]
                i += 2
                continue
            if c == q:
                q = None
        elif c == "'" and i + 2 < len(code) and code[i + 2] == "'":
            cur += code[i:i + 3]
            i += 3
            continue
        elif c == '"':
            q = c
            cur += c
        elif c == ";":
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        out.append(cur.strip())
    return [s for s in out if s]


class Line:
    def __init__(self, text: str):
        self.text = text
        code, self.comment = split_code(text)
        self.labels: list[str] = []
        rest = code
        while True:
            m = LABEL_RE.match(rest)
            if not m:
                break
            self.labels.append(m.group(1))
            rest = rest[m.end():]
        self.stmts = statements(rest)
        self.code_after_labels = rest

    @property
    def is_stmt(self) -> bool:
        return bool(self.stmts)

    @property
    def blank(self) -> bool:
        return not self.labels and not self.stmts


def mnemonic(stmt: str) -> tuple[str, str]:
    parts = stmt.split(None, 1)
    return parts[0].lower(), (parts[1].strip() if len(parts) > 1 else "")


def is_label_token(op: str) -> bool:
    return bool(re.fullmatch(r"[.A-Za-z_][\w.$]*|\d+[bf]", op)) and op.lower() not in REGS


REGS = {r for r in (
    "rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 "
    "eax ebx ecx edx esi edi ebp esp r8d r9d r10d r11d r12d r13d r14d r15d").split()}


def preprocess(lines: list[str], only: set[str] | None = None) -> list[str]:
    """Split `label: stmt` inside the routines being decomposed into two lines so blocks can
    start right after a label (other routines keep their formatting)."""
    out = []
    secs = section_of(lines)
    inside = [False] * len(lines)
    for name, a, b in routines(lines):
        if only is None or name in only:
            for i in range(a, b):
                inside[i] = True
    for t, sec, ins in zip(lines, secs, inside):
        ln = Line(t)
        if ins and sec.startswith(".text") and ln.labels and ln.stmts:
            code, comment = split_code(t)
            rest, m_end = code, 0
            while (m := LABEL_RE.match(rest)):
                m_end += m.end()
                rest = rest[m.end():]
            out.append(code[:m_end].strip())
            out.append("    " + rest.strip() + (("  " + comment) if comment else ""))
        else:
            out.append(t)
    return out


def section_of(lines: list[str]) -> list[str]:
    sec, out = ".text", []
    for t in lines:
        s = t.strip()
        if s.startswith(".section"):
            sec = s.split()[1].rstrip(",") if len(s.split()) > 1 else sec
        elif s in (".text", ".data", ".bss"):
            sec = s
        elif s.startswith(".struct"):
            sec = ".struct"
        out.append(sec)
    return out


def routines(lines: list[str]) -> list[tuple[str, int, int]]:
    secs = section_of(lines)
    starts = []
    for i, t in enumerate(lines):
        m = TOP_LABEL_RE.match(t)
        s = t.strip()
        if m and secs[i].startswith(".text"):
            starts.append((m.group(1), i))
        elif m or s.startswith(".section") or s in (".data", ".bss") or s.startswith(".struct"):
            starts.append(("", i))
    out = []
    for k, (name, i) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(lines)
        if name:
            # trailing comment/blank lines belong to the next routine's header
            j = end
            while j - 1 > i and (not lines[j - 1].strip() or lines[j - 1].lstrip().startswith("#")):
                j -= 1
            out.append((name, i, j))
    return out


class Analyzer:
    def __init__(self, lines: list[str], start: int, end: int):
        self.all = [Line(t) for t in lines]
        self.start, self.end = start, end
        # global .L references: label -> list of line indices
        self.refs: dict[str, list[int]] = {}
        for i, ln in enumerate(self.all):
            code = ln.code_after_labels
            for m in LOCAL_REF_RE.finditer(code):
                self.refs.setdefault(m.group(1), []).append(i)
        self.numdefs: dict[str, list[int]] = {}
        for i in range(start, end):
            for lb in self.all[i].labels:
                if lb.isdigit():
                    self.numdefs.setdefault(lb, []).append(i)
        self.numpairs = []
        for i in range(start, end):
            for m in NUM_REF_RE.finditer(self.all[i].code_after_labels):
                self.numpairs.append((i, self.num_target(i, m.group(1), m.group(2))))

    def num_target(self, i: int, n: str, d: str) -> int | None:
        defs = self.numdefs.get(n, [])
        if d == "b":
            c = [x for x in defs if x <= i]
            return c[-1] if c else None
        c = [x for x in defs if x > i]
        return c[0] if c else None

    def follow_labels(self, b: int) -> set[str]:
        out, L = set(), self.all
        while b < len(L) and not L[b].stmts:
            out.update(L[b].labels)
            b += 1
        return out

    def check(self, a: int, b: int, strict: bool = True):
        """Return (ok, exits, rewrites) for block [a,b) (absolute line indices).

        strict: the block may only leave by falling off its end or jumping to the label that
        directly follows it (single-entry / single-exit step).
        rewrites: {(line, stmt_index): new_stmt} -- operands addressing the *caller's* frame
        are shifted by +16; slots pushed/allocated inside the block keep their offsets."""
        L = self.all
        bad = (False, None, None)
        follow = self.follow_labels(b)
        if not L[a].is_stmt or L[a].labels:
            return bad
        defs = set()
        for i in range(a, b):
            for lb in L[i].labels:
                defs.add(lb)
        for lb in defs:
            if lb.isdigit():
                continue
            for r in self.refs.get(lb, []):
                if not (a <= r < b):
                    return bad
        for i, t in self.numpairs:
            if t is None or (a <= i < b) != (a <= t < b):
                return bad
        depth = 0
        exits = set()
        rw: dict[tuple[int, int], str] = {}
        for i in range(a, b):
            for k, st in enumerate(L[i].stmts):
                mn, ops = mnemonic(st)
                o = [x.strip() for x in ops.split(",")] if ops else []
                if mn.startswith(".") and mn not in (".align", ".p2align", ".balign", ".equ", ".set"):
                    return bad
                if mn in ("ret", "retq", "leave", "enter", "iret", "iretq", "pushf", "popf"):
                    return bad
                if mn in ("push", "pushq", "pushfq", "pop", "popq", "popfq"):
                    if RSP_RE.search(ops):
                        return bad
                    depth += 8 if mn.startswith("push") else -8
                    if depth < 0:
                        return bad
                    continue
                if mn in ("sub", "add") and o and o[0] == "rsp":
                    v = CONSTS.eval(o[1]) if len(o) > 1 else None
                    if v is None:
                        return bad
                    depth += v if mn == "sub" else -v
                    if depth < 0:
                        return bad
                    continue
                if mn == "lea" and o and o[0] == "rsp":
                    m = re.fullmatch(r"\[\s*rsp\s*([+-])\s*(.+?)\s*\]", o[1] if len(o) > 1 else "")
                    v = CONSTS.eval(m.group(2)) if m else None
                    if v is None:
                        return bad
                    depth += v if m.group(1) == "-" else -v
                    if depth < 0:
                        return bad
                    continue
                if mn.startswith("j") or mn in COND_SHORT:
                    tgt = ops.strip()
                    if not is_label_token(tgt):
                        return bad  # indirect jump
                    if NUM_REF_RE.fullmatch(tgt):
                        continue
                    if tgt not in defs:
                        if mn in COND_SHORT or depth != 0:
                            return bad
                        if strict and tgt not in follow:
                            return bad
                        exits.add(tgt)
                    continue
                if mn == "call":
                    if RSP_RE.search(ops) or STEP_RE.fullmatch(ops.strip()):
                        return bad  # steps assume a direct call from their parent
                    if ops.strip() in STACK_ARG_CALLEES:
                        return bad  # callee reads stack-passed arguments from our frame
                    continue
                for m in LOCAL_REF_RE.finditer(ops):
                    if m.group(1) not in defs and mn not in ("lea", "mov"):
                        return bad
                if not RSP_RE.search(ops):
                    continue
                stripped = MEM_RE.sub("[]", ops)
                if RSP_RE.search(stripped):
                    if not (mn == "mov" and len(o) == 2 and o[1] == "rsp" and o[0] in REGS):
                        return bad
                    if depth:
                        return bad  # pointer into block-local slots: arithmetic may cross frames
                    rw[(i, k)] = f"lea {o[0]}, [rsp + 16]"
                    continue
                new_ops, ok = ops, True

                def rep(m):
                    nonlocal ok
                    inner = m.group(1)
                    if not RSP_RE.search(inner):
                        return m.group(0)
                    if not re.fullmatch(r"\s*rsp\b.*", inner):
                        ok = False  # rsp must be the base register
                        return m.group(0)
                    rest = inner.strip()[3:].strip()
                    if re.search(r"(?<![\w.$])(r\w+|e[a-ds][xip]|e[sd]i)\b", rest):
                        off = None if depth else 0     # index register: only at depth 0
                        if off is None:
                            ok = False
                            return m.group(0)
                    else:
                        if rest.startswith("-"):
                            ok = False                 # red zone / below the frame
                            return m.group(0)
                        off = CONSTS.eval(rest.lstrip("+").strip()) if rest else 0
                        if off is None:
                            if depth:
                                ok = False
                                return m.group(0)
                            off = 0
                    if off >= depth:
                        return "[" + inner.rstrip() + " + 16]"
                    if mn == "lea":
                        ok = False  # address of a block-local slot (may be re-based later)
                    return m.group(0)
                new_ops = MEM_RE.sub(rep, ops)
                if not ok:
                    return bad
                if new_ops != ops:
                    rw[(i, k)] = st[:len(st) - len(ops)] + new_ops
        if depth != 0:
            return bad
        return True, exits, rw


class Consts:
    """Assemble-time constants (.equ/.set and .struct field offsets) for offset arithmetic."""

    def __init__(self):
        self.v: dict[str, int] = {}
        self.raw: dict[str, str] = {}

    def load(self, lines: list[str]):
        off = None
        for t in lines:
            code = split_code(t)[0].strip()
            if not code:
                continue
            m = re.match(r"\.(?:equ|set)\s+([\w.$]+)\s*,\s*(.+)$", code)
            if m:
                self.raw[m.group(1)] = m.group(2)
                continue
            if code.startswith(".struct"):
                off = self.eval(code.split(None, 1)[1]) if len(code.split()) > 1 else 0
                continue
            if code.startswith((".section", ".text", ".data", ".bss")):
                off = None
                continue
            if off is None:
                continue
            m = re.match(r"([\w.$]+):\s*(.*)$", code)
            if m:
                self.v[m.group(1)] = off
                code = m.group(2).strip()
                if not code:
                    continue
            m = re.match(r"\.(space|zero|skip|byte|word|short|long|int|quad)\s*(.*)$", code)
            if m:
                kind, arg = m.groups()
                if kind in ("space", "zero", "skip"):
                    n = self.eval(arg.split(",")[0])
                    off = None if n is None else off + n
                else:
                    size = {"byte": 1, "word": 2, "short": 2, "long": 4, "int": 4, "quad": 8}[kind]
                    off += size * max(1, len(arg.split(",")))

    def eval(self, expr: str, depth: int = 0):
        expr = expr.strip()
        if depth > 20 or not expr:
            return None

        def sym(m):
            n = m.group(0)
            if n in self.v:
                return str(self.v[n])
            if n in self.raw:
                r = self.eval(self.raw[n], depth + 1)
                if r is not None:
                    self.v[n] = r
                    return str(r)
            raise KeyError(n)
        try:
            e = re.sub(r"(?<![\w$.])[A-Za-z_][\w.$]*", sym, expr)
            if not re.fullmatch(r"[\d\sxXa-fA-F+\-*/()<>|&~%]+", e):
                return None
            return int(eval(e.replace("/", "//"), {"__builtins__": {}}, {}))
        except Exception:
            return None


CONSTS = Consts()
STACK_ARG_CALLEES: set[str] = set()


def find_stack_arg_callees(files: list[Path]) -> set[str]:
    """Routines that read arguments passed on the caller's stack ([rsp + frame + 8 ...])."""
    out = set()
    for f in files:
        if "aarch64" in f.parts:
            continue
        lines = f.read_text().split("\n")
        for name, a, b in routines(lines):
            depth = 0
            for t in lines[a + 1:b]:
                for st in Line(t).stmts:
                    mn, ops = mnemonic(st)
                    o = [x.strip() for x in ops.split(",")]
                    if mn in ("push", "pop"):
                        depth += 8 if mn == "push" else -8
                    elif mn in ("sub", "add") and o[0] == "rsp":
                        v = CONSTS.eval(o[1]) if len(o) > 1 else None
                        depth = -10 ** 9 if v is None else depth + (v if mn == "sub" else -v)
                    else:
                        for m in re.finditer(r"\[\s*rsp\s*\+\s*([^\]]+)\]", ops):
                            v = CONSTS.eval(m.group(1))
                            if v is not None and depth >= 0 and v >= depth + 8:
                                out.add(name)
    out.discard("_start")
    return out


def load_consts(path: Path):
    root = path.resolve()
    while root.parent != root and not (root / "Makefile").exists():
        root = root.parent
    for inc in sorted((root / "include").rglob("*.inc")):
        if "aarch64" in inc.parts or "freebsd" in inc.parts:
            continue
        CONSTS.load(inc.read_text().split("\n"))
    for inc in (root / "build").glob("*.inc"):
        CONSTS.load(inc.read_text().split("\n"))
    CONSTS.load(path.read_text().split("\n"))
    STACK_ARG_CALLEES.clear()
    srcs = sorted((root / "src").rglob("*.s")) if (root / "src").is_dir() else []
    STACK_ARG_CALLEES.update(find_stack_arg_callees(srcs + [path]))


def rewrite_line(text: str, i: int, rw: dict, exit_map: dict[str, str]) -> str:
    code, comment = split_code(text)
    ln = Line(text)
    if not ln.stmts:
        return text
    indent = re.match(r"\s*", code).group(0) or "    "
    new = []
    for k, st in enumerate(ln.stmts):
        st2 = rw.get((i, k), st)
        mn, ops = mnemonic(st2)
        if (mn.startswith("j") or mn in COND_SHORT) and ops.strip() in exit_map:
            st2 = f"{mn} {exit_map[ops.strip()]}"
        new.append(st2)
    body = "; ".join(new)
    if new == ln.stmts:
        return text
    return indent + body + (("  " + comment.strip()) if comment else "")


def slug(text: str) -> str:
    words = re.findall(r"[A-Za-z0-9]+", text.lower())
    stop = {"the", "a", "an", "of", "to", "and", "for", "in", "on", "if", "is", "with", "at"}
    words = [w for w in words if w not in stop][:4]
    return "_".join(words)[:32]


def nice_boundary(L: list[Line], i: int) -> bool:
    """Line i starts a natural step (after a comment, blank line, label, jmp or ret)."""
    if i <= 0 or i >= len(L):
        return True
    p = L[i - 1]
    if not p.text.strip() or (p.comment and not p.stmts) or (p.labels and not p.stmts):
        return True
    return bool(p.stmts) and mnemonic(p.stmts[-1])[0] in ("jmp", "ret")


LAYOUT_RE = re.compile(r"\[?\s*rsp\s*[+\]]|^\[|=\s*\w+\s*\(\d+\)")
MINOR_CALLS = {"ScreenBuffer_set_pen", "mem_copy", "mem_set", "str_len", "str_copy", "str_cat",
               "i18n_get", "theme_get", "utf8_display_width", "sys_clock_ms", "u64_to_dec",
               "mem_alloc", "mem_free", "str_cmp", "str_eq"}


def _comment_text(c: str) -> str:
    t = c.lstrip("#").strip()
    if LAYOUT_RE.search(t):
        return ""
    t = re.sub(r"^\d+[a-z]?[.)]\s*", "", t)          # "3. Draw divider" -> "Draw divider"
    t = re.sub(r'"[^"]*"|\([^)]*\)?|\[[^\]]*\]?', " ", t)  # drop literals / formulas
    if "=" in t:
        left, right = t.split("=", 1)
        t = left if re.search(r"[A-Za-z]{3,}", left) else right
    words = [w for w in re.findall(r"[A-Za-z][A-Za-z0-9_]*", t) if len(w) > 1]
    return " ".join(words) if any(len(w) >= 3 for w in words) else ""


def is_header(L: list[Line], i: int) -> bool:
    """A step-header comment line (`# 3. Draw divider`, `# Footer summary`)."""
    if i >= len(L) or L[i].stmts or L[i].labels or not L[i].comment:
        return False
    return bool(_comment_text(L[i].comment)) and nice_boundary(L, i)


def describe(L: list[Line], a: int, b: int | None = None) -> str:
    """Name a block after the step comment above it, the first comment in it, or its main call."""
    j = a - 1
    while j >= 0 and not L[j].stmts and not L[j].labels:
        if L[j].comment and (t := _comment_text(L[j].comment)):
            return t
        j -= 1
    end = b if b is not None else min(a + 6, len(L))
    for i in range(a, end):
        if L[i].comment and not L[i].stmts and (t := _comment_text(L[i].comment)):
            return t
    for i in range(a, end):
        if L[i].comment and (t := _comment_text(L[i].comment)):
            return t
    calls = []
    for i in range(a, end):
        for st in L[i].stmts:
            mn, ops = mnemonic(st)
            if mn == "call" and is_label_token(ops) and ops not in MINOR_CALLS:
                calls.append(ops)
    if calls:
        c = Counter(calls).most_common(1)[0][0]
        c = c.split("_", 1)[1] if "_" in c and c[0].isupper() else c
        return re.sub(r"(?<=[a-z])(?=[A-Z])", "_", c).lower()
    return ""


def decompose(lines: list[str], name: str, max_func: int, used: set[str]) -> tuple[list[str], int]:
    """Decompose routine `name` once; returns (new_lines, helpers_created)."""
    for rn, s, e in routines(lines):
        if rn == name:
            break
    else:
        raise SystemExit(f"routine {name} not found")
    an = Analyzer(lines, s, e)
    L = an.all
    segs = []
    i = s + 1
    while i < e:
        if not L[i].is_stmt or L[i].labels:
            i += 1
            continue
        best = None
        for b in range(min(e, i + MAX_SEG), i + MIN_SEG - 1, -1):
            ok, exits, rw = an.check(i, b)
            if not ok:
                continue
            if b - i + 4 > max_func - 4:
                continue
            step_end = b == e or is_header(L, b) or (L[b].labels and is_header(L, b + 1))
            inner = sum(1 for k in range(i + 3, b) if is_header(L, k))
            score = (b - i) + (25 if step_end else 10 if nice_boundary(L, b) else 0) \
                + (8 if nice_boundary(L, i) else 0) - 18 * inner
            if best is None or score > best[0]:
                best = (score, b, exits, rw)
        if best:
            segs.append((i, best[1], best[2], best[3]))
            i = best[1]
        else:
            i += 1
    import os
    if os.environ.get("SPLIT_ONLY"):  # debugging aid: extract only segment #N (1-based)
        n = int(os.environ["SPLIT_ONLY"])
        segs = segs[n - 1:n]
    if not segs:
        return lines, 0
    out = lines[:s]
    helpers: list[str] = []
    pos = s
    for k, (a, b, exits, rw) in enumerate(segs):
        out.extend(lines[pos:a])
        base = slug(describe(L, a, b)) or f"part{k + 1}"
        hname = f"{name}__{base}"
        n = 2
        while hname in used:
            hname = f"{name}__{base}_{n}"
            n += 1
        used.add(hname)
        indent = re.match(r"\s*", lines[a]).group(0) or "    "
        out.append(f"{indent}call {hname}")
        follow = an.follow_labels(b)
        emap = {t: (f".L{hname}_ret" if t in follow else f".L{hname}_x{j + 1}")
                for j, t in enumerate(sorted(exits))}
        desc = describe(L, a, b)
        helpers.append("")
        helpers.append(f"# {name} step{(': ' + desc) if desc else ''} (runs on the caller's frame)")
        helpers.append(f"{hname}:")
        helpers.append("    lea rsp, [rsp - 8]")
        for li in range(a, b):
            helpers.append(rewrite_line(lines[li], li, rw, emap))
        helpers.append(f".L{hname}_ret:")
        helpers.append("    lea rsp, [rsp + 8]")
        helpers.append("    ret")
        for t, lab in emap.items():
            if lab.endswith("_ret"):
                continue
            helpers.append(f"{lab}:")
            helpers.append("    lea rsp, [rsp + 16]")
            helpers.append(f"    jmp {t}")
        pos = b
    ins = safe_insert_point(lines, e)
    if ins is None:
        return lines, 0
    out.extend(lines[pos:ins])
    out.extend(helpers)
    out.extend(lines[ins:])
    return out, len(segs)


def ends_unconditionally(lines: list[str], s: int, e: int) -> bool:
    for t in reversed(lines[s:e]):
        st = Line(t).stmts
        if st:
            return mnemonic(st[-1])[0] in ("jmp", "ret", "ud2", "OS_EXIT")
    return False


def safe_insert_point(lines: list[str], e: int) -> int:
    """First routine end at/after e that cannot fall through into the next label."""
    if ends_unconditionally(lines, 0, e):
        return e
    for name, s2, e2 in routines(lines):
        if s2 >= e and ends_unconditionally(lines, s2, e2):
            return e2
    return None  # fall-through chain up to the end of .text: leave the routine alone


def top_names(lines: list[str]) -> set[str]:
    return {m.group(1) for t in lines if (m := TOP_LABEL_RE.match(t))}


# Inner-loop hot paths: a step call per iteration would cost measurable time, keep them whole.
HOT_ROUTINES = {
    "mem_alloc", "mem_free", "utf8_decode", "utf8_char_width", "sha256_transform", "crc32_update",
    "fuzzy_score", "cmp_indices", "extract_radix_key", "make_prefix_key", "introsort_loop",
    "insertion_sort_u32", "sift_down_u32", "heapsort_u32", "radix_sort_u32", "prefix_sort_u32",
    "DirModel_step_load", "apply_stat_to_entry", "entry_passes_filter", "DirModel_apply_filter",
    "DirModel_ensure_all_stats", "ScreenBuffer_flush", "ScreenBuffer_draw_text", "out_rgb_sgr",
    "out_u32", "term_put_byte", "inf_decode", "inf_build_tree", "os_batch_stat",
    # Monolithic state machines whose step family would outgrow their module: redesign by hand.
    "input_poll_event", "StatusBar_render",
}


def run(path: Path, names: list[str] | None, max_func: int, dry: bool) -> int:
    global CONSTS
    CONSTS = Consts()
    load_consts(path)
    raw = path.read_text().split("\n")
    todo = names or [n for n, s, e in routines(raw) if e - s > max_func and n not in HOT_ROUTINES]
    lines = preprocess(raw, set(todo))
    used = top_names(lines)
    total = 0
    for name in todo:
        for _ in range(1):  # single level: steps are never regrouped into nested steps
            r = {n: (s, e) for n, s, e in routines(lines)}
            if name not in r or r[name][1] - r[name][0] <= max_func:
                break
            lines, made = decompose(lines, name, max_func, used)
            total += made
            if not made:
                break
        # helpers that are themselves too long (cannot happen with MAX_SEG, kept as a guard)
        for _ in range(0):
            big = [n for n, s, e in routines(lines) if n.startswith(name + "__") and e - s > max_func]
            if not big:
                break
            for h in big:
                lines, made = decompose(lines, h, max_func, used)
                total += made
    left = [(n, e - s) for n, s, e in routines(lines) if e - s > max_func]
    if not dry and total:
        path.write_text("\n".join(lines))
    print(f"{path}: {total} helpers; still long: {left}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--routine", action="append")
    ap.add_argument("--max-func", type=int, default=80)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    for f in a.files:
        run(Path(f), a.routine, a.max_func - 4, a.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
