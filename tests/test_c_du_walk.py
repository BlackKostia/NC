#!/usr/bin/env python3
"""src/fs/du_parallel.c versus the frozen assembly: whole Disk Usage walks (sizes of the top-level folders and every DuProgress
counter) on real trees -- nested folders, symlinks, fifos, hard links across and inside folders, the 64-level depth cap, unreadable
folders, derived mounts (/proc, /sys), cache re-runs after a change -- with and without a progress callback, plus cancellation."""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CLI_C = ["tests/harness/du_walk_cli.c", "src/fs/du_parallel.c", "src/fs/du_links.c", "src/fs/du_cache.c", "src/core/string.c", "src/core/utf8.c",
         "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    ref = t / "du_parallel_ref.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                    str(ROOT / "tests/harness/du_parallel_reference.s"), "-o", str(ref)], check=True)
    H.rename_defined_globals([ref], "ref_")
    extra = [ref]
    for name in ("pal_thread", "pal_du"):                              # PAL files the shared harness does not link by default
        o = t / f"{name}.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / f"src/os/linux/x86_64/{name}.s"), "-o", str(o)], check=True)
        extra.append(o)
    return H.build("x86_64", t, CLI_C, extra)


def walk(exe: Path, impl: str, root: Path | str, names: list[str], cb: int = 0, runs: int = 1) -> list[str]:
    res = subprocess.run([str(exe), impl, str(root), str(cb), str(runs), *names], capture_output=True, env=ENV, timeout=300)
    assert res.returncode == 0, (res.returncode, res.stderr)
    return res.stdout.decode().splitlines()


def counters(line: str, ordered: bool, strict: bool = True) -> str:
    """the comparable part of a result line: item sizes only when no hard link can cross items (thread order), always the sum;
    the dirs / files / bytes counters only when no folder is walked by two threads at once (a shared folder is cached by the first)"""
    f = dict(p.split("=") for p in line.split() if "=" in p)
    sizes = line.split("sizes ")[1].split(" sum=")[0] if ordered else ""
    walked = f"{f['dirs']} {f['files']} {f['bytes']}" if strict else ""
    return f"{sizes}|{f['sum']} {walked} {f['done']} {f['total']} {f['cancel']} {f['phase']} {f['cb']} {f['donecalls']}"


def same(exe: Path, root: Path | str, names: list[str], cb: int = 0, runs: int = 1, ordered: bool = True, strict: bool = True) -> list[str]:
    ref, c = walk(exe, "ref", root, names, cb, runs), walk(exe, "c", root, names, cb, runs)
    assert len(ref) == len(c) == runs
    for r, x in zip(ref, c):
        assert counters(r, ordered, strict) == counters(x, ordered, strict), f"{root} {names} cb={cb}:\nasm {r}\nC   {x}"
    return c


def make_tree(t: Path) -> Path:
    rng = random.Random(31)
    root = t / "tree"
    root.mkdir()
    for d in range(6):
        sub = root / f"d{d}"
        sub.mkdir()
        for i in range(rng.randrange(5, 40)):
            (sub / f"f{i}").write_bytes(b"x" * rng.randrange(0, 20000))
        (sub / "inner").mkdir()
        for i in range(8):
            (sub / "inner" / f"g{i}").write_bytes(b"y" * rng.randrange(0, 9000))
        (sub / "inner" / "deeper").mkdir()
        (sub / "inner" / "deeper" / "h").write_bytes(b"z" * 5000)
        os.symlink("f0", sub / "link")
        os.symlink("../d0", sub / "dirlink")
        os.symlink("missing", sub / "dangling")
    os.mkfifo(root / "d0" / "fifo")
    (root / "empty").mkdir()
    (root / "sparse").mkdir()
    with open(root / "sparse" / "big", "wb") as f:
        f.truncate(50 << 20)
        f.seek(1 << 20)
        f.write(b"data")
    (root / "locked").mkdir()
    (root / "locked" / "secret").write_bytes(b"s" * 4000)
    os.chmod(root / "locked", 0)
    (root / "plainfile").write_bytes(b"p" * 3000)
    return root


def test_trees(exe: Path, t: Path) -> None:
    root = make_tree(t)
    try:
        names = [f"d{i}" for i in range(6)] + ["empty", "sparse", "locked", "plainfile", "does-not-exist"]
        for cb in (0, 1):
            same(exe, root, names, cb=cb)
            same(exe, root, names[:1], cb=cb)
            same(exe, root, names[:3], cb=cb)
            same(exe, root, ["d3", "d3", "d4", "d4"], cb=cb, strict=False)          # a folder listed twice: the cache answers the second walk
        out = same(exe, root, names, cb=1, runs=3)                    # second and third run: subtree cache hits
        assert "dirs=" in out[0]
        print("[PASS] DW1. 6 real folders (symlinks, fifo, sparse, locked, missing, repeated) -- sizes and counters identical to the asm, with and without a callback")
    finally:
        os.chmod(root / "locked", 0o755)


def test_links(exe: Path, t: Path) -> None:
    root = t / "links"
    root.mkdir()
    for d in ("a", "b", "c"):
        (root / d).mkdir()
    (root / "a" / "orig").write_bytes(b"h" * 100000)
    for d in ("a", "b", "c"):
        os.link(root / "a" / "orig", root / d / f"copy_{d}")
    (root / "b" / "solo").write_bytes(b"s" * 5000)
    os.link(root / "b" / "solo", root / "b" / "solo2")                 # both names in one folder
    same(exe, root, ["a", "b", "c"], ordered=False)                    # which folder owns the shared inode depends on thread order
    same(exe, root, ["b"], ordered=True)
    ref = walk(exe, "ref", root, ["a", "b", "c"])[0]
    total_files = int(dict(p.split("=") for p in ref.split() if "=" in p)["files"])
    assert total_files == 2, "the 100000-byte inode counted once across three folders, plus the b/solo inode counted once"
    print("[PASS] DW2. hard links: an inode shared by several folders and names is counted exactly once, identical to the asm")


def test_depth_and_mounts(exe: Path, t: Path) -> None:
    deep = t / "deep"
    cur = deep
    for i in range(72):                                                # deeper than DUP_MAX_DEPTH (64)
        cur.mkdir(parents=True, exist_ok=True)
        (cur / f"f{i}").write_bytes(b"d" * 1500)
        cur = cur / "n"
    same(exe, t, ["deep"])
    same(exe, t, ["deep"], cb=1, runs=2)
    same(exe, "/", ["proc", "sys"])                                    # derived filesystems count as 0
    r = walk(exe, "c", "/", ["proc"])[0]
    assert "sizes 0 " in r and "dirs=0" in r, r
    print("[PASS] DW3. depth cap 64 and derived mounts (/proc, /sys) identical to the asm")


def test_changes(exe: Path, t: Path) -> None:
    root = t / "chg"
    root.mkdir()
    (root / "x").mkdir()
    (root / "x" / "f").write_bytes(b"1" * 9000)
    for impl in ("ref", "c"):
        a = walk(exe, impl, root, ["x"], runs=1)[0]
    (root / "x" / "g").write_bytes(b"2" * 20000)                       # mtime of x changes: a stale cache entry must not be used
    ref, c = walk(exe, "ref", root, ["x"])[0], walk(exe, "c", root, ["x"])[0]
    assert counters(ref, True) == counters(c, True)
    assert counters(a, True) != counters(c, True), "the new file is counted"
    print("[PASS] DW4. a changed folder is walked again, identical to the asm")


def sizes_of(line: str) -> str:
    return line.split("sizes ")[1].split(" dirs=")[0]


def test_cancel(exe: Path, t: Path) -> None:
    root = t / "cancel"
    root.mkdir()
    for d in range(4):
        (root / f"d{d}").mkdir()
        for i in range(1000):
            (root / f"d{d}" / f"f{i}").write_bytes(b"c" * 700)
    names = [f"d{i}" for i in range(4)]
    base = sizes_of(walk(exe, "c", root, names)[0])
    for impl in ("ref", "c"):
        for sel in (names, names[:1]):                                  # even a single folder goes to a worker thread: the UI shows progress
            canc = walk(exe, impl, root, sel, cb=2)[0]
            f = dict(p.split("=") for p in canc.split() if "=" in p)
            assert f["cancel"] == "1" and f["donecalls"] == "1" and f["ticks"] == "1", canc   # the pump ticked while worker threads walked
        first, second = walk(exe, impl, root, names, cb=3, runs=2)
        assert sizes_of(second) == base, f"{impl}: the walk after a canceled one must be complete (no partial subtree cached):\n{first}\n{second}"
    print("[PASS] DW5. progress callback: cancel flag stops the walk, one DONE call, the next walk is complete (no partial cache)")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_trees(exe, t)
        test_links(exe, t)
        test_depth_and_mounts(exe, t)
        test_changes(exe, t)
        test_cancel(exe, t)
    print("ALL C DISK USAGE WALKER TESTS PASSED.")


if __name__ == "__main__":
    main()
