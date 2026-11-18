#!/usr/bin/env python3
"""src/fs/file_ops_delete.c versus the frozen assembly (tests/harness/file_ops_delete_reference.s): fs_delete_recursive,
fs_move_recursive and fs_read_file_head.

FD1 differential on two identical trees (x86_64): deleting files, symlinks (to files and to directories: the link goes, the target
    stays), empty / nested / directories 512 levels deep (exactly MAX_DIR_DEPTH), an unreadable or undeletable sub-directory (EACCES), a
    missing path, cancel requests at every poll in the background worker; moves by rename, every conflict policy of the worker
    (overwrite, skip, rename, error), and across file systems (renameat2 -> EXDEV under seccomp): copy + delete, a copy that
    skipped an item keeps its source, the delete step neither cancels nor counts; reading file heads (0 .. 64 KiB, a FIFO,
    a directory, a missing file, no out pointer); results, counters and the trees afterwards
FD2 qemu-aarch64: the C module gives the x86_64 results (without the seccomp scenarios); FD3 mutation check
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/file_ops_delete.c"
REF = "tests/harness/file_ops_delete_reference.s"
MODS = ["src/fs/file_ops.c", "src/fs/file_ops_copy.c", "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c", "build/i18n_en.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "file_ops_delete_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    stub = t / "i18n_stub.c"
    stub.write_text('#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n')
    return H.build(arch, t, ["tests/harness/file_ops_delete_cli.c", *MODS, str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DFOD_SRC="{path}"'])


def tree(root: Path, deep: int = 0) -> Path:
    for d in ("t/a/b/c", "t/e", "m/sub", "keep", "locked/inner", "exist"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for f, size in (("t/f1", 10), ("t/a/f2", 3000), ("t/a/b/c/f3", 0), ("m/x", 5), ("m/sub/y", 7), ("keep/k", 1), ("big", 70000),
                    ("locked/inner/z", 2), ("exist/x", 9), ("small", 3)):
        (root / f).write_bytes(bytes((i * 7 + len(f)) & 255 for i in range(size)))
    os.symlink("../keep", root / "t" / "l_dir")
    os.symlink("../keep/k", root / "t" / "l_file")
    os.symlink("nowhere", root / "t" / "l_dangling")
    os.symlink("keep", root / "lnk_top")
    os.mkfifo(root / "fifo")
    (root / "locked" / "inner").chmod(0o500)                             # its entries cannot be removed
    if deep:
        p = root / "deep"
        for _ in range(deep):
            p = p / "d"
        p.mkdir(parents=True)
        (p / "leaf").write_text("x")
    return root


def unlock(root: Path) -> None:
    for p in root.rglob("inner"):
        p.chmod(0o755)


SCRIPTS = {
    "delete": "D @/small\nD @/lnk_top\nD @/t\nD @/missing\nD @/locked\nD @/keep\nD @/fifo\n",
    "deep": "D @/deep\n",
    "cancel": "W 1\n" + "".join(f"C {k}\nD @/t\n" for k in (1, 2, 4)) + "C 0\nD @/t\n",
    "move": "M @/small @/small2\nM @/m @/m2\nM @/missing @/z\nW 1\nP s\nM @/keep @/exist\nP r\nM @/keep @/exist\nP e\nM @/m2 @/q\nP o\nM @/small2 @/exist/x\n",
    "head": "H @/big 0\nH @/big 100\nH @/big 65536\nH @/big 69999\nH @/small 100\nH @/fifo 10\nH @/t 10\nH @/missing 10\nH @/big 50 n\n",
}
SECCOMP = {
    "xdev": "S 316 18\nM @/small @/x_small\nM @/m @/x_m\nK s\nM @/t @/exist\nK o\nW 1\nC 2\nM @/keep @/x_keep\nC 3\nM @/keep @/x_keep3\n"
            "C 1\nM @/exist @/x_exist\nC 0\nM @/missing @/x_q\n",
    "xdev_skip": "S 316 18\nK s\nM @/m @/exist\nM @/small @/exist/x\n",
}


def run(exe: Path, impl: str, base: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl, str(base)], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin"}, timeout=20)   # a mutant that blocks on the FIFO hangs
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def one(exe: Path, t: Path, tag: str, impl: str, arch: str = "x86_64") -> tuple[str, list]:
    base = tree(t / f"{tag}_{impl}_{arch}", 512 if tag == "deep" else 0)   # the innermost directory sits exactly at the limit
    out = run(exe, impl, base, {**SCRIPTS, **SECCOMP}[tag], arch)
    unlock(base)
    snap = H.snapshot(base)
    return out, [e for e in snap if not e[0].startswith("deep/")] + [("deep_entries", sum(1 for e in snap if e[0].startswith("deep/")))]


def test_differential(exe: Path, t: Path) -> dict[str, tuple[str, list]]:
    got = {}
    for tag in {**SCRIPTS, **SECCOMP}:
        a, b = one(exe, t, tag, "ref"), one(exe, t, tag, "c")
        assert a[0] == b[0], f"{tag}: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a[0].splitlines(), b[0].splitlines()) if x != y)
        assert a[1] == b[1], f"{tag}: the trees differ afterwards"
        got[tag] = b
    text = "".join(o for o, _ in got.values())
    assert all(got[k][0].startswith("S 0 0\n") for k in SECCOMP), "the seccomp filters are installed"
    for code in ("r=-36", "r=-125", "r=-13", "r=-2", "r=-5", "r=0", "skip=1"):
        assert code in text, f"coverage: {code}"
    print(f"[PASS] FD1. delete / move / read-head identical to the asm in {sum(o.count(chr(10)) for o, _ in got.values())} calls on "
          "identical trees (symlinks not followed, 512 levels, EACCES, cancel, conflict policies, EXDEV copy + delete, heads)")
    return got


MUTANTS = [
    ("depth", "#define MAX_DIR_DEPTH 512", "#define MAX_DIR_DEPTH 513"),
    ("cancel ignored", "r = fs_progress_cancelled() ? -ECANCELED : ddf_entry(dfd, name, type, depth);", "r = ddf_entry(dfd, name, type, depth);"),
    ("error ignored", "        if (r < 0) return r;\n        r = os_unlinkat(dfd, name, AT_REMOVEDIR);", "        r = os_unlinkat(dfd, name, AT_REMOVEDIR);"),
    ("entry not counted", "    fs_progress_begin(name);\n    fs_progress_item();\n    return 0;", "    fs_progress_begin(name);\n    return 0;"),
    ("top not counted", "    if (r < 0) return r;\n    fs_progress_item();\n    return 0;\n}\n\n/* Moves", "    if (r < 0) return r;\n    return 0;\n}\n\n/* Moves"),
    ("rmdir kept", "        r = os_unlinkat(AT_FDCWD, path, AT_REMOVEDIR);", "        r = 0;"),
    ("skip moves", "        if ((int)act == CONFLICT_ACT_SKIP) {", "        if (false) {"),
    ("rename ignored", "if ((int)act == CONFLICT_ACT_RENAME) dst = renamed;", ""),
    ("no copy fallback", "    if (r != -EXDEV) return r;", "    return r;"),
    ("skip deletes source", "if (r < 0 || g_copy_had_skip) return r;", "if (r < 0) return r;"),
    ("delete cancelable", "    g_fs_progress = nullptr;\n", ""),
    ("head blocks", "O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);\n    if (fd < 0) return fd;\n    size_t got", "O_RDONLY | O_CLOEXEC, 0);\n    if (fd < 0) return fd;\n    size_t got"),
]


# Not mutated (equivalent here): O_NOFOLLOW on a sub-directory open (d_type already says DT_DIR; it guards against a symlink
# swapped in meanwhile) and "got <= max_bytes" in the head loop (a read of 0 bytes ends it the same way).
def test_mutants(t: Path, expect: dict[str, tuple[str, list]]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "file_ops_delete.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "file_ops_delete.c"))
                noticed[name] = any(one(exe, mt, tag, "c") != expect[tag] for tag in {**SCRIPTS, **SECCOMP})
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] FD3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        try:
            exe = build("x86_64", t / "x86")
            expect = test_differential(exe, t)
            if H.available("aarch64"):
                a64 = build("aarch64", t / "a64")
                for tag in SCRIPTS:
                    assert one(a64, t, tag, "c", "aarch64") == expect[tag], f"qemu-aarch64 differs in {tag}"
                print("[PASS] FD2. qemu-aarch64: the C module gives the x86_64 results")
            else:
                print("[SKIP] FD2: aarch64 toolchain/qemu not installed")
            test_mutants(t, expect)
        finally:
            for p in t.rglob("inner"):
                p.chmod(0o755)
    print("ALL C FILE OPS DELETE TESTS PASSED.")


if __name__ == "__main__":
    main()
