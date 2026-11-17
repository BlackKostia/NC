#!/usr/bin/env python3
"""src/fs/dir_model_stat.c + dir_model_select.c versus the frozen assembly (tests/harness/dir_model_stat_reference.s,
dir_model_select_reference.s, dir_model_entry_reference.s): lazy stat, batched stat, selection and lookup of a DirModel.

DM1 differential on a real tree (x86_64): regular files (sizes, executable bits), directories, symlinks to files / directories /
    symlinks to directories / nowhere, a FIFO, names with blanks and UTF-8, entries that vanished after the listing (stat fails),
    "..", loader flags (FE_IS_DIR from d_type, FE_DT_UNKNOWN, FE_LINK_DIR already known); stat_range over every window and with
    the streaming fd, ensure_entry_stat, ensure_all_stats in chunks of 1024 (3000 entries) with its batched link pass, OOM of
    its chunk, a vanished directory; toggle / select-all / count / find / get_entry at and beyond the bounds; every entry field,
    the counters and the number of open fds after each step
DM2 qemu-aarch64: the C modules give the x86_64 results; DM3 mutation check
"""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/dir_model_stat.c", "src/fs/dir_model_select.c"]
REFS = [f"tests/harness/{m}_reference.s" for m in ("dir_model_stat", "dir_model_select", "dir_model_entry")]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
FE_IS_DIR, FE_IS_LINK, FE_IS_HIDDEN, FE_SELECTED, FE_IS_PARENT, FE_LINK_DIR, FE_STAT_READY, FE_DT_UNKNOWN = 1, 2, 8, 16, 32, 64, 128, 256


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
            subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=dm_alloc", str(o)], check=True)
        extra += refs
    return H.build(arch, t, ["tests/harness/dir_model_stat_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), f'-DDM_SRC1="{s1}"', f'-DDM_SRC2="{s2}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=300)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def esc(name: str) -> str:
    return "".join("\\s" if c == " " else c if ord(c) < 128 else "".join(f"\\x{b:02x}" for b in c.encode()) for c in name)


def tree(t: Path) -> tuple[Path, list[tuple[str, int]], int, int]:
    d = t / "tree"
    d.mkdir(parents=True)
    ents: list[tuple[str, int]] = [("..", FE_IS_PARENT | FE_IS_DIR | FE_STAT_READY)]
    rng = random.Random(3)
    for i in range(12):
        p = d / f"file{i}.txt"
        p.write_bytes(b"x" * rng.randrange(0, 5000))
        p.chmod(rng.choice([0o644, 0o755, 0o700, 0o600, 0o611]))
        ents.append((p.name, rng.choice([0, FE_IS_HIDDEN, FE_DT_UNKNOWN])))
    for name in ("sub", "sub 2", "ünï"):
        (d / name).mkdir()
        ents.append((name, FE_IS_DIR))
    os.symlink("file1.txt", d / "lnk_file")
    os.symlink("sub", d / "lnk_dir")
    os.symlink("lnk_dir", d / "lnk_lnk_dir")
    os.symlink("nowhere", d / "lnk_dangling")
    os.mkfifo(d / "fifo")
    ents += [("lnk_file", 0), ("lnk_dir", 0), ("lnk_lnk_dir", FE_DT_UNKNOWN), ("lnk_dangling", 0), ("fifo", 0),
             ("lnk_dir", FE_LINK_DIR), ("gone_file", 0), ("gone_dir", FE_IS_DIR)]
    ents.append(("ready", FE_STAT_READY))
    (d / "ready").write_bytes(b"r" * 10)
    dirs = sum(1 for _, fl in ents if fl & FE_IS_DIR and not fl & FE_IS_PARENT)
    return d, ents, dirs, len(ents) - 1 - dirs


def model(d: Path, ents: list[tuple[str, int]], dirs: int, files: int, rev: bool = False, dotdot: int = 1) -> str:
    s = f"P {d} {dotdot} {dirs} {files}\n" + "".join(f"N {esc(n)} {fl}\n" for n, fl in (ents if dotdot else ents[1:]))
    return s + ("R\n" if rev else "")


def scripts(t: Path) -> list[str]:
    d, ents, dirs, files = tree(t)
    n = len(ents)
    out = []
    for start in range(0, n + 2, 3):                                     # stat_range windows (and with the streaming fd)
        for ln in (0, 1, 4, n):
            for w in (0, 1):
                out.append(model(d, ents, dirs, files, rev=start % 2 == 1) + f"W {w}\nS {start} {ln}\nS 0 {n}\nQ\n")
    out.append(model(d, ents, dirs, files) + "".join(f"E {i}\n" for i in range(-1, n + 2)) + "Q\n")
    for w in (0, 1):
        out.append(model(d, ents, dirs, files, rev=True) + f"W {w}\nE 3\nA\nA\nQ\n")
    out.append(model(d, ents, dirs, files) + "O 1\nA\nQ\nA\nQ\n")             # OOM of the chunk: nothing changes, then it works
    out.append(f"P {t / 'missing_dir'} 0 0 3\nN a 0\nN b 0\nN c 0\nA\nE 0\nS 0 3\nQ\n")
    sel = "".join(f"T {i}\n" for i in (-5, 0, 1, 2, 2, 5, n - 1, n, n + 9)) + "C x\nC\nX\nC x\nX\nC x\nT 4\nX\nC x\n"
    sel += "".join(f"F {esc(nm)}\n" for nm in ("..", "file3.txt", "sub 2", "ünï", "lnk_dir", "nope", "")) + "".join(f"G {i}\n" for i in (-1, 0, n - 1, n, 1 << 40))
    out.append(model(d, ents, dirs, files) + sel)
    out.append(model(d, ents, dirs, files, rev=True, dotdot=0) + sel)
    pend = [("..", FE_IS_PARENT | FE_IS_DIR | FE_SELECTED)] + ents[1:]   # ".." not stat'ed yet and selected; no files counted yet
    out.append(model(d, pend, dirs, 0) + "A\nX\nC x\nX\nC x\n")
    out.append(model(d, pend, dirs, 0, rev=True) + f"K {n - 4}\nS {n - 5} 2\nS {n - 6} 9\nS 0 {n}\nX\nC x\n")   # filtered view: hidden rows stay
    big = t / "big"                                                       # 3000 entries: three chunks of the batched stat
    big.mkdir()
    rng = random.Random(9)
    bents = []
    for i in range(3000):
        p = big / f"e{i:04d}"
        k = rng.randrange(10)
        if k == 0:
            p.mkdir(); bents.append((p.name, FE_IS_DIR))
        elif k == 1:
            os.symlink("e0000" if i else "x", p); bents.append((p.name, 0))
        elif k == 2:
            bents.append((p.name, 0))                                     # listed, then gone
        else:
            p.write_bytes(b"b" * k); bents.append((p.name, FE_STAT_READY if k == 9 else 0))
    for w in (0, 1):
        out.append(model(big, bents, 0, 3000, dotdot=0) + f"W {w}\nA\nC\nX\nC x\nQ\n")
    return out


def outputs(exe: Path, impl: str, ss: list[str], arch: str = "x86_64") -> list[str]:
    return [run(exe, impl, s, arch) for s in ss]


def test_differential(exe: Path, ss: list[str]) -> list[str]:
    a, b = outputs(exe, "ref", ss), outputs(exe, "c", ss)
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            p, q = next((p, q) for p, q in zip(x.splitlines(), y.splitlines()) if p != q)
            raise AssertionError(f"script {i}: oracle and C differ:\n  ref {p[:300]}\n  c   {q[:300]}")
    text = "".join(b)
    assert "complete=1" in text and f"|{FE_IS_LINK | FE_STAT_READY | FE_LINK_DIR}," in text, "batched link pass reached"
    fds = {ln for ln in text.splitlines() if ln.startswith("Q ")}
    assert len(fds) == 1, f"an fd leaks: {fds}"
    print(f"[PASS] DM1. lazy stat / batched stat / selection identical to the asm in {sum(x.count(chr(10)) for x in b)} steps "
          f"over {len(ss)} models (links, FIFO, vanished entries, streaming fd, 3 chunks of 1024, OOM, no fd leak)")
    return b


MUTANTS = [
    ("src/fs/dir_model_stat.c", "get_entry bound", "(uint64_t)idx >= m->count", "(uint64_t)idx > m->count"),
    ("src/fs/dir_model_stat.c", "link dir counted twice", "if (!(e->flags & (FE_IS_DIR | FE_LINK_DIR))) {\n        m->dir_count++;", "if (true) {\n        m->dir_count++;"),
    ("src/fs/dir_model_stat.c", "file count below zero", "        if (m->file_count) m->file_count--;\n    }\n    e->flags |= FE_LINK_DIR;", "        m->file_count--;\n    }\n    e->flags |= FE_LINK_DIR;"),
    ("src/fs/dir_model_stat.c", "dt_unknown kept", "~(uint32_t)(FE_DT_UNKNOWN | FE_IS_EXEC)", "~(uint32_t)FE_IS_EXEC"),
    ("src/fs/dir_model_stat.c", "exec bits", "if (st->mode & 0111)", "if (st->mode & 0100)"),
    ("src/fs/dir_model_stat.c", "dir bytes counted", "        if (st->mode & 0111) fl |= FE_IS_EXEC;\n        m->total_bytes", "        if (st->mode & 0111) fl |= FE_IS_EXEC;\n    }\n    {\n        m->total_bytes"),
    ("src/fs/dir_model_stat.c", "link target not followed", "&t, 1) >= 0", "&t, 0) >= 0"),
    ("src/fs/dir_model_stat.c", "failed stat retried", "if (os_statat(dirfd, m->name_pool + e->name_off, &st, 0) < 0) e->flags |= FE_STAT_READY;", "if (os_statat(dirfd, m->name_pool + e->name_off, &st, 0) < 0) (void)0;"),
    ("src/fs/dir_model_stat.c", "range end", "if (end > m->count) end = m->count;", "if (end > m->count + 1) end = m->count;"),
    ("src/fs/dir_model_stat.c", "own fd leaked", "    if (own) (void)os_close(fd);\n}", "}"),
    ("src/fs/dir_model_select.c", "dotdot stat'ed", "for (uint64_t i = (uint32_t)m->has_dotdot;", "for (uint64_t i = 0;"),
    ("src/fs/dir_model_select.c", "batch errors kept pending", "if (c->errs[k]) c->entries[k]->flags |= FE_STAT_READY;", "if (c->errs[k]) (void)0;"),
    ("src/fs/dir_model_select.c", "links not batched", "if (!k) return;", "return;"),
    ("src/fs/dir_model_select.c", "complete flag", "    m->stats_complete = 1;\n", ""),
    ("src/fs/dir_model_select.c", "toggle parent", "if (!e || (e->flags & FE_IS_PARENT)) return;", "if (!e) return;"),
    ("src/fs/dir_model_select.c", "select-all parent", "any = !(fl & FE_IS_PARENT) && (fl & FE_SELECTED);", "any = (fl & FE_SELECTED);"),
    ("src/fs/dir_model_select.c", "count bytes", "if (out_bytes) *out_bytes = bytes;", "if (out_bytes) *out_bytes = (int64_t)n;"),
    ("src/fs/dir_model_select.c", "find returns raw index", "return (intptr_t)i;", "return (intptr_t)m->order[i];"),
]


# Not mutated: the chunk size of the batched stat (1024) only changes how many names one os_batch_stat call carries.
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
                noticed[name] = outputs(exe, "c", ss) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DM3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        ss = scripts(t / "fs")
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, ss)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            got = outputs(a64, "c", ss, "aarch64")
            assert got == expect, "qemu-aarch64 differs from x86_64"
            print("[PASS] DM2. qemu-aarch64: the C modules give the x86_64 results")
        else:
            print("[SKIP] DM2: aarch64 toolchain/qemu not installed")
        test_mutants(t, ss, expect)
    print("ALL C DIR MODEL STAT TESTS PASSED.")


if __name__ == "__main__":
    main()
