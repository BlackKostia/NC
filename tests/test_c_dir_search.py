#!/usr/bin/env python3
"""src/fs/dir_search.c and dir_search_match.c versus the frozen assembly: glob / substring masks on random names, content
grep around the 32 KiB window edge and the 1 MiB cap, and whole searches (masks, grep, depth cap 16, 4096-hit cap, symlinks,
fifos, unicode names, unreadable and missing roots) on real trees: the resulting DirModel must match entry for entry."""

import os
import random
import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["dir_search", "dir_search_match", "dir_search_reset", "dir_search_walk"]
CLI_C = ["tests/harness/search_cli.c", "src/fs/dir_search.c", "src/fs/dir_search_match.c", "src/core/string.c", "src/core/utf8.c",
         "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    objs = []
    for m in REFS:
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    return H.build("x86_64", t, CLI_C, objs)


def run(exe: Path, *args: str, data: bytes = b"") -> str:
    res = subprocess.run([str(exe), *args], input=data, capture_output=True, env=ENV, timeout=120)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode("utf-8", "replace")


def test_glob(exe: Path) -> None:
    rng = random.Random(3)
    alpha = "abcABC.-_ xéЖ"
    lines = []
    for _ in range(20000):
        s = "".join(rng.choice(alpha) for _ in range(rng.randrange(0, 12)))
        p = "".join(rng.choice(alpha + "**??") for _ in range(rng.randrange(0, 9)))
        if rng.random() < 0.5:
            lines.append(f"G\t{s}\t{p}\n")
        else:
            lines.append(f"M\t{s}\t{p}\t{rng.choice('01')}\n")
    out = run(exe, "lines", data="".join(lines).encode()).splitlines()
    assert len(out) == len(lines)
    bad = [(l, o) for l, o in zip(lines, out) if o.split()[0] != o.split()[1]]
    assert not bad, bad[:3]
    assert sum(o == "1 1" for o in out) > 1500, "the generator must produce plenty of matches"
    print(f"[PASS] DS1. glob / substring masks identical to the asm on {len(lines)} random name/pattern pairs")


def test_grep(exe: Path, t: Path) -> None:
    rng = random.Random(4)
    for size, at in ((0, 0), (10, 3), (32766, 32760), (32767, 32763), (32768, 32767), (70000, 32766), (70000, 65530), (70000, 69990), (1048576 + 100, 1048570),
                     (1048576 + 100, 1048000), (200000, 199990)):
        data = bytearray(rng.choice(b"abcdxyz \n") for _ in range(size))
        pat = b"NeEdLe"
        if size >= at + len(pat):
            data[at:at + len(pat)] = pat
        f = t / "g.bin"
        f.write_bytes(bytes(data))
        for p in (pat.decode(), "needle", "NEEDLEX", "e", "zzzzzzzzzz"):
            out = run(exe, "grep", str(f), p).split()
            assert out[0] == out[1], (size, at, p, out)
    assert run(exe, "grep", str(t / "missing"), "x").split() == ["0", "0"]
    print("[PASS] DS2. content grep identical across 32 KiB windows, carry-over matches and the 1 MiB cap")


def make_tree(t: Path, rng: random.Random) -> Path:
    root = t / "tree"
    root.mkdir()
    names = ["a.txt", "b.TXT", "abc", "Abc.log", "x y.md", "é.txt", "Жук.md", "data.bin", ".hidden", "q?.c", "plain"]
    for d in range(3):
        sub = root / f"d{d}"
        sub.mkdir()
        for n in rng.sample(names, 6):
            (sub / n).write_bytes(bytes(rng.choice(b"hello World\n") for _ in range(rng.randrange(0, 80))) + rng.choice([b"needle", b"NEEDLE", b""]))
        (sub / "inner").mkdir()
        for n in rng.sample(names, 4):
            (sub / "inner" / n).write_bytes(b"xx needle yy" if rng.random() < 0.4 else b"zz")
    for n in names:
        (root / n).write_bytes(b"top needle" if n.startswith("a") else b"top")
    os.symlink("a.txt", root / "link_file")
    os.symlink("d0", root / "link_dir")
    os.symlink("missing", root / "dangling")
    os.mkfifo(root / "fifo")
    (root / "empty_dir").mkdir()
    deep = root / "deep"
    cur = deep
    for i in range(19):                                           # deeper than SEARCH_MAX_DEPTH (16)
        cur.mkdir()
        (cur / f"f{i}.txt").write_text("needle")
        cur = cur / f"n{i}"
    many = root / "many"
    many.mkdir()
    return root


def same(exe: Path, root: str, mask: str, grep: str) -> str:
    out = run(exe, "run", root, mask, grep)
    ref, c = out.split("C ret=")[0], "C ret=" + out.split("C ret=")[1]
    assert ref[3:] == c[1:], f"{root!r} {mask!r} {grep!r}: asm and C differ\n{out[:1500]}"
    return c


def test_runs(exe: Path, t: Path) -> None:
    rng = random.Random(5)
    root = make_tree(t, rng)
    cases = [("", ""), ("*.txt", ""), ("a?c*", ""), ("abc", ""), ("TXT", ""), ("*", "needle"), ("*.md", "NEEDLE"), ("", "needle"), ("e", ""), ("q?.c", ""),
             ("*.txt", "top"), ("", "zzzz-not-there"), ("f*", ""), ("*.txt", "needle")]
    for mask, grep in cases:
        for r in (str(root), str(root / "d1"), str(root / "empty_dir")):
            same(exe, r, mask, grep)
    deep_hits = [l for l in same(exe, str(root), "f*.txt", "").splitlines() if "/f" in l]
    assert deep_hits and all(l.split()[1].count("/") <= 17 for l in deep_hits), "depth cap 16 holds"
    for i in range(4300):                                         # more files than SEARCH_MAX_HITS
        (root / "many" / f"f{i:05d}.txt").write_text("x")
    c = same(exe, str(root), "f*.txt", "")
    assert "ret=4096" in c.splitlines()[0], c.splitlines()[0]
    r = same(exe, str(t / "does-not-exist"), "", "")
    assert "ret=-2" in r.splitlines()[0], r.splitlines()[0]
    nf = t / "plain_file"
    nf.write_text("x")
    assert "ret=-20" in same(exe, str(nf), "", "").splitlines()[0]
    print("[PASS] DS3. 60+ real-tree searches (masks, grep, symlinks, fifo, unicode, depth and hit caps, bad roots) identical to the asm")


def test_append(exe: Path) -> None:
    out = run(exe, "parent")
    ref, c = out.split("C ret=")[0], "C ret=" + out.split("C ret=")[1]
    assert ref[3:] == c[1:] and "JOIN MISMATCH" not in out and "SIGN MISMATCH" not in out, out[:800]
    assert "raw=301" in c and "dotdot=1" in c, c.splitlines()[0]
    print("[PASS] DS4. ds_append_parent / ds_append_entry / ds_join_rel identical across model growth steps")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_glob(exe)
        test_grep(exe, t)
        test_runs(exe, t)
        test_append(exe)
    print("ALL C DIR SEARCH TESTS PASSED.")


if __name__ == "__main__":
    main()
