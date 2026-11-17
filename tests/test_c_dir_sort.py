#!/usr/bin/env python3
"""src/fs/dir_sort.c + dir_sort_radix.c versus the frozen assembly (tests/harness/dir_sort*_reference.s): DirModel_sort and the
index-slice sorts behind it (comparator, insertion sort, heapsort, introsort, size/mtime radix, name/extension prefix radix).

DS1 differential (x86_64): random listings of 0..60000 entries (short ASCII, long shared prefixes, UTF-8 and high bytes,
    extensions, duplicate names / sizes / times, directories and directory links, extreme sizes and times) sorted in every mode and
    direction with and without "..", around every threshold (insertion 16, radix 64, prefix 512), empty filtered views
    (count < has_dotdot), stats complete or not; the resulting order must be identical index for index
DS2 the pieces on their own: cmp_indices / extract_radix_key / make_prefix_key on random pairs, heapsort / insertion / radix on
    raw slices, OOM of the radix and prefix scratch arrays (introsort fallback)
DS3 speed: DirModel_sort on 150000 entries in each mode within 10 % of the asm (the sort is a hot path of large directories)
DS4 qemu-aarch64: the C modules give the x86_64 orders; DS5 mutation check
"""

import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/dir_sort.c", "src/fs/dir_sort_radix.c"]
REFS = [f"tests/harness/{m}_reference.s" for m in ("dir_sort", "dir_sort_intro", "dir_sort_radix", "dir_sort_prefix")]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, srcs: list[str] | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    s1, s2 = [s if Path(s).is_absolute() else str(ROOT / s) for s in (srcs or SRCS)]
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            extra.append(o)
        H.rename_defined_globals(extra, "ref_")
        for o in extra:
            subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=ds_alloc", str(o)], check=True)
    return H.build(arch, t, ["tests/harness/dir_sort_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), f'-DDS_SRC1="{s1}"', f'-DDS_SRC2="{s2}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=600)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def sort_script(rng: random.Random) -> str:
    s = []
    sizes = [0, 1, 2, 3, 15, 16, 17, 18, 63, 64, 65, 66, 200, 511, 512, 513, 514, 2000, 9000]
    for n in sizes:
        s.append(f"E {n} {rng.randrange(1 << 40)} {rng.randrange(4)} {rng.choice([0, 10, 60])} {rng.choice([0, 30, 100])}\n")
        for mode in (0, 1, 2, 3, 5):
            for desc in (0, 1):
                dot = rng.randrange(2)
                count = n if rng.random() < 0.8 else rng.randrange(0, n + 1)
                s.append(f"M {mode} {desc} {dot} {max(count, 0)} {rng.randrange(2)}\n")
    for kind in range(4):                                                # big listings: radix / prefix passes over many lanes
        s.append(f"E 60000 {rng.randrange(1 << 40)} {kind} {rng.choice([0, 20])} 15\n")
        for mode in (0, 1, 2, 3):
            s.append(f"M {mode} {rng.randrange(2)} 1 60000 1\n")
    for keys in (1, 2):                                                  # an odd number of radix passes: the result is copied back
        for n in (64, 300, 5000):
            s.append(f"E {n} {rng.randrange(1 << 40)} 0 {rng.choice([0, 30])} 10 {keys}\n" + "".join(f"M {m} {d} 0 {n} 1\n" for m in (1, 2) for d in (0, 1)))
    s.append("E 5 1 0 0 0\nM 0 0 1 0 1\nM 1 0 1 1 0\nM 2 1 0 2 0\n")    # empty filtered view (count < has_dotdot) and tiny views
    return "".join(s)


def piece_script(rng: random.Random) -> str:
    s = []
    for n, kind in ((300, 0), (300, 1), (300, 2), (700, 3), (5000, 3)):
        s.append(f"E {n} {rng.randrange(1 << 40)} {kind} 25 20\n")
        s += [f"K {rng.randrange(n)} {rng.randrange(n)} {rng.randrange(6)} {rng.randrange(2)}\n" for _ in range(300)]
        s += [f"K 7 7 {m} 1\n" for m in range(4)]
        for mode in range(4):
            for desc in (0, 1):
                s.append(f"H {mode} {desc} {rng.randrange(n + 1)}\nI {mode} {desc} {rng.randrange(min(n, 400) + 1)}\n")
                s.append(f"R {1 + mode % 2} {desc} {rng.randrange(64, n + 1)}\n")
        for k in (1, 2, 3):                                              # OOM of each scratch array: introsort fallback
            s.append(f"O {k}\nM 1 {k % 2} 0 {n} 1\nO {k}\nM 3 {k % 2} 0 {n} 1\nO {k}\nR 2 0 {n}\n")
    return "".join(s)


def diff(exe: Path, script: str, tag: str) -> str:
    a, b = run(exe, "ref", script), run(exe, "c", script)
    if a != b:
        x, y = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
        raise AssertionError(f"{tag}: oracle and C differ:\n  ref {x[:200]}\n  c   {y[:200]}")
    return b


def test_differential(exe: Path, sorts: str, pieces: str) -> tuple[str, str]:
    a = diff(exe, sorts, "DirModel_sort")
    b = diff(exe, pieces, "pieces")
    ms = [ln for ln in a.splitlines() if ln.startswith("M ")]
    assert any("stats=1" in ln for ln in ms) and any("stats=0" in ln for ln in ms) and all(" unsorted=0 " in ln for ln in ms)
    ks = [ln.split() for ln in b.splitlines() if ln.startswith("K ")]
    assert {k[1] for k in ks} == {"-1", "0", "1"}, "comparator outcomes"
    print(f"[PASS] DS1. DirModel_sort identical to the asm in {len(ms)} sorts (all modes / directions, '..', thresholds 16 / 64 / 512, "
          "60000-entry radix and prefix sorts, empty views)")
    print(f"[PASS] DS2. cmp_indices / keys on {len(ks)} pairs, heapsort / insertion / radix slices and scratch OOM identical to the asm")
    return a, b


def test_speed(exe: Path) -> None:
    s = "".join(f"E 150000 {seed} {kind} 10 10\n" + "".join(f"T {mode} 0 5\n" for mode in range(4)) for seed, kind in ((11, 0), (12, 3)))
    best = {impl: None for impl in ("ref", "c")}
    for _ in range(2):
        for impl in best:
            ts = [int(ln.split()[1]) for ln in run(exe, impl, s).splitlines() if ln.startswith("T ")]
            best[impl] = ts if best[impl] is None else [min(x, y) for x, y in zip(best[impl], ts)]
    for r, c in zip(best["ref"], best["c"]):
        assert c <= r * 1.10 + 2, f"DirModel_sort slower than the asm: asm {best['ref']} ms, C {best['c']} ms"
    print(f"[PASS] DS3. DirModel_sort on 150000 entries (name / size / mtime / ext, two name kinds): asm {best['ref']} ms, C {best['c']} ms")


MUTANTS = [
    ("src/fs/dir_sort.c", "insertion threshold", "#define INSERTION_MIN_N 16", "#define INSERTION_MIN_N 15"),
    ("src/fs/dir_sort.c", "tie keeps direction", "        desc = 0;                                                    /* equal", "        (void)0;                                                     /* equal"),
    ("src/fs/dir_sort.c", "no case-sensitive tie", "if (!r) r = str_cmp(na, nb);", ""),
    ("src/fs/dir_sort.c", "ext without ext first", "if (!xa) r = xb ? -1 : 0;", "if (!xa) r = xb ? 1 : 0;"),
    ("src/fs/dir_sort.c", "size compare", "return a > b ? 1 : -1;", "return a < b ? 1 : -1;"),
    ("src/fs/dir_sort.c", "radix key bias", "^ 0x8000000000000000ull", "^ 0"),
    ("src/fs/dir_sort.c", "median of three", "if (ds_cmp(c, arr[0], arr[hi]) > 0) ds_swap(arr, 0, hi);", ""),
    ("src/fs/dir_sort.c", "depth", "2 * (size_t)(63 - __builtin_clzll(len))", "(size_t)(63 - __builtin_clzll(len))"),
    ("src/fs/dir_sort.c", "heap right child", "if (child + 1 < n && ", "if (child + 1 < n - 1 && "),
    ("src/fs/dir_sort_radix.c", "radix threshold", "#define RADIX_MIN_N 64", "#define RADIX_MIN_N 65"),
    ("src/fs/dir_sort_radix.c", "prefix threshold", "#define PREFIX_MIN_N 512", "#define PREFIX_MIN_N 513"),
    ("src/fs/dir_sort_radix.c", "radix ties by name", "introsort_u32(arr + i, j - i, entries, pool, SORT_NAME, 0);", "(void)0;"),
    ("src/fs/dir_sort_radix.c", "prefix fold", "if (b >= 'A' && b <= 'Z') b += 32;", ""),
    ("src/fs/dir_sort_radix.c", "prefix ext flag", "key = 1;                                                      /* has", "key = 0;                                                      /* has"),
    ("src/fs/dir_sort_radix.c", "prefix ties skipped", "if (j - i >= 2) introsort_u32(arr + i, j - i, entries, pool, mode, desc);", "(void)0;"),
    ("src/fs/dir_sort_radix.c", "link dirs are files", "(FE_IS_DIR | FE_LINK_DIR)", "FE_IS_DIR"),
    ("src/fs/dir_sort_radix.c", "stats skipped", "&& !m->stats_complete) DirModel_ensure_all_stats(m);", "&& false) DirModel_ensure_all_stats(m);"),
    ("src/fs/dir_sort_radix.c", "dotdot sorted", "uint32_t *s = m->order + (uint32_t)m->has_dotdot;", "uint32_t *s = m->order;"),
    ("src/fs/dir_sort_radix.c", "copy back", "if (src != arr) mem_copy(arr, src, len * 4);", ""),
]


# Not mutated (behaviourally equivalent, speed only): skipping constant radix lanes (a pass over a constant byte keeps the order)
# and which introsort part is recursed first (each part is sorted on its own).
def test_mutants(t: Path, scripts: tuple[str, str], expect: tuple[str, str]) -> None:
    srcs = {s: (ROOT / s).read_text() for s in SRCS}
    for f, name, old, _ in MUTANTS:
        assert old in srcs[f], f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, f: str, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            paths = []
            for s in SRCS:
                p = mt / Path(s).name
                p.write_text(srcs[s].replace(old, new, 1) if s == f else srcs[s])
                paths.append(str(p))
            try:
                exe = build("x86_64", mt, paths)
                noticed[name] = any(run(exe, "c", sc) != e for sc, e in zip(scripts, expect))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DS5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    rng = random.Random(0xD5)
    scripts = (sort_script(rng), piece_script(rng))
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, *scripts)
        test_speed(exe)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for sc, e in zip(scripts, expect):
                assert run(a64, "c", sc, "aarch64") == e, "qemu-aarch64 differs from x86_64"
            print("[PASS] DS4. qemu-aarch64: the C modules give the x86_64 orders")
        else:
            print("[SKIP] DS4: aarch64 toolchain/qemu not installed")
        test_mutants(t, scripts, expect)
    print("ALL C DIR SORT TESTS PASSED.")


if __name__ == "__main__":
    main()
