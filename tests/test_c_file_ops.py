#!/usr/bin/env python3
"""src/fs/file_ops.c versus the frozen assembly (tests/harness/file_ops_reference.s): fs_errno_message, fs_mkdir, fs_touch, fs_rename,
fs_rename_noreplace, path_is_same_or_descendant and copy_data (reflink -> copy_file_range -> read / write).

FO1 differential on two identical trees (x86_64): every errno message; mkdir / touch / rename / rename_noreplace on files,
    directories, symlinks (dangling too), missing parents and existing targets; the RENAME_NOREPLACE fallback when the kernel
    answers EINVAL or ENOSYS (seccomp); path_is_same_or_descendant on prefixes, trailing slashes, "/" and empty strings;
    copy_data of files of 0 B .. 9 MiB (copy_file_range steps of 4 MiB), from a pipe, into /dev/full (ENOSPC), with
    copy_file_range failing before any progress (EXDEV / EOPNOTSUPP / EINVAL / ENOSYS / EBADF: read / write fallback; EIO: error)
    and cancel requests at every poll; the results, the reported bytes, the polls and the trees afterwards
FO2 qemu-aarch64: the C module gives the x86_64 results (without the seccomp scenarios); FO3 mutation check
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/file_ops.c"
REF = "tests/harness/file_ops_reference.s"
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
ERRNOS = [0, 1, 2, 5, 9, 13, 16, 17, 20, 21, 22, 28, 39, 95, 125, 9999, 10000, -5]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    if arch == "x86_64":
        o = t / "file_ops_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    return H.build(arch, t, ["tests/harness/file_ops_cli.c", str(ROOT / "build/i18n_en.c"), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DFO_SRC="{path}"'])


def tree(root: Path) -> Path:
    root.mkdir(parents=True)
    for name, size in (("empty", 0), ("small", 100), ("buf", 262144), ("buf1", 262145), ("big", 9 * 1024 * 1024 + 17)):
        (root / name).write_bytes(bytes((i * 31 + 7) & 255 for i in range(min(size, 4096))) * (size // 4096) + bytes(size % 4096))
    (root / "dir").mkdir()
    (root / "dir" / "inner").write_text("x")
    (root / "full").mkdir()
    os.symlink("small", root / "lnk")
    os.symlink("nowhere", root / "dangling")
    return root


def run(exe: Path, impl: str, base: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl, str(base)], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin", "LANG": "C"}, timeout=300)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def scripts() -> dict[str, str]:
    s = {"errno": "".join(f"E {e}\n" for e in ERRNOS)}
    s["ops"] = ("K @/new\nK @/new\nK @/missing/x\nT @/t1\nT @/t1\nT @/dir\nT @/missing/t\nR @/t1 @/t2\nR @/t2 @/small\nR @/nope @/x\n"
                "R @/dir @/dir/inner/x\nQ @/small @/s2\nQ @/s2 @/buf\nQ @/s2 @/dangling\nQ @/s2 @/lnk\nQ @/dir @/dir2\nQ @/nope @/y\n"
                "Q @/s2 @/missing/z\nK @/dir2/sub\nR @/dir2 @/new\n")
    pairs = [("/a", "/a"), ("/a", "/a/"), ("/a/", "/a"), ("/a", "/a/b"), ("/a", "/ab"), ("/a///", "/a/b"), ("/", "/x"), ("/", "/"),
             ("~", "/a"), ("a", "a"), ("a", "ab/c"), ("/a/b", "/a"), ("/a/b", "/a/b/c/d"), ("//", "/q"), ("/a", "~")]
    s["paths"] = "".join(f"I {a} {b}\n" for a, b in pairs)
    copies = "".join(f"D @/{n} @/{n}.{r} {r}\n" for n in ("empty", "small", "buf", "buf1", "big") for r in (1, 0))
    copies += "D @/dir @/dir.copy 1\nD @/big /dev/full 1\nD @/small /dev/full 0\nP 0 @/p0\nP 50000 @/p1\n"
    copies += "".join(f"C {k}\nD @/big @/big.cancel{k} 1\nC {k}\nD @/buf1 @/buf1.cancel{k} 0\n" for k in (1, 2, 3)) + "C 0\n"
    s["copy"] = copies
    return s


def seccomp_scripts() -> dict[str, str]:
    s = {f"noreplace_{e}": f"S n {e}\nQ @/small @/s2\nQ @/s2 @/buf\nQ @/s2 @/dangling\nQ @/s2 @/missing/x\nQ @/nope @/q\n" for e in (22, 38)}
    for e in (18, 95, 22, 38, 9, 5, 28):
        s[f"cfr_{e}"] = f"S c {e}\nD @/big @/big.x 1\nD @/small @/small.x 1\nD @/empty @/empty.x 1\nC 2\nD @/big @/big.c 1\nC 0\n"
    return s


def diff_trees(exe: Path, t: Path, tag: str, script: str) -> tuple[str, list]:
    a, b = tree(t / f"{tag}_a"), tree(t / f"{tag}_b")
    oa, ob = run(exe, "ref", a, script), run(exe, "c", b, script)
    assert oa == ob, f"{tag}: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(oa.splitlines(), ob.splitlines()) if x != y)
    snap = H.snapshot(b)
    assert H.snapshot(a) == snap, f"{tag}: the trees differ afterwards"
    return ob, snap


def test_differential(exe: Path, t: Path) -> dict[str, tuple[str, list]]:
    outs = {}
    for tag, s in {**scripts(), **seccomp_scripts()}.items():
        outs[tag] = diff_trees(exe, t, tag, s)
    allout = "".join(o for o, _ in outs.values())
    assert " r=-28 " in allout and " r=-125 " in allout and "Q -17" in allout, "coverage: ENOSPC, cancel, EEXIST"
    assert all(outs[k][0].startswith("S 0 0\n") for k in seccomp_scripts()), "the seccomp filters are installed"
    print(f"[PASS] FO1. file_ops identical to the asm in {sum(o.count(chr(10)) for o, _ in outs.values())} calls on identical trees "
          f"(errno texts, mkdir/touch/rename, NOREPLACE fallback for EINVAL/ENOSYS, path prefixes, copy 0 B..9 MiB, pipe, /dev/full, "
          "copy_file_range failures, cancel)")
    return outs


MUTANTS = [
    ("errno same", "#define FS_ERR_SAME 9999", "#define FS_ERR_SAME 9998"),
    ("errno busy", "case EBUSY: return l->s[LS_err_busy];", ""),
    ("touch not exclusive", "O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC", "O_WRONLY | O_CREAT | O_CLOEXEC"),
    ("mkdir mode", "os_mkdirat(AT_FDCWD, path, 0755)", "os_mkdirat(AT_FDCWD, path, 0700)"),
    ("noreplace flag", "new_path, RENAME_NOREPLACE);", "new_path, 0);"),
    ("fallback on ENOSYS only", "if (r != -EINVAL && r != -ENOSYS) return r;", "if (r != -ENOSYS) return r;"),
    ("fallback follows links", "os_statat(AT_FDCWD, new_path, &st, 0)", "os_statat(AT_FDCWD, new_path, &st, 1)"),
    ("trailing slash kept", "while (n > 1 && src[n - 1] == '/') n--;", ""),
    ("root not special", "if (n == 1 && src[0] == '/') return 1;", ""),
    ("prefix boundary", "return dst[n] == 0 || dst[n] == '/';", "return 1;"),
    ("cfr chunk", "#define CFR_CHUNK 4194304", "#define CFR_CHUNK 4194303"),
    ("rw progress", "fs_progress_bytes((uint64_t)w);", "fs_progress_bytes((uint64_t)r + 1);"),
    ("rw cancel ignored", "        fs_progress_bytes((uint64_t)w);\n        if (fs_progress_cancelled()) return -ECANCELED;", "        fs_progress_bytes((uint64_t)w);"),
    ("cfr cancel ignored", "            fs_progress_bytes((uint64_t)r);\n            if (fs_progress_cancelled()) return -ECANCELED;", "            fs_progress_bytes((uint64_t)r);"),
    ("EXDEV fatal", "if (r == -EXDEV || ", "if ("),
    ("EIO falls back", "|| r == -EBADF) return copy_rw(sfd, dfd);", "|| r == -EBADF || r == -EIO) return copy_rw(sfd, dfd);"),
    ("short write ignored", "if (w < 0) return w;", ""),
]


# Not mutated: the probe error of the NOREPLACE fallback (any stat error but ENOENT makes the rename fail the same way) and a
# copy_file_range failure after progress (no unprivileged way to make a running copy_file_range fail half-way).
def test_mutants(t: Path, expect: dict[str, tuple[str, list]]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}
    allscripts = {**scripts(), **seccomp_scripts()}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "file_ops.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "file_ops.c"))
                noticed[name] = False
                for tag, s in allscripts.items():
                    root = tree(mt / tag)
                    if run(exe, "c", root, s) != expect[tag][0] or H.snapshot(root) != expect[tag][1]:
                        noticed[name] = True
                        break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] FO3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for tag, s in scripts().items():
                root = tree(t / f"a64_{tag}")
                assert run(a64, "c", root, s, "aarch64") == expect[tag][0] and H.snapshot(root) == expect[tag][1], f"qemu-aarch64 differs in {tag}"
            print("[PASS] FO2. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] FO2: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C FILE OPS TESTS PASSED.")


if __name__ == "__main__":
    main()
