#!/usr/bin/env python3
"""src/core/memcheck.c (MEMCHECK=1 leak / bad-free tracker) versus the frozen assembly (tests/harness/memcheck_reference.s): random
alloc / free / realloc scripts over a small pointer pool (reuse, double frees, null pointers, hash collisions, tombstones), a full
65536-slot table, log files (new, pre-existing longer file, unwritable path, stderr) and the exact MC_SUMMARY / MC_LEAK / MC_BADFREE lines."""

import random
import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
MEMCHECK_C = "src/core/memcheck.c"
REFERENCE = "tests/harness/memcheck_reference.s"
CLI = ["tests/harness/memcheck_cli.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c", "src/core/syscall.c",
       "src/core/try_rt.c", "src/core/memory.c", "src/core/utf8.c"]
CAP = 65536
MASK = CAP - 1
M64 = (1 << 64) - 1


def build(t: Path, c_src: str = MEMCHECK_C) -> Path:
    return H.build_with_refs("x86_64", t, [*CLI, c_src], [REFERENCE], cflags=["-DMEMCHECK=1"], asflags=["--defsym", "MEMCHECK=1"])


def mc_hash(p: int) -> int:
    return ((((p >> 4) * 0x9E3779B97F4A7C15) & M64) ^ p) & MASK


def run(exe: Path, impl: str, script: str, log: Path | None = None, precreate: bytes | None = None) -> tuple[str, str]:
    env = {}
    if log is not None:
        env["DUOP_MEMCHECK_LOG"] = str(log)
        if precreate is not None:
            log.write_bytes(precreate)
        elif log.exists():
            log.unlink()
    res = H.run_impl("x86_64", exe, impl, stdin=script.encode(), env=env)
    assert res.returncode == 0, (impl, res.stderr[-300:])
    return (log.read_bytes().decode("latin-1") if log is not None and log.exists() else ""), res.stderr.decode("latin-1")


def both(t: Path, exe: Path, script: str, log: bool = True, precreate: bytes | None = None, bad_path: bool = False) -> str:
    outs = []
    for impl in ("ref", "c"):
        path = (t / "no" / "such" / "dir" / "mc.log") if bad_path else (t / f"{impl}.log") if log else None
        outs.append(run(exe, impl, script, path, precreate))
    assert outs[0] == outs[1], "asm and C logs differ:\n--- asm\n" + outs[0][0][:600] + outs[0][1][:300] + "\n--- C\n" + outs[1][0][:600] + outs[1][1][:300]
    return outs[1][0] + outs[1][1]


def random_script(rng: random.Random, ops: int, pool: int) -> str:
    base = rng.randrange(0x1000, 0x7FFF00000000, 16)
    ptrs = [base + 16 * i for i in range(pool)]
    # colliding pointers: the same table slot, different pointers (probe chains and tombstone reuse)
    slot = mc_hash(ptrs[0])
    ptrs += [p for p in (base + 16 * i for i in range(pool, pool + 600000, 7)) if mc_hash(p) == slot][:6]
    lines = ["I"]
    for _ in range(ops):
        k = rng.randrange(10)
        p = rng.choice(ptrs) if rng.random() > 0.04 else 0
        caller = rng.randrange(0x400000, 0x500000)
        if k < 4:
            lines.append(f"A {p:x} {rng.choice([0, 1, 16, 4096, rng.randrange(1 << 40)]):x} {caller:x}")
        elif k < 7:
            lines.append(f"F {p:x} {caller:x}")
        elif k < 9:
            q = rng.choice(ptrs) if rng.random() > 0.1 else 0
            lines.append(f"R {rng.choice([p, q]):x} {q:x} {rng.randrange(1, 1 << 20):x} {caller:x}")
        else:
            lines.append(f"F {rng.randrange(1, 1 << 47):x} {caller:x}")                 # a pointer nobody allocated
    lines.append("P")
    return "\n".join(lines) + "\n"


def test_random(t: Path, exe: Path) -> None:
    rng = random.Random(2026)
    leaks = bads = 0
    for i in range(60):
        out = both(t, exe, random_script(rng, rng.randrange(1, 400), rng.randrange(1, 40)))
        leaks += out.count("MC_LEAK")
        bads += out.count("MC_BADFREE")
        assert out.count("MC_SUMMARY") == 1
    assert leaks > 100 and bads > 100, (leaks, bads)
    print(f"[PASS] MCK1. 60 random scripts: {leaks} leak lines and {bads} bad frees identical to the asm (summary, hex/dec formatting, seq)")


def test_log_targets(t: Path, exe: Path) -> None:
    script = "I\nA 1000 40 400100\nA 2000 10 400200\nF 1000 400300\nF 1000 400400\nP\n"
    both(t, exe, script, log=False)                                    # stderr
    both(t, exe, script, precreate=b"x" * 5000)                         # O_TRUNC: a longer old log is cut
    out = both(t, exe, script, bad_path=True)                           # unwritable path: falls back to stderr
    assert "MC_BADFREE ptr=0x0000000000001000" in out and "live=1" in out and "bad_frees=1" in out, out
    print("[PASS] MCK2. stderr, truncated pre-existing log and unwritable log path behave like the asm")


def test_full_table(t: Path, exe: Path) -> None:
    n = CAP + 500
    lines = ["I"] + [f"A {0x10000 + 16 * i:x} 8 400000" for i in range(n)]
    lines += [f"F {0x10000 + 16 * i:x} 400001" for i in range(0, n, 3)] + [f"F {0x10000 + 16 * i:x} 400002" for i in range(n - 10, n)] + ["P"]
    out = both(t, exe, "\n".join(lines) + "\n")
    assert "MC_BADFREE" in out and out.count("MC_LEAK") > CAP // 2, out[:300]
    print(f"[PASS] MCK3. {n} allocations overflow the {CAP}-slot table exactly like the asm (untracked blocks, bad frees, leak list)")


def probe_edge_script() -> str:
    """CAP-1 blocks leave exactly one free slot f; block Y hashes to f+1, so it needs CAP-1 probes (the last allowed) to be tracked."""
    used: set[int] = set()
    ptrs = [0x10000 + 16 * i for i in range(CAP - 1)]
    for p in ptrs:
        i = mc_hash(p)
        while i in used:
            i = (i + 1) & MASK
        used.add(i)
    free_slot = next(i for i in range(CAP) if i not in used)
    y = next(0x40000000 + 16 * k for k in range(10 ** 7) if mc_hash(0x40000000 + 16 * k) == (free_slot + 1) & MASK)
    lines = ["I"] + [f"A {p:x} 8 400000" for p in ptrs] + [f"A {y:x} 8 400001", f"F {y:x} 400002", f"A {y:x} 8 400003", f"F {ptrs[5]:x} 400004", "P"]
    return "\n".join(lines) + "\n"


def test_probe_edge(t: Path, exe: Path) -> None:
    out = both(t, exe, probe_edge_script())
    assert "MC_BADFREE" not in out and "frees=2" in out, out[:300]
    print("[PASS] MCK3b. a block that needs exactly 65535 probes (one free slot left) is tracked and freed like the asm")


def test_mutations(t: Path) -> None:
    mutants = [("peak tracking inverted", "if (g_mc_live_bytes > g_mc_peak)", "if (g_mc_live_bytes < g_mc_peak)"),
               ("tombstones not reused", "if (e->ptr && e->ptr != MC_TOMB) continue;", "if (e->ptr) continue;"),
               ("hash shift", "(ptr >> 4)", "(ptr >> 5)"),
               ("alloc probe limit", "probes < MC_CAP; probes++, i = (i + 1) & MC_MASK) {\n        McEntry *e = &g_mc_table[i];\n        if (e->ptr && e->ptr",
                "probes < MC_CAP - 1; probes++, i = (i + 1) & MC_MASK) {\n        McEntry *e = &g_mc_table[i];\n        if (e->ptr && e->ptr"),
               ("free probe limit", "probes < MC_CAP; probes++, i = (i + 1) & MC_MASK) {\n        McEntry *e = &g_mc_table[i];\n        if (!e->ptr)",
                "probes < MC_CAP - 1; probes++, i = (i + 1) & MC_MASK) {\n        McEntry *e = &g_mc_table[i];\n        if (!e->ptr)"),
               ("live bytes not released", "g_mc_live_bytes -= e->size;", "(void)e->size;"),
               ("realloc order", "    if (old_ptr) mc_on_free(old_ptr, caller);\n    if (new_ptr) mc_on_alloc(new_ptr, size, caller);",
                "    if (new_ptr) mc_on_alloc(new_ptr, size, caller);\n    if (old_ptr) mc_on_free(old_ptr, caller);"),
               ("seq post-increment", "++g_mc_seq }", "g_mc_seq++ }"),
               ("hex digits", "shift >= 0", "shift > 0"),
               ("env prefix length", "*envp + 18", "*envp + 17"),
               ("log not truncated", "O_WRONLY | O_CREAT | O_TRUNC", "O_WRONLY | O_CREAT"),
               ("bad free silent", "    g_mc_bad++;\n    mc_log_badfree((uintptr_t)ptr, (uintptr_t)caller);", "    g_mc_bad++;\n    (void)&mc_log_badfree;\n    (void)caller;"),
               ("leak caller dropped", 'mc_hex(mc_str(p, " caller="), e->caller)', 'mc_hex(mc_str(p, " caller="), 0)'),
               ("free frees count", "g_mc_frees++;", "")]
    base = random_script(random.Random(7), 300, 12)
    edge = probe_edge_script()
    full = "\n".join(["I"] + [f"A {0x10000 + 16 * i:x} 8 400000" for i in range(CAP + 200)] + [f"F {0x10000 + 16 * (CAP + 10):x} 1", "P"]) + "\n"

    def detected(path: Path, i: int) -> bool:
        (t / f"m{i}").mkdir()
        exe = build(t / f"m{i}", str(path))
        for script, precreate in ((base, None), (full, None), (edge, None), ("I\nA 1000 8 1\nF 1000 2\nP\n", b"y" * 4000)):
            log = t / "mut.log"
            if run(exe, "ref", script, log, precreate) != run(exe, "c", script, log, precreate):
                return True
        return False

    survivors = H.mutcheck(ROOT / MEMCHECK_C, mutants, detected, t)
    assert not survivors, f"mutants survived: {survivors}"
    print(f"[PASS] MCK4. {len(mutants)}/{len(mutants)} mutations of memcheck.c are caught by the asm differential")


def test_empty_without_memcheck(t: Path) -> None:
    obj = t / "plain.o"
    subprocess.run(["gcc", *H.COMMON, "-c", str(ROOT / MEMCHECK_C), "-o", str(obj)], check=True)
    syms = subprocess.run(["nm", str(obj)], capture_output=True, text=True, check=True).stdout.strip()
    assert syms == "", f"a non-MEMCHECK build must not contain tracker symbols: {syms}"
    print("[PASS] MCK5. without MEMCHECK the file compiles to an empty object (zero release overhead)")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_random(t, exe)
        test_log_targets(t, exe)
        test_full_table(t, exe)
        test_probe_edge(t, exe)
        test_empty_without_memcheck(t)
        test_mutations(t)
    print("ALL C MEMCHECK TESTS PASSED.")


if __name__ == "__main__":
    main()
