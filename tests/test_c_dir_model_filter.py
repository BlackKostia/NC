#!/usr/bin/env python3
"""src/fs/dir_model_filter.c versus the frozen assembly (tests/harness/dir_model_filter_reference.s + dir_model_flt_reference.s):
prepare_filter / entry_passes_filter / DirModel_apply_filter / DirModel_chdir.

DF1 apply_filter differential (x86_64): synthetic listings with hidden entries, directories and directory links, UTF-8; random
    filter sequences that narrow (the in-place path), widen, change case, reach FILTER_MAX - 1 = 63 bytes and beyond, flip
    show_hidden, run while loading, grow the raw count, in unsorted / huge mode and in every sort mode and direction: the visible
    order, counts and the whole filter state
DF2 chdir differential on a real tree: into sub-directories, "..", absolute and relative targets, ".", "/" , symlinks to
    directories, a file (ENOTDIR), a missing path, an unreadable directory (EACCES), a path that does not fit PATH_MAX (EINVAL);
    going back hits the dir cache (no reload, the filter cleared, stats reset), a directory touched in between is reloaded, view
    settings changed in between re-filter and re-sort the snapshot
DF3 a defect of the asm, fixed: when the listing had been donated to the cache and the fresh arrays could not be allocated,
    DirModel_chdir returned -ENOMEM in eax only (rax = 0xfffffff4, positive): every caller took it for success
DF4 qemu-aarch64: the C module gives the x86_64 results; DF5 mutation check
"""

import os
import random
import subprocess
import time
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/dir_model_filter.c"
REFS = ["tests/harness/dir_model_filter_reference.s", "tests/harness/dir_model_flt_reference.s"]
MODS = ["src/fs/dir_cache.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_model_stat.c",
        "src/fs/dir_model_select.c", "src/core/oop_rt.c", "src/core/string_path.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    uring = t / "pal_uring.o"
    subprocess.run([*H.ARCHS[arch]["as_"], *inc, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(uring)], check=True, capture_output=True)
    extra = [uring]
    if arch == "x86_64":
        refs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        extra += refs
    return H.build(arch, t, ["tests/harness/dir_model_filter_cli.c", *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), f'-DDMF_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=300)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def filter_script(rng: random.Random, t: Path) -> str:
    s = [f"N {t}\n"]
    alpha = ["a", "b", "c", "A", "B", "ab", "abc", "x", ".", "é", "É", "zz"]
    for listing in range(14):
        n = rng.choice([0, 1, 5, 30, 200, 700])
        s.append(f"M {n} {rng.randrange(1 << 30)} {rng.choice([0, 20])} {rng.choice([0, 30])}\n")
        flt = ""
        for _ in range(14):
            op = rng.random()
            if op < 0.45:
                flt += rng.choice(alpha)                                  # narrowing
            elif op < 0.65:
                flt = flt[:-1]                                            # widening
            elif op < 0.75:
                flt = flt.upper() if rng.random() < 0.5 else flt.lower()
            elif op < 0.8:
                flt = "a" * rng.choice([62, 63, 64, 70])
            else:
                flt = ""
            extra = []
            if rng.random() < 0.2:
                extra += ["h", str(rng.randrange(2))]
            if rng.random() < 0.1:
                extra += ["l", str(rng.randrange(2))]
            if rng.random() < 0.1:
                extra += ["u", str(rng.randrange(2))]
            if rng.random() < 0.08:
                extra += ["g", str(rng.randrange(2))]
            if rng.random() < 0.15:
                extra += ["s", str(rng.randrange(4)), str(rng.randrange(2))]
            if rng.random() < 0.05:
                extra += ["r", str(max(0, n - 1))]
            s.append(f"F {flt or '-'} {' '.join(extra)}\n")
        s.append("F - l 0 u 0 g 0 h 1\n")
    s.append(f"M 300 7 40 20\nF a h 0\nF ab h 1\nF abc h 0\nF - h 1\n")   # hidden mode changes while the filter narrows
    return "".join(s)


def tree(t: Path) -> Path:
    root = t / "tree"
    for d in ("a/b/c", "a/.hid", "a/b2", "x y", "ro"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for f in ("a/f1", "a/F2", "a/b/g", "a/.hidden_file", "x y/z", "plain"):
        (root / f).write_text(f)
    os.symlink("a/b", root / "lnk")
    (root / "ro").chmod(0)
    return root


def chdir_script(t: Path) -> str:
    r = tree(t)
    long = "/".join(["q" * 200] * 21)
    s = f"N {r}\nD a\nS\nD b\nD ..\nD ..\nD a\nF f\nD b/c\nD ../..\nD /\nD {r}\nD lnk\nD .\nD {r}/plain\nD nope\nD {r}/ro\n"
    s += f"D {long}\nD a\nD ../x y\nD ../a\nD .hid\nD ..\n"
    return s


def test_filter(exe: Path, s: str) -> str:
    a, b = run(exe, "ref", s), run(exe, "c", s)
    if a != b:
        x, y = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
        raise AssertionError(f"apply_filter: oracle and C differ:\n  ref {x[:400]}\n  c   {y[:400]}")
    fs = [ln for ln in b.splitlines() if ln.startswith("F")]
    assert any(" fv=1 " in ln for ln in fs) and any("/63 " in ln for ln in fs) and any(" ld=1 " in ln for ln in fs), "generator coverage"
    print(f"[PASS] DF1. apply_filter identical to the asm in {len(fs)} filter steps (narrowing in place, widening, case, 63-byte cap, "
          "hidden, loading, raw growth, unsorted / huge, all sort modes)")
    return b


def test_chdir(exe: Path, s: str) -> str:
    a, b = run(exe, "ref", s), run(exe, "c", s)
    if a != b:
        x, y = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
        raise AssertionError(f"chdir: oracle and C differ:\n  ref {x[:400]}\n  c   {y[:400]}")
    ds = [ln for ln in b.splitlines() if ln.startswith("D")]
    rs = {ln.split()[1] for ln in ds}
    assert {"r=0", "r=-20", "r=-2", "r=-22"} <= rs, rs
    reloads = [int(ln.split(" reloads=")[1].split()[0]) for ln in ds]
    assert any(b2 == a2 for a2, b2 in zip(reloads, reloads[1:])), "a cache hit needs no reload"
    print(f"[PASS] DF2. chdir identical to the asm in {len(ds)} steps (relative / absolute / '..' / '/' / symlink, ENOTDIR, ENOENT, "
          "EACCES, EINVAL, cache hits without reload, filter cleared)")
    return b


def test_touch(exe: Path, t: Path) -> None:
    r = t / "tree"
    outs = {}
    for impl in ("ref", "c"):
        part1 = run(exe, impl, f"N {r}\nD a\nD ..\nD a\nD ..\n")
        (r / "a").chmod(0o755)
        (r / "a" / "new_file").write_text("x")                           # one name for both: getdents order depends on it
        os.utime(r / "a", ns=(time.time_ns(), time.time_ns()))
        part2 = run(exe, impl, f"N {r}\nD a\nD ..\nF - s 1 1\nD a\nD ..\n")
        outs[impl] = (part1, part2)
        (r / "a" / "new_file").unlink()
    assert outs["ref"] == outs["c"], "touch / re-sort sequence differs"
    print("[PASS] DF2b. a directory changed in between is reloaded; a snapshot taken with other view settings is re-sorted")


def test_oom(exe: Path, t: Path) -> None:
    r = t / "tree"
    s = f"N {r}\nD a\nO 1\nD b\n"                      # leaving a/ donates its listing; the fresh arrays for b/ fail
    ref = [ln for ln in run(exe, "ref", s).splitlines() if ln.startswith("D")]
    c = [ln for ln in run(exe, "c", s).splitlines() if ln.startswith("D")]
    assert ref[-1].startswith("D r=4294967284 ") and c[-1].startswith("D r=-12 "), (ref[-1][:40], c[-1][:40])
    print("[PASS] DF3. fixed: an allocation failure after the donation is reported as -ENOMEM (asm: 0xfffffff4, taken for success)")


MUTANTS = [
    ("filter cap", "if (++c >= FILTER_MAX - 1) {", "if (++c >= FILTER_MAX) {"),
    ("no case fold", "if (b >= 'A' && b <= 'Z') b += 32;", ""),
    ("parent filtered", "if (flags & FE_IS_PARENT) return 1;", ""),
    ("hidden always shown", "if ((flags & FE_IS_HIDDEN) && !m->show_hidden) return 0;", ""),
    ("link dir is a file", "if (flags & (FE_IS_DIR | FE_LINK_DIR)) m->dir_count++;", "if (flags & FE_IS_DIR) m->dir_count++;"),
    ("parent counted", "    if (flags & FE_IS_PARENT) return;\n", ""),
    ("narrowing ignores hidden", " && m->show_hidden == m->flt_hidden", ""),
    ("narrowing while loading", " && !m->is_loading && m->raw_count", " && m->raw_count"),
    ("narrowing after growth", " && m->raw_count == m->flt_raw", ""),
    ("narrowing on any filter", "str_starts_with(m->filter, m->flt_applied)", "true"),
    ("no sort", "if (!m->is_loading && !m->is_unsorted && !m->huge_mode) DirModel_sort(m);", ""),
    ("huge mode sorted", " && !m->huge_mode) DirModel_sort(m);", ") DirModel_sort(m);"),
    ("remembered while loading", "        if (m->is_loading) return;", "        (void)0;"),
    ("filter kept on chdir", "    m->filter[0] = 0;\n", ""),
    ("no donation", "    (void)dircache_store(m);\n", ""),
    ("hit 2 not re-filtered", "if (hit != 1) {", "if (hit == 3) {"),
    ("stats kept on hit", "        reset_entry_stats(m);\n", ""),
    ("path not normalised", "if (!path_normalize(m->path, target, resolved, PATH_MAX)) return -EINVAL;", "if (!str_copy(resolved, target, PATH_MAX)) return -EINVAL;"),
    ("oom swallowed", "&& (r = alloc_initial_arrays(m)) < 0) return r;", "&& (r = alloc_initial_arrays(m)) < 0) return 0;"),
]


def test_mutants(t: Path, scripts: list[str], expect: list[str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "dir_model_filter.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "dir_model_filter.c"))
                noticed[name] = any(run(exe, "c", s) != e for s, e in zip(scripts, expect))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DF5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        rng = random.Random(0xF1)
        (t / "flt").mkdir()
        scripts = [filter_script(rng, t / "flt"), chdir_script(t), f"N {t / 'tree'}\nD a\nO 1\nD b\nD ..\n"]
        try:
            exe = build("x86_64", t / "x86")
            expect = [test_filter(exe, scripts[0]), test_chdir(exe, scripts[1]), run(exe, "c", scripts[2])]
            test_oom(exe, t)
            test_touch(exe, t)
            if H.available("aarch64"):
                a64 = build("aarch64", t / "a64")
                for s, e in zip(scripts, expect):
                    assert run(a64, "c", s, "aarch64") == e, "qemu-aarch64 differs from x86_64"
                print("[PASS] DF4. qemu-aarch64: the C module gives the x86_64 results")
            else:
                print("[SKIP] DF4: aarch64 toolchain/qemu not installed")
            (t / "tree" / "ro").chmod(0)
            test_mutants(t, scripts, expect)
        finally:
            (t / "tree" / "ro").chmod(0o755)
    print("ALL C DIR MODEL FILTER TESTS PASSED.")


if __name__ == "__main__":
    main()
