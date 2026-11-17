#!/usr/bin/env python3
"""src/fs/disk_usage.c versus the frozen assembly on real DirModels (linked with the actual directory model objects): the
size-sorted Disk Usage view of folders, files, hard-linked names and >64 folders (batch flushes), a second run answered by the
subtree cache, a run after the tree changed, and a canceled walk (back to the plain name-sorted listing)."""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    subprocess.run(["make", "-s", "-j8"], cwd=ROOT, check=True, capture_output=True)
    refs = []
    for m in ("disk_usage", "du_parallel"):
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        refs.append(o)
    H.rename_defined_globals(refs, "ref_")
    cli = t / "du_pop_cli.o"
    cflags = [f for f in H.COMMON if f not in ("-Os",)] + ["-Os", "-fno-stack-clash-protection"]
    subprocess.run(["gcc", *cflags, "-c", str(ROOT / "tests/harness/du_pop_cli.c"), "-o", str(cli)], check=True)
    start = t / "pal_start.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "src/os/linux/x86_64/pal_start.s"), "-o", str(start)], check=True)
    objs = sorted(str(p) for p in (ROOT / "build").rglob("*.o") if p.name not in ("main.o", "pal_start.o"))
    exe = t / "dupop"
    res = subprocess.run(["ld", "-z", "noexecstack", "--gc-sections", str(start), str(cli), *map(str, refs), *objs, "-o", str(exe)], capture_output=True, text=True)
    assert res.returncode == 0, res.stderr[-1500:]
    return exe


def dump(exe: Path, impl: str, d: Path | str, runs: int = 1, cancel: bool = False) -> list[str]:
    res = subprocess.run([str(exe), impl, str(d), str(runs), *(["cancel"] if cancel else [])], capture_output=True, env=ENV, timeout=300, cwd=str(ROOT))
    assert res.returncode == 0, (res.returncode, res.stderr)
    return res.stdout.decode("utf-8", "replace").split(("REF" if impl == "ref" else "C") + " ret=")[1:]


def same(exe: Path, d: Path | str, runs: int = 1, cancel: bool = False) -> str:
    a, b = dump(exe, "ref", d, runs, cancel), dump(exe, "c", d, runs, cancel)
    assert len(a) == len(b) == runs
    for x, y in zip(a, b):
        assert x == y, f"{d}: asm and C views differ\n--- asm\n{x[:1500]}\n--- C\n{y[:1500]}"
    return b[-1]


def make_tree(t: Path) -> Path:
    rng = random.Random(41)
    root = t / "pop"
    root.mkdir()
    for d in range(130):                                              # two full batches of 64 plus a remainder
        sub = root / f"dir{d:03d}"
        sub.mkdir()
        for i in range(rng.randrange(0, 6)):
            (sub / f"f{i}").write_bytes(b"x" * rng.randrange(0, 30000))
        if d % 9 == 0:
            (sub / "nested").mkdir()
            (sub / "nested" / "n").write_bytes(b"n" * 8000)
    for i in range(20):
        (root / f"file{i:02d}.bin").write_bytes(b"f" * rng.randrange(0, 50000))
    os.link(root / "file00.bin", root / "hard_a")
    os.link(root / "file00.bin", root / "hard_b")
    (root / "pair_a").write_bytes(b"p" * 7000)
    os.link(root / "pair_a", root / "pair_b")                          # st_nlink == 2: the smallest shared inode
    os.symlink("dir000", root / "link_dir")
    os.symlink("missing", root / "dangling")
    with open(root / "sparse", "wb") as f:
        f.truncate(30 << 20)
    (root / ".hidden").mkdir()
    (root / ".hidden" / "h").write_bytes(b"h" * 1234)
    return root


def test_views(exe: Path, t: Path) -> None:
    root = make_tree(t)
    out = same(exe, root, runs=3)                                     # run 2 and 3: cache hits for every folder
    assert "du_mode=1" in out.split("\n")[0] and "sort=1 desc=1" in out.split("\n")[0], out.split("\n")[0]
    for sub in (root / "dir001", root / "dir000", root / ".hidden"):
        same(exe, sub, runs=2)
    empty = t / "empty"
    empty.mkdir()
    same(exe, empty)
    same(exe, t / "missing-dir")                                      # the folder cannot be opened / listed
    print("[PASS] DP1. Disk Usage views (130 folders in batches, hard-linked names, sparse file, links, cache re-runs) identical to the asm")


def test_changed(exe: Path, t: Path) -> None:
    root = t / "chg"
    root.mkdir()
    for d in range(70):
        (root / f"d{d}").mkdir()
        (root / f"d{d}" / "f").write_bytes(b"1" * 5000)
    first = same(exe, root)
    (root / "d3" / "g").write_bytes(b"2" * 100000)
    second = same(exe, root)
    assert first != second
    print("[PASS] DP2. after a change the touched folder is measured again, identical to the asm")


def test_cancel(exe: Path, t: Path) -> None:
    root = t / "cancel"
    root.mkdir()
    for d in range(4):
        (root / f"d{d}").mkdir()
        for i in range(1000):
            (root / f"d{d}" / f"f{i}").write_bytes(b"c" * 700)
    out = same(exe, root, cancel=True)
    head = out.split("\n")[0]
    assert head.startswith("0 ") and "du_mode=0" in head and "sort=0 desc=0" in head, head
    print("[PASS] DP3. a canceled walk leaves the plain name-sorted listing, identical to the asm")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_views(exe, t)
        test_changed(exe, t)
        test_cancel(exe, t)
    print("ALL C DISK USAGE POPULATE TESTS PASSED.")


if __name__ == "__main__":
    main()
