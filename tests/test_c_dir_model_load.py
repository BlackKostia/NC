#!/usr/bin/env python3
"""src/fs/dir_model_load.c + dir_model_stream.c versus the frozen assembly (tests/harness/dir_model_load_reference.s +
dir_model_stream_reference.s): ensure_capacity, finish_load_internal, DirModel_reload, DirModel_step_load, DirModel_cancel_load.

DL1 differential on real directories (x86_64): mixed entries (directories, symlinks, FIFO, hidden, UTF-8 and wide names, dots, a
    255-byte name), an empty directory, "/", 30000 files streamed with budgets 0 / 1 / 7 / 4096 and environment overrides of the
    batch size and the huge threshold (ls -f mode), filters and hidden mode during the stream, cancel (Esc) mid-stream, a missing
    and an unreadable directory, OOM of the getdents buffer, of the ".." slot and of every capacity growth: every entry field, the
    order, the counters, the capacities and the state flags
DL2 two defects of the asm, fixed: an allocation failure while streaming came back as 0xfffffff4 in rax (eax only), which the event
    loop took for "more to come"; and the truncated listing was finished as if complete, so the dir cache could take it and serve
    it on the next visit. Now -ENOMEM is returned and the partial listing is marked aborted (shown, never cached)
DL3 speed: reloading and streaming 200000 entries is not slower than the asm (within 10 %)
DL4 qemu-aarch64: the C modules give the x86_64 results; DL5 mutation check
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/dir_model_load.c", "src/fs/dir_model_stream.c"]
REFS = ["tests/harness/dir_model_load_reference.s", "tests/harness/dir_model_stream_reference.s"]
MODS = ["src/fs/dir_model_filter.c", "src/fs/dir_cache.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_model_stat.c",
        "src/fs/dir_model_select.c", "src/core/oop_rt.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, srcs: list[str] | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    s1, s2 = [s if Path(s).is_absolute() else str(ROOT / s) for s in (srcs or SRCS)]
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
        for o in refs:
            subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=dml_alloc", "--redefine-sym", "mem_realloc=dml_realloc", str(o)], check=True)
        extra += refs
    return H.build(arch, t, ["tests/harness/dir_model_load_cli.c", *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), f'-DDML_SRC1="{s1}"', f'-DDML_SRC2="{s2}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=600)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def trees(t: Path) -> dict[str, Path]:
    mixed = t / "mixed"
    mixed.mkdir(parents=True)
    for d in ("sub", ".hidden_dir", "dir.with.dots"):
        (mixed / d).mkdir()
    for f in ("a.txt", ".bashrc", "noext", "x.tar.gz", "ünïcödé.md", "日本語ファイル名.txt", "e" * 255, "ends.", ".a.b"):
        (mixed / f).write_text(f)
    os.symlink("sub", mixed / "lnk_dir")
    os.symlink("a.txt", mixed / "lnk_file")
    os.mkfifo(mixed / "fifo")
    empty = t / "empty"
    empty.mkdir()
    big = t / "big"
    big.mkdir()
    fd = os.open(big, os.O_RDONLY)
    try:
        for i in range(30000):
            name = f"f{i:05d}" + (".c" if i % 3 == 0 else "") if i % 97 else f".h{i}"
            os.close(os.open(name, os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
        for i in range(40):
            os.mkdir(f"d{i}", dir_fd=fd)
    finally:
        os.close(fd)
    exact = t / "exact"                                                   # ".." + 5041 names of 12 bytes fill the pool to exactly 64 KiB
    exact.mkdir()
    fd = os.open(exact, os.O_RDONLY)
    try:
        for i in range(5041):
            os.close(os.open(f"x{i:011d}", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
    finally:
        os.close(fd)
    exact1 = t / "exact1"                                                 # one byte more: the last name must grow the pool
    exact1.mkdir()
    fd = os.open(exact1, os.O_RDONLY)
    try:
        for i in range(5041):
            os.close(os.open(f"x{i:011d}" + ("y" if i == 77 else ""), os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
    finally:
        os.close(fd)
    ro = t / "ro"
    ro.mkdir()
    (ro / "x").write_text("x")
    ro.chmod(0)
    return {"mixed": mixed, "empty": empty, "big": big, "ro": ro, "missing": t / "missing", "exact": exact, "exact1": exact1}


def scripts(d: dict[str, Path]) -> list[str]:
    m, b = d["mixed"], d["big"]
    s = [f"L {m}\nA 0\n", f"F - 0\nL {m}\nA 0\nF - 1\n", f"F A 1\nL {m}\nA 0\nF - 1\n", f"F t 0\nL {m}\nA 0\nF - 1\n",
         f"L {d['empty']}\nA 0\n", "L /\nA 0\n", f"L {d['missing']}\n", f"L {d['ro']}\n", f"L {m} a 1\n", f"L {m} r 1\n"]
    for budget in (1, 7, 4096, 0):
        s.append(f"L {b}\nS {budget}\nS {budget}\nA {budget}\n")
    s.append(f"E 1000 300\nL {b}\nA 0\nE 50000 4096\n")                  # huge mode from 1000 entries, 300 per step
    s.append(f"E 0 0\nL {b}\nA 0\nE 50000 4096\n")                        # zero overrides: the defaults
    s.append(f"L {b}\nS 5000\nX\nS 10\nK\n")                              # Esc mid-stream: kept rows, aborted, not cached
    s.append(f"F f0 0\nL {b}\nA 999\nF - 1\n")
    for k in range(1, 9):                                                 # every capacity growth fails once
        s.append(f"L {b}\nA 4096 {k}\n")
    s.append(f"L {m}\nA 0\nK\n")                                          # a complete listing is cacheable
    s.append(f"L {d['exact']}\nA 0\nL {d['exact1']}\nA 0\n")
    s += [f"E {h} 4096\nL {m}\nA 0\nE 50000 4096\n" for h in (15, 16, 17)]   # huge mode exactly at the last entry
    s.append(f"L {m}\nA 0\nR\nA 0\nR\nS 2\nR\n")                                 # refresh an existing model
    return s


def diff(exe: Path, ss: list[str]) -> list[str]:
    a, b = [run(exe, "ref", s) for s in ss], [run(exe, "c", s) for s in ss]
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            p, q = next((p, q) for p, q in zip(x.splitlines(), y.splitlines()) if p != q)
            raise AssertionError(f"script {i}: oracle and C differ:\n  ref {p[:400]}\n  c   {q[:400]}")
    return b


def test_stream_oom(exe: Path, d: dict[str, Path]) -> None:
    b = d["big"]
    hit = 0
    for k in range(1, 9):
        s = f"L {b}\nA 4096 {k}\nK\n"
        ref, c = run(exe, "ref", s).splitlines(), run(exe, "c", s).splitlines()
        if " r=-12 " not in c[1]:
            continue                                                      # this growth happened inside reload already
        hit += 1
        assert " r=4294967284 " in ref[1] and " ab=0 " in ref[1] and ref[2] == "K 1", ("asm: eax-only -ENOMEM, cached", ref)
        assert " ab=1 " in c[1] and c[2] == "K 0", ("C: -ENOMEM, aborted, not cached", c)
    assert hit >= 3, hit
    print(f"[PASS] DL2. fixed: OOM while streaming ({hit} growth points) returns -ENOMEM and leaves the partial listing aborted and "
          "uncacheable (asm: 0xfffffff4 = 'more', listing cached as complete)")


def test_speed(exe: Path, t: Path) -> None:
    big = t / "huge"
    big.mkdir()
    fd = os.open(big, os.O_RDONLY)
    try:
        for i in range(200000):
            os.close(os.open(f"n{i:06d}.dat", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
    finally:
        os.close(fd)
    s = f"E 1000000 4096\nT {big} 4096\nT {big} 0\nE 1000 4096\nT {big} 4096\n"
    best = {impl: None for impl in ("ref", "c")}
    for _ in range(4):
        for impl in ("ref", "c"):
            ms = [int(ln.split()[1]) for ln in run(exe, impl, s).splitlines()]
            best[impl] = ms if best[impl] is None else [min(a, b) for a, b in zip(best[impl], ms)]
        if all(c <= r * 1.10 + 3 for r, c in zip(best["ref"], best["c"])):
            break
    for r, c in zip(best["ref"], best["c"]):
        assert c <= r * 1.10 + 3, f"loading is slower than the asm: {best}"
    print(f"[PASS] DL3. reload + stream of 200000 entries (sorted, default batch, ls -f mode): asm {best['ref']} ms, C {best['c']} ms")


MUTANTS = [
    ("src/fs/dir_model_load.c", "first cap", "(m->raw_cap ? m->raw_cap : INITIAL_FILE_CAP / 2) * 2", "(m->raw_cap ? m->raw_cap : INITIAL_FILE_CAP / 2) * 2 + 1"),
    ("src/fs/dir_model_load.c", "pool growth", "do nc <<= 1; while (nc < want);", "nc = want;"),
    ("src/fs/dir_model_load.c", "cancel sorts", "if (canceled) m->load_aborted = 1;", "if (canceled) { m->load_aborted = 1; DirModel_sort(m); }"),
    ("src/fs/dir_model_load.c", "huge sorted", "else if (m->huge_mode) m->is_unsorted = 1;", "else if (false) m->is_unsorted = 1;"),
    ("src/fs/dir_model_load.c", "reset counts", "    m->dir_count = m->file_count = m->has_dotdot = 0;\n", "    m->has_dotdot = 0;\n"),
    ("src/fs/dir_model_load.c", "no stamp", "        ino = st.ino;\n", ""),
    ("src/fs/dir_model_load.c", "parent at root", "if (!(m->path[0] == '/' && !m->path[1])) {", "if (true) {"),
    ("src/fs/dir_model_load.c", "parent flags", ".flags = FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY", ".flags = FE_IS_DIR | FE_IS_PARENT"),
    ("src/fs/dir_model_load.c", "unsorted while streaming", "if (m->is_loading) m->is_unsorted = 1;", "(void)0;"),
    ("src/fs/dir_model_load.c", "no git refresh", "    (void)git_refresh(m);\n", ""),
    ("src/fs/dir_model_stream.c", "budget default", "#define STREAM_BATCH_BUDGET 4096", "#define STREAM_BATCH_BUDGET 4095"),
    ("src/fs/dir_model_stream.c", "utf8 width ignored", "hi & 0x80 ? (uint32_t)utf8_display_width(name) : ", ""),
    ("src/fs/dir_model_stream.c", "hidden", "uint32_t flags = name[0] == '.' ? FE_IS_HIDDEN : 0, mode;", "uint32_t flags = 0, mode;"),
    ("src/fs/dir_model_stream.c", "link mode", "mode = S_IFLNK | 0777;", "mode = S_IFLNK | 0755;"),
    ("src/fs/dir_model_stream.c", "huge bound", "if (m->raw_count >= huge)", "if (m->raw_count > huge)"),
    ("src/fs/dir_model_stream.c", "filter ignored", "if (shown) {", "if (true) {"),
    ("src/fs/dir_model_stream.c", "hidden shown", "(!(flags & FE_IS_HIDDEN) || m->show_hidden) &&", "true &&"),
    ("src/fs/dir_model_stream.c", "capacity fast path", "m->name_used + len + 1 > m->name_cap", "m->name_used + len > m->name_cap"),
    ("src/fs/dir_model_stream.c", "dotdot listed", "(!name[1] || (name[1] == '.' && !name[2]))", "(!name[1])"),
    ("src/fs/dir_model_stream.c", "cancel ignored", "if (m->is_loading) finish_load_internal(m, 1);", "(void)m;"),
]


# Not mutated: the "want > name_cap" test inside ensure_capacity (the stream's inline fast path decides before the call, ".." needs
# 3 bytes of an empty pool). Unreachable on Linux (NAME_MAX = 255): the 255 caps of ext_offset and of the ASCII display width; equivalent: a
# leading dot counted as the extension dot (ext_offset 0 either way).
def test_mutants(t: Path, ss: list[str], expect: list[str]) -> None:
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
                noticed[name] = any(run(exe, "c", s) != e for s, e in zip(ss, expect))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DL5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd).resolve()
        d = trees(t / "fs")
        try:
            ss = scripts(d)
            exe = build("x86_64", t / "x86")
            clean = [s for s in ss if not (s.startswith(f"L {d['big']}\nA 4096 ") and s.count("\n") == 2)]
            expect = diff(exe, clean)
            text = "".join(expect)
            assert " hu=1 " in text and " ab=1 " in text and "r=-2 " in text and "r=-13 " in text and "r=-12 " in text, "coverage"
            print(f"[PASS] DL1. reload / stream / cancel identical to the asm in {sum(o.count(chr(10)) for o in expect)} steps "
                  "(mixed entries, empty, '/', 30000 files at budgets 1 / 7 / 4096 / default, huge mode, filters, Esc, ENOENT, EACCES, OOM)")
            test_stream_oom(exe, d)
            test_speed(exe, t / "fs")
            if H.available("aarch64"):
                a64 = build("aarch64", t / "a64")
                c_all = [run(exe, "c", s) for s in ss]
                assert [run(a64, "c", s, "aarch64") for s in ss] == c_all, "qemu-aarch64 differs from x86_64"
                print("[PASS] DL4. qemu-aarch64: the C modules give the x86_64 results")
            else:
                print("[SKIP] DL4: aarch64 toolchain/qemu not installed")
                c_all = [run(exe, "c", s) for s in ss]
            test_mutants(t, ss, c_all)
        finally:
            d["ro"].chmod(0o755)
    print("ALL C DIR MODEL LOAD TESTS PASSED.")


if __name__ == "__main__":
    main()
