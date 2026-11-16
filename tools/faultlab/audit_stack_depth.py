#!/usr/bin/env python3
"""Worst-case stack depth and recursion analysis on the linked ELF (needs symbols: `make`).

    audit_stack_depth.py [./duop] [--limit BYTES] [--thread ENTRY:STACK_BYTES]...

Disassembles the binary, propagates the stack depth through each routine's control-flow graph
(push/pop/sub/add/lea rsp), builds the call graph (direct calls + tail jumps; indirect calls
may reach any routine whose address is taken) and reports

  * every recursion cycle with its stack cost per level (unbounded depth = stack overflow;
    without sigaltstack the fault handler cannot run, so the terminal stays in raw mode),
  * the deepest non-recursive call chain from the entry point and from each thread entry,
    compared with --limit / the thread's stack size (a signal frame is added on top).
Exit status 1 when a thread budget is exceeded or --limit is crossed."""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict

SIGFRAME = 4096 + 2700          # kernel rt_sigframe + AVX-512 xsave area on the interrupted stack
INS_RE = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
FUNC_RE = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")
TGT_RE = re.compile(r"^([0-9a-f]+) <([^>+]+)(?:\+0x[0-9a-f]+)?>")
JCC = {"jo", "jno", "js", "jns", "je", "jz", "jne", "jnz", "jb", "jnae", "jc", "jnb", "jae", "jnc", "jbe", "jna",
       "ja", "jnbe", "jl", "jnge", "jge", "jnl", "jle", "jng", "jg", "jnle", "jp", "jpe", "jnp", "jpo",
       "jrcxz", "jecxz", "loop", "loope", "loopne"}


def num(text):
    text = text.strip()
    return int(text, 16) if text.startswith(("0x", "-0x")) else int(text)


def disassemble(binary):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-M", "intel", binary],
                         capture_output=True, text=True, check=True).stdout
    funcs, cur = {}, None
    for line in out.splitlines():
        m = FUNC_RE.match(line)
        if m:
            cur = m.group(2)
            funcs[cur] = {"addr": int(m.group(1), 16), "ins": []}
            continue
        m = INS_RE.match(line)
        if m and cur:
            funcs[cur]["ins"].append((int(m.group(1), 16), m.group(2), m.group(3).strip()))
    return funcs


def delta(mn, ops):
    """Stack growth in bytes caused by one instruction (None = rsp set to an unknown value)."""
    if mn == "push":
        return 8
    if mn == "pop":
        return -8
    if mn in ("sub", "add") and ops.startswith("rsp,"):
        try:
            v = num(ops.split(",", 1)[1])
        except ValueError:
            return None
        return v if mn == "sub" else -v
    if mn == "lea" and ops.startswith("rsp,"):
        m = re.match(r"rsp,\[rsp([+-])(0x[0-9a-f]+|\d+)\]", ops.replace(" ", ""))
        if m:
            v = num(m.group(2))
            return v if m.group(1) == "-" else -v
        return None
    if mn in ("and", "mov") and ops.startswith("rsp,"):
        return 0 if mn == "and" else None
    return 0


def analyze(name, fn, by_addr, taken):
    """-> (own max depth, [(callee | '*indirect*', depth at the call incl. return address)])."""
    ins = fn["ins"]
    index = {a: i for i, (a, _, _) in enumerate(ins)}
    depth_at, work, calls, peak = {}, [(0, 0)], [], 0
    while work:
        i, d = work.pop()
        while 0 <= i < len(ins):
            if i in depth_at and depth_at[i] >= d:
                break
            depth_at[i] = d
            addr, mn, ops = ins[i]
            peak = max(peak, d)
            tgt = TGT_RE.match(ops)
            if mn == "call":
                calls.append((tgt.group(2) if tgt else "*indirect*", d + 8))
            elif mn == "jmp":
                if tgt and int(tgt.group(1), 16) in index:
                    i = index[int(tgt.group(1), 16)]
                    continue
                calls.append((tgt.group(2) if tgt else "*indirect*", d))       # tail call
                break
            elif mn in JCC:
                if tgt and int(tgt.group(1), 16) in index:
                    work.append((index[int(tgt.group(1), 16)], d))
                elif tgt:
                    calls.append((tgt.group(2), d))
            elif mn in ("ret", "syscall") and mn == "ret":
                break
            dd = delta(mn, ops)
            d = max(0, d + dd) if dd is not None else d
            i += 1
    return peak, calls


def address_taken(binary, funcs):
    """Routines whose address is stored in .rodata (vtables, handler tables) or taken with lea."""
    starts = {f["addr"]: n for n, f in funcs.items()}
    taken = set()
    dump = subprocess.run(["objdump", "-s", "-j", ".rodata", binary], capture_output=True, text=True).stdout
    blob = bytearray()
    for line in dump.splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r"[0-9a-f]+", parts[0]):
            for word in parts[1:5]:
                if re.fullmatch(r"[0-9a-f]{2,8}", word):
                    blob += bytes.fromhex(word)
    for off in range(0, len(blob) - 7, 8):
        v = int.from_bytes(blob[off:off + 8], "little")
        if v in starts:
            taken.add(starts[v])
    for f in funcs.values():
        for _, mn, ops in f["ins"]:
            if mn == "lea":
                m = re.search(r"# ([0-9a-f]+) <([^>+]+)>", ops)
                if m and int(m.group(1), 16) in starts:
                    taken.add(m.group(2))
    return taken


def sccs(graph):
    index, low, stack, on, out, counter = {}, {}, [], set(), [], [0]
    sys.setrecursionlimit(100000)

    def visit(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in graph.get(v, ()):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1 or v in graph.get(v, ()):
                out.append(comp)

    for v in list(graph):
        if v not in index:
            visit(v)
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    binary = args[0] if args else "./duop"
    limit = next((int(sys.argv[i + 1]) for i, a in enumerate(sys.argv) if a == "--limit"), 0)
    threads = [sys.argv[i + 1].split(":") for i, a in enumerate(sys.argv) if a == "--thread"]
    funcs = disassemble(binary)
    if len(funcs) < 50:
        print("STACK DEPTH AUDIT: binary has no symbols (build with `make`, not `make release`)")
        return 2
    by_addr = {f["addr"]: n for n, f in funcs.items()}
    taken = address_taken(binary, funcs)
    info = {n: analyze(n, f, by_addr, taken) for n, f in funcs.items()}
    direct = {n: {c for c, _ in calls if c in funcs} for n, (_, calls) in info.items()}
    cycles = sccs(direct)
    in_cycle = {n for c in cycles for n in c}

    print(f"== {len(cycles)} recursion cycles (direct calls) ==")
    for comp in sorted(cycles, key=len):
        cost = sum(max((d for c, d in info[n][1] if c in comp), default=0) for n in comp)
        print(f"  {cost:6d} B/level  " + " -> ".join(sorted(comp)))

    memo = {}

    def worst(n, trail=()):
        """Deepest chain below n, each recursion cycle entered once; -> (bytes, chain)."""
        if n in memo:
            return memo[n]
        if n in trail:
            return (info[n][0], (n + " (recursion)",))
        best = (info[n][0], (n,))
        for callee, d in info[n][1]:
            targets = taken if callee == "*indirect*" else ([callee] if callee in funcs else [])
            for t in targets:
                sub, chain = worst(t, trail + (n,))
                if d + sub > best[0]:
                    best = (d + sub, (n,) + chain)
        if not (set(best[1]) & set(trail)) and not any("(recursion)" in c for c in best[1]):
            memo[n] = best
        return best

    rc = 0
    big = sorted(((p, n) for n, (p, _) in info.items()), reverse=True)[:8]
    print("== largest frames ==")
    for p, n in big:
        print(f"  {p:6d} B  {n}" + ("   [in a recursion cycle]" if n in in_cycle else ""))
    entries = [("_start", 0)] + [(e, int(s)) for e, s in threads]
    print("== deepest call chains (each recursion cycle counted once) ==")
    for entry, budget in entries:
        if entry not in funcs:
            print(f"  {entry}: no such routine")
            continue
        total, chain = worst(entry)
        line = f"  {entry}: {total} B (+{SIGFRAME} B signal frame)"
        if budget:
            ok = total + SIGFRAME <= budget
            line += f" of {budget} B -> {'ok' if ok else 'EXCEEDED'}"
            rc |= 0 if ok else 1
        if limit and not budget and total > limit:
            line += f" -> over --limit {limit}"
            rc |= 1
        print(line)
        print("      " + " > ".join(chain[:14]) + (" ..." if len(chain) > 14 else ""))
    print(f"STACK DEPTH AUDIT: {len(funcs)} routines, {len(taken)} address-taken, {len(cycles)} recursion cycles")
    return rc


if __name__ == "__main__":
    sys.exit(main())
