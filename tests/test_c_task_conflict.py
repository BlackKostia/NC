#!/usr/bin/env python3
"""src/fs/task_conflict.c versus the frozen assembly (tests/harness/task_conflict_reference.s): conflict detection and resolution of
the background copy / move (fo_resolve_eexist_open, fo_move_check_conflict, fs_task_resolve_conflict) and the UI side of the
handshake (fs_task_check_conflict, fs_task_reply_conflict).

CF1 differential on identical trees (x86_64), with a forked process playing the UI: the target is the source itself (-9999),
    overwrite (a temp file renamed over a regular target, in place for others), skip (g_copy_had_skip), rename to a free
    "<stem>_<n><ext>" (no extension, dot files, dots in directories, multiple dots, _1 .. _1023 taken -> _x<seq>), answers "for
    all" reused without asking, cancel while waiting, the UI process (always overwrite); moves: missing target, the same inode,
    directories on one device, files; the name and sizes the UI saw, results and trees
CF2 qemu-aarch64: the C module gives the x86_64 results; CF3 mutation check
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/task_conflict.c"
REF = "tests/harness/task_conflict_reference.s"
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
        "src/core/mem_prims.c", "src/fs/file_ops_overwrite.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "task_conflict_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    return H.build(arch, t, ["tests/harness/task_conflict_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DTCF_SRC="{path}"'])


def tree(root: Path, many: bool = False) -> Path:
    for d in ("d1", "d2", "src", "dir.d"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for f, data in (("f.txt", "old f"), ("f_1.txt", "x"), ("f_2.txt", "x"), ("noext", "n"), (".hidden", "h"), ("a.b.c", "abc"),
                    ("dir.d/file", "df"), ("src/s.txt", "source data"), ("src/big", "B" * 5000), ("target", "t")):
        (root / f).write_text(data)
    os.link(root / "src" / "s.txt", root / "hard")
    os.symlink("f.txt", root / "lnk")
    if many:
        fd = os.open(root, os.O_RDONLY)
        try:
            for i in range(1, 1024):
                os.close(os.open(f"m_{i}.dat", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
            os.close(os.open("m.dat", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=fd))
        finally:
            os.close(fd)
    return root


SCRIPTS = {
    "ui": "E f.txt @/src/s.txt\nM @/src/s.txt @/target\n",
    "same": "W 1\nE hard @/src/s.txt\nM @/src/s.txt @/hard\nA o\nM @/d1 @/d2\nM @/src/s.txt @/missing\n",
    "answers": "W 1\nA o s r r r r r\nE f.txt @/src/big\nE target @/src/s.txt\nE f.txt @/src/s.txt\nE noext @/src/s.txt\nE .hidden @/src/s.txt\n"
               "E a.b.c @/src/s.txt\nE dir.d/file @/src/s.txt\n",
    "for_all": "W 1\nA R o\nE f.txt @/src/s.txt\nE f.txt @/src/s.txt\nQ target 1 2\nE d1 @/src/s.txt\n",
    "skip_all": "W 1\nA S\nE f.txt @/src/s.txt\nE target @/src/big\nM @/src/s.txt @/f.txt\n",
    "moves": "W 1\nA o r s\nM @/src/s.txt @/f.txt\nM @/src/big @/target\nM @/d1 @/d2\n",
    "cancel": "W 1\nA c\nE f.txt @/src/s.txt\nQ target 3 4\n",
    "many": "W 1\nA r r\nE m.dat @/src/s.txt\nE m.dat @/src/s.txt\n",
    "many_gap": "W 1\nA r\nE m.dat @/src/s.txt\n",                         # m_1023 free: the last numbered name
    "notdir": "W 1\nA r\nQ f.txt/inner 1 2\n",                             # ENOTDIR on every candidate: all tries used
}


def run(exe: Path, impl: str, base: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl, str(base)], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin"}, timeout=25)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def one(exe: Path, t: Path, tag: str, impl: str, arch: str = "x86_64") -> tuple[str, list]:
    base = tree(t / f"{tag}_{impl}_{arch}", tag.startswith("many"))
    if tag == "many_gap":
        (base / "m_1023.dat").unlink()
    out = run(exe, impl, base, SCRIPTS[tag], arch)
    return out, H.snapshot(base, scrub=None)


def test_differential(exe: Path, t: Path) -> dict[str, tuple[str, list]]:
    got = {}
    for tag in SCRIPTS:
        a, b = one(exe, t, tag, "ref"), one(exe, t, tag, "c")
        assert a[0] == b[0], f"{tag}: oracle and C differ:\n{a[0]}\n{b[0]}"
        assert a[1] == b[1], f"{tag}: the trees differ afterwards"
        got[tag] = b
    text = "".join(o for o, _ in got.values())
    for frag in ("r=-9999", "skip=1", "f_3.txt", "noext_1", ".hidden_1", "a.b_1.c", "dir.d/file_1", "m_x1.dat", "m_1023.dat", "inner_x", "r=-125", "  seen f.txt"):
        assert frag in text, f"coverage: {frag}"
    print(f"[PASS] CF1. conflict handling identical to the asm in {sum(o.count(chr(10)) for o, _ in got.values())} steps with a UI "
          "process (same file, overwrite, skip, unique names incl. _x<seq>, for all, cancel, moves, the UI's view of name and sizes)")
    return got


MUTANTS = [
    ("tries", "#define UNIQUE_TRIES 1088", "#define UNIQUE_TRIES 1024"),
    ("seq names early", "if (n >= 1024) {", "if (n >= 1023) {"),
    ("dot in a directory", "if (*p == '/') dot = nullptr;", "if (false) dot = nullptr;"),
    ("leading dot is an extension", "if (!dot || dot == orig || dot[-1] == '/') dot = p;", "if (!dot) dot = p;"),
    ("unique stops on any error", "if (os_statat(dfd, out, &st, 0) == -ENOENT) return;", "if (os_statat(dfd, out, &st, 0) < 0) return;"),
    ("cancel ignored", "if (__atomic_load_n(&s->cancel, __ATOMIC_ACQUIRE)) return -1;", ""),
    ("UI renames", "if (!s) return CONFLICT_ACT_OVERWRITE;", "if (!s) return CONFLICT_ACT_SKIP;"),
    ("for all ignored", "if (all) g_conflict_all_act = act;", "(void)all;"),
    ("sizes swapped", "s->conflict_src_sz = src_sz;\n        s->conflict_dst_sz = dst_sz;", "s->conflict_src_sz = dst_sz;\n        s->conflict_dst_sz = src_sz;"),
    ("full path shown", "path_basename(dst_rel)", "dst_rel"),
    ("same file overwritten", "if (have && src_st->dev == dst.dev && src_st->ino == dst.ino)", "if (false)"),
    ("skip not flagged", "        g_copy_had_skip = 1;\n", ""),
    ("mode", "uint32_t mode = (src_st->mode & 0777) | 0600;", "uint32_t mode = 0644;"),
    ("move same inode asks", "if (s.dev == d.dev && s.ino == d.ino) return CONFLICT_ACT_OVERWRITE;", ""),
    ("check reports always", "if (!s || __atomic_load_n(&s->conflict_state, __ATOMIC_ACQUIRE) != 1) return 0;", "if (!s) return 0;"),
]


# Not mutated: O_EXCL | O_NOFOLLOW of the renamed target (the unique name was just found free; the flags only guard a race).
def test_mutants(t: Path, expect: dict[str, tuple[str, list]]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "task_conflict.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "task_conflict.c"))
                noticed[name] = any(one(exe, mt, tag, "c") != expect[tag] for tag in SCRIPTS)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] CF3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for tag in SCRIPTS:
                assert one(a64, t, tag, "c", "aarch64") == expect[tag], f"qemu-aarch64 differs in {tag}"
            print("[PASS] CF2. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] CF2: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C TASK CONFLICT TESTS PASSED.")


if __name__ == "__main__":
    main()
