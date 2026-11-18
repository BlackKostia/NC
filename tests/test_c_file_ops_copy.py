#!/usr/bin/env python3
"""src/fs/file_ops_copy.c versus the frozen assembly (tests/harness/file_ops_copy_reference.s + file_ops_copy_at_reference.s): the
recursive copy engine (copy_reg_at, copy_dir_fd, copy_subdir, fs_copy_file, fs_copy_recursive).

FC1 differential on two identical trees (x86_64): files of several sizes and modes, nested directories, symlinks to files /
    directories / nowhere, a FIFO and a socket (refused in the UI process), hard links (the same inode as the target), a tree 600
    levels deep (MAX_DIR_DEPTH = 512), an unreadable sub-directory, a directory copied into itself, into its own sub-directory
    (the destination root is never descended into) and onto an existing directory (merge), every conflict policy for existing
    files (skip, same file, crash-safe overwrite through a temp file, in place, error), cancel requests at every poll; the result,
    the items / bytes / begins reported and the trees afterwards (every partial target of a failed or canceled copy removed)
FC2 qemu-aarch64: the C module gives the x86_64 results; FC3 mutation check
"""

import os
import socket
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/file_ops_copy.c"
REFS = ["tests/harness/file_ops_copy_reference.s", "tests/harness/file_ops_copy_at_reference.s"]
MODS = ["src/fs/file_ops.c", "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c", "build/i18n_en.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            extra.append(o)
        H.rename_defined_globals(extra, "ref_")
    stub = t / "i18n_stub.c"
    stub.write_text('#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n')
    return H.build(arch, t, ["tests/harness/file_ops_copy_cli.c", *MODS, str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DFOC_SRC="{path}"'])


def tree(root: Path, deep_levels: int = 0) -> Path:
    s = root / "src"
    (s / "a" / "b").mkdir(parents=True)
    (s / "e").mkdir()
    for name, size, mode in (("f1", 10, 0o644), ("f2", 300000, 0o600), ("x.sh", 50, 0o755), ("a/g", 0, 0o640), ("a/b/h", 9000, 0o444)):
        p = s / name
        p.write_bytes(bytes((i * 13 + len(name)) & 255 for i in range(size)))
        p.chmod(mode)
    os.symlink("f1", s / "l_file")
    os.symlink("a", s / "l_dir")
    os.symlink("nowhere", s / "l_dangling")
    os.mkfifo(s / "fifo")
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(str(s / "sock"))
    sock.close()
    os.link(s / "f1", s / "hard")
    ro = s / "ro"
    ro.mkdir()
    (ro / "secret").write_text("s")
    if deep_levels:                                                    # only the "tree" scenario copies it
        p = root / "deep"
        for _ in range(deep_levels):
            p = p / "d"
        p.mkdir(parents=True)
        (p / "leaf").write_text("x")
    (root / "exist").mkdir()
    (root / "exist" / "f1").write_text("old f1")
    (root / "exist" / "keep").write_text("keep")
    (root / "exist" / "a").mkdir()                                      # merged into by the sub-directory copy
    (root / "exist" / "a" / "g").write_text("old g")
    os.symlink("src", root / "alias")
    (root / "exist2" / "b").mkdir(parents=True)                        # a sub-directory copy merges into it
    (root / "exist2" / "b" / "old").write_text("old")                                   # the destination inside the source by another path
    (root / "target").write_text("existing target")
    (root / "target").chmod(0o640)
    ro.chmod(0)
    return root


def unlock(root: Path) -> None:
    for p in (root / "src" / "ro", root / "copy" / "ro", root / "into" / "ro", root / "exist" / "ro", root / "cxl" / "ro"):
        if p.exists():
            p.chmod(0o755)


SCRIPTS = {
    "file": "F @/src/f1 @/new1\nF @/src/f2 @/new2\nF @/src/x.sh @/new3\nF @/src/missing @/new4\nF @/src/a @/new5\nF @/src/fifo @/new6\n"
            "F @/src/sock @/new7\nF @/src/l_file @/new8\nF @/src/f1 @/nodir/x\n",
    "conflicts": "".join(f"P {p}\nF @/src/f2 @/target\nF @/src/f1 @/src/hard\n" for p in "sxoie"),
    "tree": "R @/src @/copy\nR @/src @/src\nR @/src @/src/a/inside\nP o\nR @/src @/exist\nR @/src/f1 @/single\nR @/src/l_dir @/link_copy\n"
            "R @/missing @/m\nR @/deep @/deep_copy\nR @/src/a @/alias/a/b/inside3\nR @/src/a @/exist2\nP s\nR @/src/f1 @/src/f1\n",
    "worker": "W 1\nR @/src/a @/wa\nF @/src/f2 @/wf2\n",
    "cancel": "".join(f"C {k}\nR @/src @/cxl{k}\n" for k in (1, 2, 3, 5, 8)) + "C 1\nF @/src/f2 @/cf\nC 0\n",
}
SECCOMP = {                                                              # fsync fails: the partial target goes, except in place
    "fsync": "S 74 5\nF @/src/f2 @/s1\nP i\nF @/src/f2 @/target\nP o\nF @/src/f1 @/exist/f1\nR @/src/a @/s2\n",
}


def run(exe: Path, impl: str, base: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl, str(base)], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin"}, timeout=30)   # a mutant that blocks on the FIFO hangs
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def snap(root: Path) -> list:
    unlock(root)
    s = H.snapshot(root, scrub=None)
    return [e for e in s if not e[0].startswith("deep/") and not e[0].startswith("deep_copy/")] + [("deep_depth", sum(1 for e in s if e[0].startswith("deep_copy/")))]


def one(exe: Path, t: Path, tag: str, impl: str, arch: str = "x86_64") -> tuple[str, list]:
    base = tree(t / f"{tag}_{impl}_{arch}", 600 if tag == "tree" else 0)
    out = run(exe, impl, base, {**SCRIPTS, **SECCOMP}[tag], arch)
    return out, snap(base)


def test_differential(exe: Path, t: Path) -> dict[str, tuple[str, list]]:
    got = {}
    for tag in {**SCRIPTS, **SECCOMP}:
        a, b = one(exe, t, tag, "ref"), one(exe, t, tag, "c")
        assert a[0] == b[0], f"{tag}: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a[0].splitlines(), b[0].splitlines()) if x != y)
        assert a[1] == b[1], f"{tag}: the trees differ afterwards"
        got[tag] = b
    text = "".join(o for o, _ in got.values())
    assert got["fsync"][0].startswith("S 0 0\n"), "the seccomp filter is installed"
    for code in ("r=-9999", "r=-95", "r=-36", "r=-125", "r=-13", "r=-5", "r=0"):
        assert code in text, f"coverage: {code}"
    print(f"[PASS] FC1. copy engine identical to the asm in {sum(o.count(chr(10)) for o, _ in got.values())} copies on identical trees "
          "(files, links, FIFO/socket, hard links, 600 levels, unreadable dir, into itself / a descendant, merge, 5 conflict policies, "
          "worker mode, cancel)")
    return got


MUTANTS = [
    ("depth limit", "#define MAX_DIR_DEPTH 512", "#define MAX_DIR_DEPTH 511"),
    ("fifo in the UI", "!(type == S_IFIFO && g_fs_progress)", "!(type == S_IFIFO)"),
    ("UI blocking open", "(g_fs_progress ? 0 : O_NONBLOCK)", "0"),
    ("target mode", "(st.mode & 0777) | 0600", "(st.mode & 0777)"),
    ("skip not counted", "            fs_progress_item();\n            (void)os_close((int)sfd);\n            return 0;", "            (void)os_close((int)sfd);\n            return 0;"),
    ("temp not committed", "if (r >= 0 && made == 2) r = fo_overwrite_commit(ddir, created, dname);", ""),
    ("partial kept", "if (made) (void)os_unlinkat(ddir, created, 0);", "(void)made;"),
    ("fsync error ignored", "if (s < 0 && s != -EINVAL) rc = s;", ""),
    ("cancel ignored", "r = fs_progress_cancelled() ? -ECANCELED : cdf_entry(sfd, dfd, name, type, depth);", "r = cdf_entry(sfd, dfd, name, type, depth);"),
    ("error ignored", "while (r >= 0 && (name", "while ((name"),
    ("root not skipped", "st.dev == g_copy_root_dev && st.ino == g_copy_root_ino) r = 0;", "false) r = 0;"),
    ("dir mode", "os_mkdirat(ddir, name, (st.mode & 0777) | 0700)", "os_mkdirat(ddir, name, 0755)"),
    ("merge refused", "if (r >= 0 || r == -EEXIST) {", "if (r >= 0) {"),
    ("self copy allowed", "if (path_is_same_or_descendant(src, dst)) return FO_SAME_FILE;", ""),
    ("links followed", "if ((st.mode & S_IFMT) == S_IFLNK) return copy_link_at(AT_FDCWD, src_path, AT_FDCWD, dst_path);", ""),
    ("same path allowed", "if (!str_cmp(src_path, dst_path)) return FO_SAME_FILE;", ""),
]


# Not mutated: the DT_UNKNOWN branch (tmpfs / ext4 always report d_type); "made" for an in-place target (its name is "", the
# unlink of "" fails harmlessly).
def test_mutants(t: Path, expect: dict[str, tuple[str, list]]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "file_ops_copy.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "file_ops_copy.c"))
                noticed[name] = any(one(exe, mt, tag, "c") != expect[tag] for tag in {**SCRIPTS, **SECCOMP})
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] FC3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


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
                print("[PASS] FC2. qemu-aarch64: the C module gives the x86_64 results")
            else:
                print("[SKIP] FC2: aarch64 toolchain/qemu not installed")
            test_mutants(t, expect)
        finally:
            for p in t.rglob("ro"):
                p.chmod(0o755)
    print("ALL C FILE OPS COPY TESTS PASSED.")


if __name__ == "__main__":
    main()
