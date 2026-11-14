#!/usr/bin/env python3
"""Thread-safety reachability for code that runs on clone() worker threads (Disk Usage walkers).

Entry points are detected automatically: every `lea rdi, [rip + F]` followed by
`call os_thread_spawn`. Everything reachable from them (call / tail-jmp graph) must not:

  ERROR  call the heap allocator (mem_alloc / mem_free / mem_realloc: single-threaded)
  ERROR  call into the UI / app / screen / i18n layers (main-thread state)
  WARN   store to a .bss global with a plain `mov` (no lock prefix / xchg): fine only when the
         value is owned by one thread -- listed for review
"""

from __future__ import annotations

import re
import sys

from asm_index import call_graph, rel, routines, sources

UNSAFE_CALLS = {"mem_alloc", "mem_free", "mem_realloc"}
UI_PREFIXES = ("App_", "ScreenBuffer_", "Screen_", "FilePane_", "Dialog_", "i18n_", "theme_",
               "input_", "term_render", "img_preview", "StatusBar_")
STORE_RE = re.compile(r"^(?:mov|add|sub|inc|dec|or|and)\s+(?:(?:byte|word|dword|qword)\s+ptr\s+)?\[rip\s*\+\s*(g_\w+)")


def entries() -> set[str]:
    found = set()
    for p in sources():
        for _, _, body in routines(p):
            for i, (_, ins) in enumerate(body):
                if "call os_thread_spawn" in ins:
                    for _, prev in reversed(body[max(0, i - 8):i]):
                        m = re.search(r"lea\s+rdi\s*,\s*\[rip\s*\+\s*(\w+)\]", prev)
                        if m:
                            found.add(m.group(1))
                            break
    return found


def main() -> int:
    graph, where = call_graph()
    roots = entries()
    seen, stack, parent = set(), list(roots), {r: None for r in roots}
    while stack:
        f = stack.pop()
        if f in seen:
            continue
        seen.add(f)
        for c in graph.get(f, ()):
            if c not in parent:
                parent[c] = f
            stack.append(c)

    def chain(f):
        out = []
        while f:
            out.append(f)
            f = parent.get(f)
        return " <- ".join(out)

    errors, warns = [], []
    for f in sorted(seen):
        if f in UNSAFE_CALLS:
            errors.append(f"thread code reaches {f}: {chain(f)}")
        if f.startswith(UI_PREFIXES):
            errors.append(f"thread code reaches UI/app routine {f}: {chain(f)}")
        if f not in where:
            continue
        p, _ = where[f]
        for name, _, body in routines(p):
            if name != f:
                continue
            for ln, ins in body:
                m = STORE_RE.match(ins)
                if m and not ins.startswith("lock"):
                    warns.append(f"{rel(p)}:{ln}: {f} plain store to {m.group(1)} ('{ins}')")
    for w in warns:
        print("WARN:", w)
    for e in errors:
        print("ERROR:", e)
    print(f"thread entry points: {', '.join(sorted(roots)) or 'none'}; reachable routines: {len(seen)}")
    if errors:
        print(f"THREAD REACH AUDIT FAILED ({len(errors)} errors)")
        return 1
    print(f"THREAD REACH AUDIT PASSED ({len(warns)} plain global stores to review)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
