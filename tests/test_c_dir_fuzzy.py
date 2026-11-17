#!/usr/bin/env python3
"""src/fs/dir_fuzzy.c, dir_fuzzy_walk.c and fs_write.c versus the frozen assembly: the scorer on random query/candidate pairs
(case folding, boundary and consecutive bonuses, the 64-bit match mask), the bounded tree collector on real trees (depth cap 8,
.git and dot entries, symlinks, pool and item caps, over-long paths) and the atomic file writer (new / existing / refused targets)."""

import os
import random
import stat
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["dir_fuzzy", "dir_fuzzy_walk"]
CLI_C = ["tests/harness/fuzzy_cli.c", "src/fs/dir_fuzzy.c", "src/fs/dir_fuzzy_walk.c", "src/fs/fs_write.c", "src/core/string.c", "src/core/string_path.c",
         "src/core/string_format.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c",
         "src/core/tmpfile.c", "src/core/hash.c"]
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


def run(exe: Path, *args: str, data: bytes = b"", cwd: str | None = None) -> str:
    res = subprocess.run([str(exe), *args], input=data, capture_output=True, env=ENV, timeout=120, cwd=cwd)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode("utf-8", "replace")


def test_score(exe: Path) -> None:
    rng = random.Random(11)
    alpha = "abcABC/_-. xyzXYZéЖ12"
    lines = []
    for _ in range(30000):
        cand = "".join(rng.choice(alpha) for _ in range(rng.choice([0, 1, 3, 8, 20, 70, 130])))
        if rng.random() < 0.6 and cand:                              # a subsequence of the candidate: mostly matches
            q = "".join(ch for ch in cand if rng.random() < 0.4)
            q = q.swapcase() if rng.random() < 0.3 else q
        else:
            q = "".join(rng.choice(alpha) for _ in range(rng.randrange(0, 6)))
        lines.append(f"{q}\t{cand}\n")
    lines += ["\t\n", "\tabc\n", "a\t\n", "ABC\tabc\n", "abc\tA_B-C\n", "x\t" + "a" * 70 + "x\n"]
    out = run(exe, "score", data="".join(lines).encode()).splitlines()
    assert len(out) == len(lines) and not any("MISMATCH" in o for o in out)
    bad = [(l, o) for l, o in zip(lines, out) if o.split()[:3] != o.split()[3:]]
    assert not bad, bad[:3]
    scores = [int(o.split()[0]) for o in out]
    assert sum(s > 0 for s in scores) > 5000 and sum(s < 0 for s in scores) > 3000, "the generator must produce matches and misses"
    assert any(o.split()[2] == "0" and o.split()[1] != "0" for o in out), "masks with high bits are exercised"
    print(f"[PASS] FZ1. fuzzy_score + match mask identical to the asm on {len(lines)} random pairs")


def make_tree(t: Path, rng: random.Random) -> Path:
    root = t / "tree"
    root.mkdir()
    for n in ("a.txt", "B_c.md", "é.txt", "x y", ".hidden", "Жук.md"):
        (root / n).write_text("x")
    (root / ".git").mkdir()
    (root / ".git" / "config").write_text("x")
    (root / "src").mkdir()
    (root / "src" / ".git").mkdir()
    (root / "src" / ".gitignore").write_text("x")                 # prefix of .git is not .git
    (root / "src" / "mod").mkdir()
    for i in range(6):
        (root / "src" / "mod" / f"f{i}.c").write_text("x")
    os.symlink("src", root / "link_dir")
    os.symlink("a.txt", root / "link_file")
    os.mkfifo(root / "fifo")
    cur = root / "deep"
    for i in range(12):                                           # deeper than FUZZY_MAX_DEPTH (8)
        cur.mkdir()
        (cur / f"d{i}.txt").write_text("x")
        cur = cur / f"n{i}"
    (root / "wide").mkdir()
    for i in range(300):
        (root / "wide" / f"w{i:03d}_{rng.randrange(1000)}.txt").write_text("x")
    (root / "empty").mkdir()
    return root


def collect(exe: Path, root: str, cap: int, mx: int) -> list[str]:
    out = run(exe, "collect", root, str(cap), str(mx)).splitlines()
    assert out[0].startswith("CMP pool=1 items=1 ret="), (root, cap, mx, out[0], out[1:6])
    return out[1:]


def test_collect(exe: Path, t: Path) -> None:
    rng = random.Random(12)
    root = make_tree(t, rng)
    for cap, mx in ((65536, 1000), (65536, 5000), (262144, 5000), (65536, 7), (65536, 1), (65536, 0), (200, 1000), (40, 1000), (1, 1000), (0, 1000), (65536, 300)):
        for r in (str(root), str(root / "src"), str(root / "empty"), str(root / "deep"), str(root / "link_dir"), str(root / "a.txt"), str(t / "missing")):
            got = collect(exe, r, cap, mx)
            if cap >= 65536 and mx >= 1000 and r == str(root):
                paths = [l.split(" ", 2)[2] for l in got]
                assert ".git" not in paths and ".git/config" not in paths and "src/.git" not in paths, "the .git directory is skipped"
                assert "src/.gitignore" in paths and ".hidden" in paths and "link_dir" in paths and "link_dir/mod" not in paths, paths[:20]
                assert "deep/n0/n1/n2/n3/n4/n5/d6.txt" in paths and "deep/n0/n1/n2/n3/n4/n5/n6" in paths and "deep/n0/n1/n2/n3/n4/n5/n6/d7.txt" not in paths, "depth cap 8"
                assert all(l.split(" ")[1] in "01" for l in got)
    print("[PASS] FZ2. dir_fuzzy_collect pool/items/return identical to the asm (depth cap, .git, symlinks, pool and item caps)")


def test_long_paths(exe: Path, t: Path) -> None:
    deep = t / "longroot"
    deep.mkdir()
    cwd = os.getcwd()
    try:
        os.chdir(deep)
        for _ in range(19):
            os.mkdir("d" * 200)
            os.chdir("d" * 200)
        base = os.getcwd()
        for name in ("s" * 200, "s" * 60, "x"):
            os.mkdir(name)
            Path(name, "f.txt").write_text("x")
            Path(name, "g" * 150).write_text("x")
    finally:
        os.chdir(cwd)
    assert len(base) > 3700
    got = collect(exe, base, 65536, 1000)
    assert got, "entries are still collected below the long root"
    for extra in range(0, 400, 37):                               # push the root length across the PATH_MAX join limits
        r = base + "/" + "z" * extra
        collect(exe, r, 65536, 1000)
    print("[PASS] FZ3. over-long roots: dfc_join limits and skipped entries identical to the asm")


def test_write(exe: Path, t: Path) -> None:
    rng = random.Random(13)
    big = bytes(rng.randrange(256) for _ in range(300000))
    for impl_i, impl in enumerate(("ref", "c")):
        d = t / f"w_{impl}"
        d.mkdir()
        results = {}
        (d / "exist.txt").write_text("old")
        os.chmod(d / "exist.txt", 0o640)
        (d / "exe.sh").write_text("old")
        os.chmod(d / "exe.sh", 0o755)
        os.symlink("exist.txt", d / "link")
        (d / "sub").mkdir()
        os.mkfifo(d / "fifo")
        cases = [("new.txt", b"hello"), ("exist.txt", b"replaced"), ("exe.sh", big), ("empty.bin", b""), ("link", b"x"), ("sub", b"x"), ("fifo", b"x"),
                 ("no/such/dir/f", b"x"), ("n" * 250, b"long")]
        for name, data in cases:
            r = run(exe, "write", impl, str(d / name), data=data).strip()
            p = d / name
            info = None
            if p.is_file() and not p.is_symlink():
                info = (p.read_bytes() == data, stat.S_IMODE(p.stat().st_mode) if name in ("exist.txt", "exe.sh") else 0)
            results[name] = (r, info)
        assert not [f for f in os.listdir(d) if ".tmp." in f], f"{impl}: temp files left behind"
        assert (d / "link").is_symlink() and (d / "exist.txt").read_text() in ("old", "replaced")
        if impl_i == 0:
            first = results
        else:
            assert results == first, (first, results)
    assert first["new.txt"] == ("0", (True, 0)) and first["exist.txt"] == ("0", (True, 0o640)) and first["exe.sh"][1] == (True, 0o755), first
    assert first["link"][0] == "-1" and first["sub"][0] == "-1" and first["fifo"][0] == "-1" and first["no/such/dir/f"][0] == "-1", first
    print("[PASS] FZ4. fs_write_file: new/existing/mode-preserving writes and refused targets identical to the asm, no .tmp left")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_score(exe)
        test_collect(exe, t)
        test_long_paths(exe, t)
        test_write(exe, t)
    print("ALL C DIR FUZZY TESTS PASSED.")


if __name__ == "__main__":
    main()
