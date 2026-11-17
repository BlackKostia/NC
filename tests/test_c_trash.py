#!/usr/bin/env python3
"""src/fs/trash_info.c, trash_dirs.c and trash_undo.c versus the frozen assembly. One implementation runs a script per process in
its own, identically built directory tree; the printed results and the final tree (names, types, modes, contents with the
deletion date masked) must be identical: .trashinfo escaping of random bytes, data-home lookup for every environment, trash
directory creation, free-name search up to the 998-name limit, moving to the trash (plain, other-filesystem, failing copy / delete
/ rename) and the 16-deep undo stack (conflicts, shifting, restore across filesystems)."""

import os
import random
import re
import stat
import subprocess
import time
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["trash_info", "trash_undo", "trash_undo_ops"]
CLI_C = ["tests/harness/trash_cli.c", "src/fs/trash_info.c", "src/fs/trash_dirs.c", "src/fs/trash_undo.c", "src/core/string.c", "src/core/string_path.c",
         "src/core/string_format.c", "src/core/string_datetime.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
         "src/core/mem_prims.c", "src/core/tmpfile.c", "src/core/hash.c"]
DATE = re.compile(rb"DeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d")


def build(t: Path) -> Path:
    objs = []
    for m in REFS:
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    return H.build("x86_64", t, CLI_C, objs)


def snapshot(root: Path) -> list[tuple]:
    snap = []
    for p in sorted(root.rglob("*")):
        rel = str(p.relative_to(root))
        st = p.lstat()
        if p.is_symlink():
            snap.append((rel, "l", os.readlink(p)))
        elif p.is_dir():
            snap.append((rel, "d", oct(st.st_mode & 0o7777)))
        elif not stat.S_ISREG(st.st_mode):                             # a fifo must never be opened: it would block
            snap.append((rel, "s", oct(st.st_mode)))
        else:
            data = DATE.sub(b"DeletionDate=<date>", p.read_bytes()).replace(str(root).encode(), b"@")
            snap.append((rel, "f", oct(st.st_mode & 0o7777), data))
    return snap


def run_one(exe: Path, impl: str, root: Path, script: str) -> tuple[list[str], list[tuple]]:
    res = subprocess.run([str(exe), impl], input=script.replace("@", str(root)).encode(), capture_output=True, timeout=120, env={"PATH": os.environ.get("PATH", "")})
    assert res.returncode == 0, res.stderr
    return res.stdout.decode("utf-8", "replace").replace(str(root), "@").splitlines(), snapshot(root)


def same(exe: Path, t: Path, name: str, setup, script: str) -> list[str]:
    """setup(root) builds the starting tree; both implementations run `script` ('@' = tree root) and must agree"""
    results = []
    for impl in ("ref", "c"):
        root = t / f"{name}_{impl}"
        root.mkdir()
        setup(root)
        results.append(run_one(exe, impl, root, script))
    (ro, rs), (co, cs) = results
    assert ro == co, f"{name}: results differ\n" + "\n".join(f"{a!r:60} | {b!r}" for a, b in zip(ro, co) if a != b)[:2500]
    assert rs == cs, f"{name}: trees differ\n{[x for x in rs if x not in cs][:3]}\n{[x for x in cs if x not in rs][:3]}"
    return co


def test_info(exe: Path, t: Path) -> None:
    rng = random.Random(51)
    lines = []
    for i in range(300):
        n = rng.choice([0, 1, 5, 40, 300, 1000])
        raw = bytes(rng.randrange(1, 256) for _ in range(n))
        lines.append(f"I\t@/info/f{i}.trashinfo\t{raw.hex()}")
    for n in (4093, 4094, 4095, 4096, 5000):                           # PATH_MAX - 1 = 4095: the longest path is 4094 bytes
        lines.append(f"I\t@/info/long{n}.trashinfo\t{(b'/a' * n)[:n].hex()}")
    lines += [f"I\t@/info/f0.trashinfo\t{b'/again/over/existing'.hex()}",           # replaces an existing file
              f"I\t@/missing-dir/x.trashinfo\t{b'/x'.hex()}",
              f"I\t@/info/{'n' * 250}.trashinfo\t{b'/x'.hex()}",
              f"I\t@/info/{'n' * 300}.trashinfo\t{b'/x'.hex()}"]
    out = same(exe, t, "info", lambda r: (r / "info").mkdir(), "\n".join(lines) + "\n")
    assert out[300:305] == ["0", "0", "-36", "-36", "-36"], out[300:305]
    root = t / "info_c"
    body = (root / "info/f5.trashinfo").read_bytes() if (root / "info/f5.trashinfo").exists() else b""
    sample = (root / "info" / "f1.trashinfo").read_bytes()
    assert sample.startswith(b"[Trash Info]\nPath=") and sample.endswith(b"\n") and DATE.search(sample), sample
    stamp = re.search(rb"DeletionDate=(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)", sample).groups()
    import calendar
    when = calendar.timegm(tuple(int(x) for x in stamp) + (0, 0, 0))
    assert abs(when - time.time()) < 120, "the deletion date is the current UTC time"
    assert body is not None
    print(f"[PASS] TR1. .trashinfo content for {len(lines)} paths (random bytes, 4093..5000 bytes, replace, bad directory) identical to the asm")


def test_home(exe: Path, t: Path) -> None:
    lines = []
    for cap in (4096, 64, 20, 14, 5, 1):
        for xdg in ("-", "", "/x/y z", "/" + "d" * 40):
            for home in ("-", "", "/home/u", "/" + "h" * 40):
                lines.append(f"H\t{cap}\t{xdg}\t{home}\t")
        lines.append(f"H\t{cap}\t-\t-\tnoenv")
    out = same(exe, t, "home", lambda r: None, "\n".join(lines) + "\n")
    assert "[/x/y z] guard=127" in out and "[/home/u/.local/share] guard=127" in out and "[/tmp] guard=127" in out, out[:30]
    assert not [o for o in out if not o.endswith("guard=127")], "no byte is written beyond the capacity"
    print(f"[PASS] TR2. data-home lookup (XDG_DATA_HOME / HOME / fallback, empty values, caps 1..4096) identical to the asm")


def test_dirs(exe: Path, t: Path) -> None:
    def setup(r: Path) -> None:
        (r / "have").mkdir()
        (r / "have/Trash").mkdir()
        (r / "plainfile").write_text("x")
    lines = ["D\t@/new", "D\t@/have", "D\t@/a/b/c", "D\t@/plainfile", "D\t@/plainfile/sub", "D\t@/have", "D\t@/new"]
    same(exe, t, "dirs", setup, "\n".join(lines) + "\n")
    print("[PASS] TR3. Trash/{files,info} creation (existing, missing parent, below a file) identical to the asm")


def test_pick(exe: Path, t: Path) -> None:
    def setup(r: Path) -> None:
        files = r / "dh/Trash/files"
        files.mkdir(parents=True)
        (r / "dh/Trash/info").mkdir()
        for n in ["a"] + [f"a.{i}" for i in range(2, 999)]:
            (files / n).write_text("")
        for n in ["b"] + [f"b.{i}" for i in range(2, 998)]:
            (files / n).write_text("")
        (files / "c").write_text("")
        (files / "c.2").write_text("")
        (files / "c.4").write_text("")
        (files / ("L" * 255)).write_text("")
    names = ["a", "b", "c", "d", "L" * 255, "L" * 254, "é ж", "sp ace", "dot.", "..", ".", "", "n" * 300, "x" * 4000]
    lines = [f"Q\t@/dh\t{n.encode().hex()}" for n in names] + ["Q\t@/nodata\t" + b"z".hex()]
    out = same(exe, t, "pick", setup, "\n".join(lines) + "\n")
    assert out[0].startswith("-17 ") and out[1].split()[0] == "0" and out[1].split()[1].endswith("/b.998"), out[:2]
    assert out[2].split()[1].endswith("/c.3"), out[2]
    print("[PASS] TR4. free-name search (suffixes .2 ... .998, exhaustion -EEXIST, long and odd names) identical to the asm")


def trash_tree(r: Path) -> None:
    (r / "data").mkdir()
    (r / "w").mkdir()
    for n in ("a.txt", "b.txt", "c.txt", "é.txt", "sp ace.txt", "d%1.txt"):
        (r / "w" / n).write_text(f"content of {n}")
    os.chmod(r / "w/b.txt", 0o755)
    (r / "w/dir").mkdir()
    (r / "w/dir/inner").write_text("inner")
    os.symlink("a.txt", r / "w/link")
    os.mkfifo(r / "w/fifo")


def test_trash_undo(exe: Path, t: Path) -> None:
    env = "E\tXDG_DATA_HOME=@/data\n"
    scenarios = {
        "plain": ["T\t@/w/a.txt", "T\t@/w/b.txt", "T\t@/w/dir", "T\t@/w/link", "U", "U", "T\t@/w/c.txt", "U", "U", "U", "U", "U"],
        "names": ["T\t@/w/é.txt", "T\t@/w/sp ace.txt", "T\t@/w/d%1.txt", "T\t@/w/nothing", "U", "U", "U"],
        "again": ["T\t@/w/a.txt", "P\t3\t@/w/a.txt\t@/data/Trash/files/a.txt\t@/data/Trash/info/a.txt.trashinfo"] + ["U"] * 3,   # a stale duplicate entry
        "conflict": ["T\t@/w/a.txt", "T\t@/w/c.txt", "W\t@/w/c.txt", "U", "U", "R\t@/w/c.txt", "U", "U"],
        "exdev": ["M\trename\t-18", "T\t@/w/a.txt", "T\t@/w/dir", "T\t@/w/fifo", "U", "U", "U", "M\trename\t0"],
        "exdev_copyfail": ["M\trename\t-18", "M\tcopy\t-5", "T\t@/w/a.txt", "M\tcopy\t0", "T\t@/w/a.txt", "U"],
        "exdev_delfail": ["M\trename\t-18", "M\tdelete\t-13", "T\t@/w/a.txt", "T\t@/w/b.txt", "M\tdelete\t0", "U", "U"],
        "rename_err": ["M\trename\t-13", "T\t@/w/a.txt", "M\trename\t-2", "T\t@/w/b.txt", "M\trename\t0", "T\t@/w/b.txt"],
        "undo_exdev": ["T\t@/w/a.txt", "T\t@/w/b.txt", "T\t@/w/c.txt", "M\trename\t-18", "U", "W\t@/w/b.txt", "U", "M\tdelete\t-13", "R\t@/w/b.txt", "U", "M\trename\t-13", "U", "M\trename\t0", "U"],
        "undo_other": ["T\t@/w/a.txt", "M\trename\t-13", "U", "U", "M\trename\t0"],
        "kinds": ["W\t@/w/n1", "W\t@/w/info1", "P\t2\t@/w/o1\t@/w/n1\t@/w/info1", "U", "W\t@/w/n2", "W\t@/w/info2", "P\t3\t@/w/o2\t@/w/n2\t@/w/info2", "U",
                  "W\t@/w/n3", "P\t3\t@/w/o3\t@/w/n3\t-", "U"],             # only a trash entry removes its .trashinfo
        "rename_undo": ["P\t1\t@/w/a.txt\t@/w/renamed\t-", "V\t@/w/a.txt\t@/w/renamed", "U", "U"],
    }
    for name, steps in scenarios.items():
        same(exe, t, name, trash_tree, env + "\n".join(steps) + "\n")
    # more than 16 undo entries: the oldest fall off the stack, the rest come back in reverse order
    lines = [f"P\t1\t@/w/o{i}\t@/w/n{i}\t-" for i in range(20)] + ["U"] * 18

    def many(r: Path) -> None:
        (r / "w").mkdir()
        for i in range(20):
            (r / "w" / f"n{i}").write_text(str(i))
    out = same(exe, t, "stack", many, "\n".join(lines) + "\n")
    assert out[20:36] == ["1"] * 16 and out[36:] == ["0", "0"], out[20:]
    print(f"[PASS] TR5. trash + undo ({len(scenarios)} scenarios: conflicts, other filesystem, failing copy / delete / rename, 20-entry stack) identical to the asm")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_info(exe, t)
        test_home(exe, t)
        test_dirs(exe, t)
        test_pick(exe, t)
        test_trash_undo(exe, t)
    print("ALL C TRASH TESTS PASSED.")


if __name__ == "__main__":
    main()
