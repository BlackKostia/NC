#!/usr/bin/env python3
"""Allocation results used without a NULL check (out-of-memory -> SIGSEGV instead of an error).

Every call to an allocating routine (mem_alloc / mem_realloc / Object_alloc / NEW_OBJ, every
`*_new` constructor, and -- by fixpoint -- any routine that returns such a result unchecked)
is followed forward through the routine. The first thing that happens to the pointer decides:

  DEREF   dereferenced (or VCALL'ed) before any test        -> crash at this instruction on OOM
  STORED  written into an object field / global untested    -> latent crash at a later use
  PASSED  handed to another routine untested
  (ok)    tested with test/cmp/or + conditional jump, or returned to a caller that is audited

    audit_null_alloc.py [--all]     (--all also lists PASSED)
Exit status 1 when DEREF/STORED sites exist."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".agents/skills/duop-reliability-audit/scripts"))
from asm_index import rel, routines, sources  # noqa: E402

ROOTS = {"mem_alloc", "mem_realloc", "Object_alloc", "mem_alloc_raw", "mem_realloc_raw"}
NULL_SAFE = {"mem_free", "Object_free", "mem_free_raw", "mem_realloc", "mem_realloc_raw"}
R64 = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
ALIAS = {}
for r in R64:
    ALIAS[r] = r
for a, b in (("eax", "rax"), ("ebx", "rbx"), ("ecx", "rcx"), ("edx", "rdx"), ("esi", "rsi"), ("edi", "rdi"),
             ("ebp", "rbp"), ("ax", "rax"), ("al", "rax"), ("cl", "rcx"), ("dl", "rdx")):
    ALIAS[a] = b
for i in range(8, 16):
    for suf in ("d", "w", "b"):
        ALIAS[f"r{i}{suf}"] = f"r{i}"
CALLER_SAVED = {"rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"}
ARGS = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
MEM_RE = re.compile(r"\[([^\]]*)\]")
TOK_RE = re.compile(r"[A-Za-z_][\w.]*")
JCC_RE = re.compile(r"^j(?!mp\b)[a-z]+\s")


def split_ops(ins: str):
    parts = ins.split(None, 1)
    mn = parts[0]
    ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
    return mn, ops


def reg_of(op: str):
    return ALIAS.get(re.sub(r"^(?:qword|dword|word|byte)\s+ptr\s+", "", op).strip())


def mem_regs(op: str):
    out = set()
    for m in MEM_RE.finditer(op):
        out |= {ALIAS[t] for t in TOK_RE.findall(m.group(1)) if t in ALIAS}
    return out


def alloc_callee(ins: str, allocs: set[str]):
    mn, ops = split_ops(ins)
    if mn == "NEW_OBJ":
        return "Object_alloc"
    if mn == "call" and ops and ops[0] in allocs:
        return ops[0]
    return None


def follow(body, i, allocs):
    """Fate of the pointer returned by the allocation at body[i]: (kind, line, text)."""
    kind, ln, text, stored = _follow(body, i)
    if stored and kind in ("lost", "PASSED"):
        return ("STORED",) + stored
    return (kind, ln, text)


def _follow(body, i):
    holders, stored = {"rax"}, None
    for j in range(i + 1, min(i + 60, len(body))):
        ln, ins = body[j]
        if ins.endswith(":"):
            continue
        mn, ops = split_ops(ins)
        if mn in ("test", "or") and len(ops) == 2 and reg_of(ops[0]) in holders and reg_of(ops[0]) == reg_of(ops[1]):
            return ("ok", ln, ins, stored)
        if mn == "cmp" and len(ops) == 2 and reg_of(ops[0]) in holders:
            return ("ok", ln, ins, stored)
        if mn == "ret":
            return ("returned" if "rax" in holders else "lost", ln, ins, stored)
        if mn in ("VCALL", "VCALL_REG"):
            target = reg_of(ops[0]) if mn == "VCALL_REG" else "rdi"
            if target in holders:
                return ("DEREF", ln, ins, stored)
            holders -= CALLER_SAVED
        elif mn in ("call", "jmp") and ops and not ops[0].startswith(".L"):
            callee = ops[0]
            if MEM_RE.search(callee) and mem_regs(callee) & holders:
                return ("DEREF", ln, ins, stored)
            passed = [a for a in ARGS if a in holders]
            if passed and callee not in NULL_SAFE:
                return ("PASSED", ln, f"{ins}  ({passed[0]})", stored)
            if mn == "jmp":
                return ("lost", ln, ins, stored)
            holders -= CALLER_SAVED
        elif mn == "jmp":
            return ("lost", ln, ins, stored)
        elif mn == "syscall" or mn.startswith("OS_"):
            holders -= {"rax", "rcx", "r11"}
        elif mn == "lea" and len(ops) == 2:
            dst = reg_of(ops[0])
            if dst and dst not in mem_regs(ops[1]):
                holders.discard(dst)
        elif mn == "mov" and len(ops) == 2:
            dst, src = reg_of(ops[0]), reg_of(ops[1])
            if "[" in ops[1] and mem_regs(ops[1]) & holders:
                return ("DEREF", ln, ins, stored)
            if "[" in ops[0]:
                if mem_regs(ops[0]) & holders:
                    return ("DEREF", ln, ins, stored)
                if src in holders and not re.search(r"\[\s*rsp\b", ops[0]) and not stored:
                    stored = (ln, ins)
            elif dst:
                if src in holders:
                    holders.add(dst)
                else:
                    holders.discard(dst)
        elif not JCC_RE.match(ins):
            if any(mem_regs(o) & holders for o in ops):
                return ("DEREF", ln, ins, stored)
            if mn in ("xor", "pop", "movzx", "movsxd", "movsx", "imul", "shl", "shr", "and") and ops and reg_of(ops[0]) in holders:
                holders.discard(reg_of(ops[0]))
        if not holders:
            return ("lost", ln, ins, stored)
    return ("lost", body[min(i + 59, len(body) - 1)][0], "", stored)


def main() -> int:
    show_all = "--all" in sys.argv
    files = {p: routines(p) for p in sources(ROOT)}
    allocs = set(ROOTS)
    for rs in files.values():
        allocs |= {name for name, _, _ in rs if name.endswith("_new")}
    while True:                                    # routines that return an allocation unchecked
        grew = False
        for rs in files.values():
            for name, _, body in rs:
                if name in allocs:
                    continue
                for i, (_, ins) in enumerate(body):
                    if alloc_callee(ins, allocs) and follow(body, i, allocs)[0] == "returned":
                        allocs.add(name)
                        grew = True
                        break
        if not grew:
            break
    found = {"DEREF": [], "STORED": [], "PASSED": []}
    sites = 0
    for p, rs in files.items():
        for name, _, body in rs:
            for i, (ln, ins) in enumerate(body):
                callee = alloc_callee(ins, allocs)
                if not callee:
                    continue
                sites += 1
                kind, at, text = follow(body, i, allocs)
                if kind in found:
                    found[kind].append(f"{rel(p)}:{ln}: {name}: {callee}() result {kind} at line {at}: {text}")
    for kind in ("DEREF", "STORED") + (("PASSED",) if show_all else ()):
        for f in found[kind]:
            print(f"{kind}: {f}")
    print(f"NULL-ALLOC AUDIT: {sites} allocation sites, {len(found['DEREF'])} dereferenced unchecked, "
          f"{len(found['STORED'])} stored unchecked, {len(found['PASSED'])} passed unchecked "
          f"({len(allocs)} allocating routines)")
    return 1 if found["DEREF"] or found["STORED"] else 0


if __name__ == "__main__":
    sys.exit(main())
