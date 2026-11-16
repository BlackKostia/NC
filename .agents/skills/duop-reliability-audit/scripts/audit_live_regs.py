#!/usr/bin/env python3
"""Caller-saved registers that are live ACROSS a call that clobbers them (SysV AMD64).

The other audits check callee-saved registers and stack balance.  They cannot see the classic assembler bug
"r10d was set before `call foo`, `foo` (or something it calls) overwrites r10, the caller reads r10d afterwards".
This audit works on the linked, symbolized binary (objdump, macros already expanded):

  * per function: registers written (minus registers it pushes AND pops, i.e. saves/restores) plus the clobbers of every
    direct callee, to a fixed point; an indirect call (vtable) clobbers every caller-saved register;
  * per call site: a register the callee clobbers that the caller defined earlier and reads later on some path,
    before rewriting it, is reported as `caller -> callee reg`.

Registers a routine deliberately returns in (utf8_decode -> rdx, parse_uint -> rdi, ...) or private helper
conventions look the same to a static scan: those are listed with a reason in audit_live_regs_baseline.json.

Usage: audit_live_regs.py ELF [--baseline FILE] [--update] [--list]
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BASELINE = os.path.join(HERE, "audit_live_regs_baseline.json")
UNREVIEWED = "UNREVIEWED"
CALLER = {"rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"}
ARGREG = ["rdi", "rsi", "rdx", "r10", "r8", "r9"]
SYS_ARGC = {0: 3, 1: 3, 2: 3, 3: 1, 4: 2, 5: 2, 8: 3, 9: 6, 10: 3, 11: 2, 12: 1, 13: 4, 14: 4, 16: 3, 17: 4, 20: 3, 21: 2,
            22: 1, 24: 0, 25: 5, 28: 3, 32: 1, 33: 2, 34: 0, 39: 0, 56: 5, 57: 0, 59: 3, 60: 1, 61: 4, 62: 2, 72: 3, 74: 1,
            75: 1, 76: 2, 77: 2, 79: 2, 80: 1, 82: 2, 83: 2, 87: 1, 89: 3, 90: 2, 91: 2, 92: 3, 93: 3, 95: 1, 96: 2, 97: 2,
            102: 0, 104: 0, 110: 0, 131: 2, 157: 5, 158: 2, 165: 5, 186: 0, 202: 6, 217: 3, 218: 1, 228: 2, 230: 4, 231: 1,
            234: 3, 257: 4, 258: 3, 259: 5, 260: 5, 262: 4, 263: 3, 264: 4, 265: 5, 266: 3, 267: 4, 268: 3, 270: 6, 271: 5,
            273: 2, 280: 4, 282: 3, 285: 4, 291: 1, 292: 3, 293: 2, 294: 1, 295: 4, 301: 5, 316: 5, 318: 3, 326: 6, 332: 5,
            425: 2, 426: 6, 427: 4}
JCC = {"je", "jne", "jz", "jnz", "ja", "jae", "jb", "jbe", "jg", "jge", "jl", "jle", "js", "jns", "jo", "jno", "jp", "jnp",
       "jc", "jnc", "jecxz", "jrcxz", "loop", "jna", "jnae", "jnb", "jnbe", "jng", "jnge", "jnl", "jnle", "jpe", "jpo"}
NO_WRITE_DEST = {"cmp", "test", "push", "bt", "ucomiss", "ucomisd", "comiss", "comisd", "prefetcht0", "prefetchnta", "nop",
                 "jmp", "call"}
PREFIXES = {"rep", "repz", "repnz", "repe", "repne", "lock", "bnd", "notrack", "data16", "cs", "ds", "es", "ss"}
PLAIN_DEST = ("mov movzx movsx movsxd lea movabs movbe bsf bsr popcnt lzcnt tzcnt movq movd movdqa movdqu movaps movups "
              "rdtsc andn bzhi pext pdep blsr blsi bextr crc32 cvtsi2sd cvtsi2ss sarx shlx shrx").split()

FAM = {}
for _n in ("ax", "bx", "cx", "dx", "si", "di", "bp", "sp"):
    FAM["r" + _n] = FAM["e" + _n] = FAM[_n] = "r" + _n
for _a, _b in (("al", "ax"), ("bl", "bx"), ("cl", "cx"), ("dl", "dx"), ("ah", "ax"), ("bh", "bx"), ("ch", "cx"),
               ("dh", "dx"), ("sil", "si"), ("dil", "di"), ("bpl", "bp"), ("spl", "sp")):
    FAM[_a] = "r" + _b
for _i in range(8, 16):
    for _s in ("", "d", "w", "b"):
        FAM[f"r{_i}{_s}"] = f"r{_i}"
REG_RE = re.compile(r"\b(" + "|".join(sorted(FAM, key=len, reverse=True)) + r")\b")


def regs_in(text: str) -> set:
    return {FAM[m] for m in REG_RE.findall(text)}


def split_ops(ops: str) -> list:
    out, depth, cur = [], 0, ""
    for ch in ops:
        depth += (ch == "[") - (ch == "]")
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    return out + [cur.strip()] if cur.strip() else out


def string_op_effects(mn: str) -> tuple:
    if "stos" in mn or "scas" in mn:
        return {"rcx", "rdi", "rax"}, {"rcx", "rdi"}
    return {"rcx", "rsi", "rdi", "rax"}, {"rcx", "rsi", "rdi"}


def special_effects(base: str, ops: str):
    """Instructions with implicit operands; None when the generic operand rules apply."""
    if base == "syscall":
        argc = SYS_ARGC.get(int(ops[1:]), 6) if ops.startswith("#") and ops[1:].lstrip("-").isdigit() else 6
        return {"rax"} | set(ARGREG[:max(argc, 0)]), {"rax", "rcx", "r11"}
    simple = {"cqo": ({"rax"}, {"rdx"}), "cdq": ({"rax"}, {"rdx"}), "cwd": ({"rax"}, {"rdx"}), "cdqe": ({"rax"}, {"rax"}),
              "cwde": ({"rax"}, {"rax"}), "cbw": ({"rax"}, {"rax"}), "cpuid": ({"rax", "rcx"}, {"rax", "rbx", "rcx", "rdx"})}
    if base in simple:
        return simple[base]
    string_ops = {"lods": ({"rsi"}, {"rax", "rsi"}), "stos": ({"rdi", "rax"}, {"rdi"}),
                  "movs": ({"rsi", "rdi"}, {"rsi", "rdi"}), "scas": ({"rdi", "rax"}, {"rdi"}),
                  "cmps": ({"rsi", "rdi", "rax"}, {"rsi", "rdi"})}
    if base in string_ops and ("PTR" in ops or ops == ""):
        return string_ops[base]                               # objdump prints string ops as lods/stos/movs/scas/cmps
    if base in ("mul", "div", "idiv") or (base == "imul" and len(split_ops(ops)) == 1):
        return regs_in(ops) | {"rax"} | ({"rdx"} if base in ("div", "idiv") else set()), {"rax", "rdx"}
    if base == "xchg":
        o = split_ops(ops)
        return regs_in(ops), regs_in(o[0]) | (regs_in(o[1]) if len(o) > 1 and "[" not in o[1] else set())
    if base == "push":
        return regs_in(ops), set()
    if base == "pop":
        return set(), regs_in(ops)
    return None


def effects(mn: str, ops: str) -> tuple:
    """(registers read, registers written) as register families; approximate but conservative for our code."""
    base = mn.split()[-1]
    if mn.startswith("rep"):
        return string_op_effects(mn)
    special = special_effects(base, ops)
    if special is not None:
        return special
    rd = {"rcx"} if base in ("shl", "shr", "sar", "sal", "rol", "ror", "shld", "shrd") and ops.endswith("cl") else set()
    o = split_ops(ops)
    if not o:
        return rd, set()
    if base in NO_WRITE_DEST or "[" in o[0]:
        for x in o:
            rd |= regs_in(x)
        return rd, set()
    dregs = regs_in(o[0])
    for x in o[1:]:
        rd |= regs_in(x)
    if base in PLAIN_DEST or base.startswith(("set", "cmov")):
        return rd | (dregs if base.startswith("cmov") else set()), dregs | ({"rax", "rdx"} if base == "rdtsc" else set())
    if base in ("xor", "sub", "sbb") and len(o) == 2 and o[0] == o[1]:
        return set(), dregs
    if base == "imul" and len(o) == 3:
        return rd, dregs
    return rd | dregs, dregs                    # read-modify-write


def branch_target(ops: str):
    m = re.match(r"([0-9a-f]+)\s*<", ops)
    return int(m.group(1), 16) if m else None


class Binary:
    """Disassembly of every function of the ELF: name -> [(addr, mnemonic, operands)]."""

    def __init__(self, elf: str):
        dis = subprocess.run(["objdump", "-d", "-M", "intel", "--no-show-raw-insn", elf], capture_output=True, text=True,
                             check=True).stdout
        self.syms = {}
        for line in subprocess.run(["nm", "-n", elf], capture_output=True, text=True, check=True).stdout.splitlines():
            p = line.split()
            if len(p) == 3 and p[1] in "TtWw":
                self.syms[int(p[0], 16)] = p[2]
        self.funcs = collections.OrderedDict()
        cur = None
        for line in dis.splitlines():
            m = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
            if not m:
                continue
            addr, mn, ops = int(m.group(1), 16), m.group(2), m.group(3).split("#")[0].strip()
            if mn in PREFIXES and ops:
                head, _, ops = ops.partition(" ")
                mn += " " + head
            if addr in self.syms:
                cur = self.syms[addr]
                self.funcs[cur] = []
            if cur is not None:
                self.funcs[cur].append((addr, mn, ops.strip()))
        for name in self.funcs:
            self.funcs[name] = self._tag_syscalls(self.funcs[name])
        self.clobbers = self._clobber_sets()

    @staticmethod
    def _tag_syscalls(body):
        last, out = None, []
        for addr, mn, ops in body:
            if mn == "mov" and ops.startswith(("eax", "rax")):
                m = re.match(r"(?:eax|rax),\s*(0x[0-9a-f]+|\d+)$", ops)
                last = int(m.group(1), 0) if m else None
            if mn == "syscall":
                ops = "#%d" % (last if last is not None else -1)
            out.append((addr, mn, ops))
        return out

    def callee(self, mn: str, ops: str):
        return self.syms.get(branch_target(ops)) if mn == "call" else None

    def _clobber_sets(self) -> dict:
        direct, calls, indirect, saved = {}, collections.defaultdict(set), set(), {}
        for fn, body in self.funcs.items():
            written, pushed, popped = set(), set(), set()
            for _, mn, ops in body:
                written |= effects(mn, ops)[1] & CALLER
                pushed |= regs_in(ops) if mn == "push" else set()
                popped |= regs_in(ops) if mn == "pop" else set()
                if mn in ("call", "jmp"):
                    addr = branch_target(ops)
                    if addr is None:
                        indirect.add(fn)                  # register / memory operand: any callee
                    elif addr in self.syms and self.syms[addr] != fn:
                        calls[fn].add(self.syms[addr])
            saved[fn] = pushed & popped
            direct[fn] = written - saved[fn]
        clob = {fn: set(w) for fn, w in direct.items()}
        changed = True
        while changed:
            changed = False
            for fn in self.funcs:
                new = (clob[fn] | set().union(*(clob.get(c, CALLER) for c in calls[fn])) | (CALLER if fn in indirect else set()))
                new -= saved[fn]
                if new != clob[fn]:
                    clob[fn], changed = new, True
        return clob

    def clobber_of(self, mn: str, ops: str) -> set:
        tgt = self.callee(mn, ops)
        return self.clobbers.get(tgt, CALLER) if tgt else CALLER


def build_cfg(body):
    index = {a: i for i, (a, _, _) in enumerate(body)}
    succ = []
    for i, (_, mn, ops) in enumerate(body):
        nxt = [i + 1] if i + 1 < len(body) else []
        tgt = index.get(branch_target(ops)) if mn == "jmp" or mn in JCC else None
        if mn == "jmp":
            succ.append([tgt] if tgt is not None else [])
        elif mn in JCC:
            succ.append(nxt + ([tgt] if tgt is not None else []))
        else:
            succ.append([] if mn in ("ret", "ud2", "hlt") else nxt)
    return succ


def first_read(binary: Binary, body, eff, succ, start: int, reg: str, limit: int = 400):
    """Nearest path distance at which `reg` is read before being rewritten (or a call clobbers it), else None."""
    seen, stack, best = set(), [(start, 0)], None
    while stack:
        i, dist = stack.pop()
        if i in seen or dist > limit:
            continue
        seen.add(i)
        rd, wr = eff[i]
        if reg in rd:
            best = (i, dist) if best is None or dist < best[1] else best
        elif reg not in wr and not (body[i][1] == "call" and reg in binary.clobber_of(body[i][1], body[i][2])):
            stack.extend((s, dist + 1) for s in succ[i])
    return best


def def_distance(binary: Binary, body, eff, succ, call_i: int, reg: str):
    """Distance back to the nearest write of `reg` on a path reaching the call, or None (live-in argument)."""
    pred = [[] for _ in body]
    for i, targets in enumerate(succ):
        for t in targets:
            pred[t].append(i)
    seen, stack, found = set(), [(p, 1) for p in pred[call_i]], None
    while stack:
        i, dist = stack.pop()
        if i in seen:
            continue
        seen.add(i)
        if reg in eff[i][1]:
            found = dist if found is None or dist < found else found
        elif not (body[i][1] == "call" and reg in binary.clobber_of(body[i][1], body[i][2])):
            stack.extend((p, dist + 1) for p in pred[i])
    return found


def live_in(binary: Binary, name: str) -> set:
    body = binary.funcs[name]
    eff = [effects(mn, ops) for _, mn, ops in body]
    succ = build_cfg(body)
    return {r for r in CALLER if first_read(binary, body, eff, succ, 0, r) is not None}


def scan(binary: Binary) -> list:
    """-> [(function, callee, register, def_distance, read_distance, reading instruction, call address)]"""
    findings, live_cache = [], {}
    for fn, body in binary.funcs.items():
        eff = [effects(mn, ops) for _, mn, ops in body]
        succ = build_cfg(body)
        for ci, (addr, mn, ops) in enumerate(body):
            if mn != "call" or ci + 1 >= len(body):
                continue
            callee = binary.callee(mn, ops)
            if callee in binary.funcs and callee not in live_cache:
                live_cache[callee] = live_in(binary, callee)
            for reg in sorted(binary.clobber_of(mn, ops) & CALLER):
                hit = first_read(binary, body, eff, succ, ci + 1, reg)
                dbef = def_distance(binary, body, eff, succ, ci, reg) if hit else None
                if hit is None or dbef is None:
                    continue                                  # never read afterwards / live-in argument
                dist = hit[1]
                if (dist <= 1 and dbef <= 6) or (reg in live_cache.get(callee, set()) and dbef <= 6 and dist <= 3):
                    continue                                  # argument set-up / immediate use of an output
                findings.append((fn, callee or "?", reg, dbef, dist, f"{body[hit[0]][1]} {body[hit[0]][2]}", hex(addr)))
    return findings


def key_of(finding) -> str:
    return f"{finding[0]} -> {finding[1]} {finding[2]}"


def load_baseline(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh).get("accepted", {})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("elf")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--update", action="store_true", help="add new findings (as UNREVIEWED) and drop stale entries")
    ap.add_argument("--list", action="store_true", help="print every finding, accepted or not")
    args = ap.parse_args()
    findings = scan(Binary(args.elf))
    keys = {key_of(f) for f in findings}
    accepted = load_baseline(args.baseline)
    new = sorted(keys - set(accepted))
    stale = sorted(set(accepted) - keys)
    unreviewed = sorted(k for k, why in accepted.items() if why.strip() in ("", UNREVIEWED) and k in keys)
    if args.list:
        for f in sorted(findings):
            print(f"  {key_of(f)}  (call@{f[6]}: def {f[3]} insn before, read {f[4]} after: {f[5]})")
    if args.update:
        merged = {k: accepted.get(k, UNREVIEWED) for k in sorted(keys)}
        with open(args.baseline, "w", encoding="utf-8") as fh:
            json.dump({"accepted": merged}, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print(f"live-regs baseline rewritten: {len(merged)} entries ({len(new)} new, {len(stale)} dropped)")
        return 0
    for k in new:
        detail = next(f for f in findings if key_of(f) == k)
        print(f"LIVEREG: {k}: defined {detail[3]} insn before call@{detail[6]}, read {detail[4]} insn after ({detail[5]})")
    for k in stale:
        print(f"STALE baseline entry (fixed or renamed - run --update): {k}")
    for k in unreviewed:
        print(f"UNREVIEWED baseline entry (write the reason it is safe): {k}")
    if new or stale or unreviewed:
        return 1
    print(f"audit_live_regs: OK ({len(accepted)} documented register-return conventions, no live caller-saved clobbers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
