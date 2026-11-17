#!/usr/bin/env python3
"""src/fs/dir_cache.c versus the frozen assembly (tests/harness/dir_cache_reference.s + dir_cache_fetch_reference.s): the LRU
directory cache (dircache_store / dircache_fetch / dircache_invalidate).

DC1 differential, x86_64: random scripts over 24 paths (more than DC_SLOTS = 16) with footprints from 0 to above DC_BUDGET; every
    result, g_dc_bytes, the exact set of arrays freed (ownership: each array carries a unique id) and every DirModel field after
    each call must be identical; the generator must reach every branch (refused, stored, LRU slot eviction, budget eviction,
    same-path replacement, hit 1, hit 2, stale, miss, invalidate)
DC2 boundaries: footprint == DC_BUDGET is taken, +1 is refused, a sum of exactly DC_BUDGET fits, OOM of the slot table refuses
    without losing the arrays
DC3 qemu-aarch64: the C module gives the x86_64 results on the same scripts
DC4 mutation check: one-line mutants of the C module must all be noticed
"""

import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/dir_cache.c"
REFS = ["tests/harness/dir_cache_reference.s", "tests/harness/dir_cache_fetch_reference.s"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
DC_SLOTS, DC_BUDGET, ENTRY = 16, 33554432, 36            # FileEntry (32) + order index (4) bytes per raw_cap entry


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            extra.append(o)
        H.rename_defined_globals(extra, "ref_")
        for o in extra:
            subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=dc_alloc", "--redefine-sym", "mem_free=dc_free", str(o)], check=True)
    return H.build(arch, t, ["tests/harness/dir_cache_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DDC_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode())
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def model(k: int, path: str, *, filt: str = "-", arrays: int = 1, loading: int = 0, aborted: int = 0, dev: int = 1, ino: int = 7,
          mtime: int = 100, ns: int = 5, raw_cap: int = 10, name_cap: int = 100, view: tuple[int, int, int] = (0, 0, 0),
          rest: tuple[int, ...] = (3, 2, 50, 3, 1, 2, 1, 0, 0)) -> str:
    raw_count, name_used, count, dir_count, file_count, dotdot, unsorted, huge, _ = (*rest[:8], 0)
    return (f"M {k} {path} {filt} {arrays} {loading} {aborted} {dev} {ino} {mtime} {ns} {raw_count} {raw_cap} {name_used} {name_cap} "
            f"{count} {dir_count} {file_count} {dotdot} {view[0]} {view[1]} {view[2]} {unsorted} {huge}\n")


def random_script(rng: random.Random, n: int) -> str:
    paths = [f"/d{i}" for i in range(24)]
    stamp = {p: (rng.randrange(1, 4), rng.randrange(1, 1 << 40), rng.randrange(-5, 1 << 33), rng.randrange(0, 10 ** 9)) for p in paths}
    out = []
    for _ in range(n):
        k, p = rng.randrange(4), rng.choice(paths)
        op = rng.random()
        if op < 0.45:
            dev, ino, mt, ns = stamp[p]
            big = rng.random()
            raw_cap = rng.randrange(0, 2000) if big < 0.7 else rng.randrange(DC_BUDGET // ENTRY // 8, DC_BUDGET // ENTRY + 2)
            name_cap = rng.randrange(0, 1 << 16) if big < 0.9 else DC_BUDGET - raw_cap * ENTRY + rng.randrange(-2, 3)
            odd = rng.random()
            out.append(model(k, p, filt=rng.choice(["-", "-", "-", "*.c", "x"]), arrays=int(odd > 0.04), loading=int(0.04 < odd < 0.07),
                             aborted=int(0.07 < odd < 0.10), dev=dev, ino=0 if 0.10 < odd < 0.13 else ino, mtime=mt, ns=ns,
                             raw_cap=raw_cap, name_cap=max(name_cap, 0), view=(rng.randrange(3), rng.randrange(2), rng.randrange(2)),
                             rest=tuple(rng.randrange(0, 1000) for _ in range(9))))
            out.append(f"S {k}\n")
        elif op < 0.85:
            dev, ino, mt, ns = stamp[p]
            which = rng.randrange(8)
            dev, ino, mt, ns = (dev + (which == 4), ino + (which == 5), mt + (which == 6), ns + (which == 7))
            out.append(f"M {k} {p} - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n")
            if rng.random() < 0.5:
                out.append(f"V {k} {rng.randrange(3)} {rng.randrange(2)} {rng.randrange(2)}\n")
            out.append(f"F {k} {dev} {ino} {mt} {ns}\n")
        elif op < 0.95:
            out.append(f"I {p}\n")
        else:
            out.append(f"O {rng.randrange(1, 3)}\n")
    return "".join(out)


def boundary_script() -> str:
    s = "O 1\n" + model(0, "/oom", raw_cap=1) + "S 0\n"                              # slot table OOM: refused, arrays kept
    s += model(0, "/full", raw_cap=0, name_cap=DC_BUDGET) + "S 0\n"                  # exactly the budget: taken
    s += model(1, "/over", raw_cap=0, name_cap=DC_BUDGET + 1) + "S 1\n"              # one byte over: refused
    s += model(1, "/over2", raw_cap=DC_BUDGET // ENTRY + 1, name_cap=0) + "S 1\n"
    s += model(2, "/half", raw_cap=0, name_cap=DC_BUDGET // 2) + "S 2\n"              # evicts /full
    s += model(3, "/half2", raw_cap=0, name_cap=DC_BUDGET // 2) + "S 3\n"             # sum == budget: both stay
    s += "M 0 /half - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nF 0 1 7 100 5\n"      # hit, same view -> 1
    s += "M 1 /half2 - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nV 1 1 0 0\nF 1 1 7 100 5\n"   # sort mode differs -> 2
    s += model(0, "/f", filt="abc") + "S 0\nM 0 /f - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nF 0 1 7 100 5\n"   # snapshot filter -> 2
    s += model(0, "/s") + "S 0\nM 0 /s - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nF 0 1 7 100 6\nF 0 1 7 100 5\n"  # stale ns, then miss
    s += "".join(model(i % 4, f"/lru{i}") + f"S {i % 4}\n" for i in range(DC_SLOTS + 3))  # 19 snapshots in 16 slots
    s += "".join(f"M 0 /lru{i} - 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nF 0 1 7 100 5\n" for i in range(DC_SLOTS + 3))
    return s


def coverage(out: str) -> dict[str, int]:
    lines = out.splitlines()
    return {"refused": sum(ln.startswith("S r=0") for ln in lines), "stored": sum(ln.startswith("S r=1") for ln in lines),
            "evict_free": sum(ln.startswith("S r=1") and "freed=[ ]" not in ln for ln in lines),
            "hit1": sum(ln.startswith("F r=1") for ln in lines), "hit2": sum(ln.startswith("F r=2") for ln in lines),
            "miss_or_stale": sum(ln.startswith("F r=0") for ln in lines),
            "stale_freed": sum(ln.startswith("F r=0") and "freed=[ ]" not in ln for ln in lines),
            "invalidated": sum(ln.startswith("I ") and "freed=[ ]" not in ln for ln in lines)}


def scripts() -> list[str]:
    rng = random.Random(0xDC)
    return [boundary_script(), *(random_script(rng, 400) for _ in range(12))]


def test_differential(exe: Path) -> list[str]:
    outs, total = [], {}
    for i, s in enumerate(scripts()):
        a, b = run(exe, "ref", s), run(exe, "c", s)
        if a != b:
            pair = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
            raise AssertionError(f"script {i}: oracle and C differ:\n  ref {pair[0]}\n  c   {pair[1]}")
        outs.append(b)
        for key, v in coverage(b).items():
            total[key] = total.get(key, 0) + v
    assert all(v > 0 for v in total.values()), f"generator misses a branch: {total}"
    print(f"[PASS] DC1. dircache_* identical to the asm in {sum(o.count(chr(10)) for o in outs)} calls ({total})")
    return outs


def test_boundaries(out: str) -> None:
    s = [ln for ln in out.splitlines() if ln.startswith(("S", "F"))]
    assert s[0].startswith("S r=0 bytes=0 freed=[ ] m= ") and " 0 0 0" not in s[0][:40], ("OOM keeps the arrays", s[0])
    assert s[1].startswith(f"S r=1 bytes={DC_BUDGET} "), s[1]
    assert s[2].startswith(f"S r=0 bytes={DC_BUDGET} ") and s[3].startswith(f"S r=0 bytes={DC_BUDGET} "), (s[2], s[3])
    assert s[4].startswith(f"S r=1 bytes={DC_BUDGET // 2} freed=[ 4 5 6 ]"), ("/full evicted for the budget", s[4])
    assert s[5].startswith(f"S r=1 bytes={DC_BUDGET} freed=[ ]"), ("a sum of exactly the budget fits", s[5])
    assert s[6].startswith("F r=1 ") and s[7].startswith("F r=2 ") and s[8].startswith("S r=1") and s[9].startswith("F r=2 "), s[6:10]
    assert s[11].startswith("F r=0") and "freed=[ ]" not in s[11] and s[12].startswith("F r=0 bytes") and "freed=[ ]" in s[12], s[11:13]
    print("[PASS] DC2. budget boundary (== taken, +1 refused, sum == budget fits), LRU/budget eviction, hit 1/2, stale, OOM")


MUTANTS = [
    ("budget >= ", "if (bytes > DC_BUDGET) return 0;", "if (bytes >= DC_BUDGET) return 0;"),
    ("sum strict", "g_dc_bytes + bytes > DC_BUDGET", "g_dc_bytes + bytes >= DC_BUDGET"),
    ("footprint without order[]", "(sizeof(FileEntry) + 4)", "sizeof(FileEntry)"),
    ("free slot not preferred", "if (want_free) return s;", ""),
    ("same path not replaced", "if (old) dc_free_slot(old);", "(void)old;"),
    ("snapshot filter ignored", "!s->filter[0] && ", ""),
    ("sort_desc ignored", " && s->sort_desc == m->sort_desc", ""),
    ("ns ignored", " || st->mtime_nsec != s->mtime_ns", ""),
    ("stale kept", "        dc_free_slot(s);\n        return 0;", "        return 0;"),
    ("budget not released on fetch", "    g_dc_bytes -= s->bytes;\n    s->used = 0;", "    s->used = 0;"),
    ("capacity not cleared", "m->raw_cap = m->name_cap = m->raw_count", "m->name_cap = m->raw_count"),
    ("is_unsorted not restored", "    m->is_unsorted = s->is_unsorted;\n", ""),
    ("LRU clock frozen", "s->lru = ++g_dc_clock;", "s->lru = g_dc_clock;"),
    ("loading accepted", "m->is_loading || ", ""),
    ("unknown inode accepted", "!m->dir_ino || ", ""),
]


def test_mutants(t: Path, expect: list[str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    ss = scripts()
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "dir_cache.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "dir_cache.c"))
                noticed[name] = any(run(exe, "c", s) != e for s, e in zip(ss, expect))
            except (subprocess.CalledProcessError, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DC4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        outs = test_differential(exe)
        test_boundaries(outs[0])
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            assert [run(a64, "c", s, "aarch64") for s in scripts()] == outs, "qemu-aarch64 differs from x86_64"
            print(f"[PASS] DC3. qemu-aarch64: the C module gives the x86_64 results on {len(outs)} scripts")
        else:
            print("[SKIP] DC3: aarch64 toolchain/qemu not installed")
        test_mutants(t, outs)
    print("ALL C DIR CACHE TESTS PASSED.")


if __name__ == "__main__":
    main()
