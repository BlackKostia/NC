#!/usr/bin/env python3
"""src/fs/task.c + task_worker.c versus the frozen assembly (tests/harness/task_reference.s + task_worker_reference.s): the progress
hooks, the scan (task_measure) and the fork-isolated worker (fs_task_start, fs_task_is_active, fs_task_wake_fd).

TK1 differential on identical trees (x86_64): copy / move / delete jobs of single items (dst verbatim) and batches (dst/<name>),
    files, directories, symlinks, a tree deeper than MAX_DIR_DEPTH (the scan fails), a name that does not fit PATH_MAX, a missing
    item (the run stops at the first failure), a move within one file system (renamed, its tree not scanned), conflicts with a
    cancel requested from inside the run, a second start while the worker runs (-EBUSY); the final page (result, phase, scan totals,
    done counters resynchronised per item, the seqlock even, the last item's name), the worker's exit, the wake fd hang-up and
    the trees afterwards
TK2 a defect of the asm, fixed: the worker frame put the saved device (TW_DEV, +48) inside the FileStat of the item (TW_ST, 56
    bytes): every stat of an item overwrote it with uid / gid, so a move within one file system was never recognised and its
    whole tree was scanned before the rename. The C worker renames without scanning (one entry per item)
TK3 qemu-aarch64: the C modules give the x86_64 results; TK4 mutation check
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/task.c", "src/fs/task_worker.c"]
REFS = ["tests/harness/task_reference.s", "tests/harness/task_worker_reference.s"]
SHARED = ["g_fs_progress", "g_measure_bytes", "g_task_parent_pid", "g_task_start_ms", "g_task_wake_fd", "g_task_op"]
MODS = ["src/fs/file_ops.c", "src/fs/file_ops_copy.c", "src/fs/file_ops_delete.c", "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c",
        "build/i18n_en.c"]
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
        "src/core/mem_prims.c"]


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
        args = [a for g in SHARED for a in ("--redefine-sym", f"ref_{g}={g}")]
        weak = [a for g in SHARED for a in ("--weaken-symbol", g)]
        for o in refs:
            subprocess.run(["objcopy", *args, str(o)], check=True)
            subprocess.run(["objcopy", *weak, str(o)], check=True)
        extra += refs
    stub = t / "i18n_stub.c"
    stub.write_text('#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n')
    return H.build(arch, t, ["tests/harness/task_cli.c", *MODS, str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DTK_SRC1="{s1}"', f'-DTK_SRC2="{s2}"'])


def tree(root: Path, deep: bool = False) -> Path:
    for d in ("src/d1/sub", "src/d2", "dst", "dst2/d1"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for f, size in (("src/a", 100), ("src/b", 5000), ("src/d1/x", 300000), ("src/d1/sub/y", 7), ("src/d2/z", 0), ("dst2/d1/x", 3)):
        (root / f).write_bytes(bytes((i * 11 + len(f)) & 255 for i in range(size)))
    os.symlink("a", root / "src" / "lnk")
    if deep:                                                           # deeper than MAX_DIR_DEPTH: the scan fails
        p = root / "src" / "deep"
        for _ in range(513):
            p = p / "d"
        p.mkdir(parents=True)
    return root


SCRIPTS = {
    "copy": "J 1 1 @/src @/dst a b d1 lnk\nJ 1 0 @/src @/dst/single.copy b\nJ 1 1 @/src @/dst missing a\nJ 1 1 @/src @/dst2 d1\n",
    "move": "J 2 1 @/src @/dst a d2\nJ 2 0 @/src @/dst/renamed b\nJ 2 1 @/src @/dst nope\n",
    "delete": "J 3 1 @/src % a d1\nJ 3 1 @/src % lnk d2 missing b\n",
    "deep": "J 1 1 @/src @/dst deep\nJ 3 1 @/src % deep\n",
    "long": "J 1 1 @/src @/dst " + "n" * 4090 + "\nJ 1 1 @/src @/" + "q" * 4090 + " a\n",
    "busy": "B 1 1 @/src @/dst d1\n",
    "cancel": "K 1\nJ 1 1 @/src @/dst2 d1\nK 1\nJ 2 0 @/src @/dst/m1 a\nK 0\n",   # the second: cancel after the last poll
}


def run(exe: Path, impl: str, base: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl, str(base)], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin"}, timeout=25)   # a mutant that never hangs up the wake fd
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def one(exe: Path, t: Path, tag: str, impl: str, arch: str = "x86_64") -> tuple[str, list]:
    base = tree(t / f"{tag}_{impl}_{arch}", tag == "deep")
    out = run(exe, impl, base, SCRIPTS[tag], arch)
    snap = [e for e in H.snapshot(base) if "/deep/" not in "/" + e[0]]
    return out, snap


def test_differential(exe: Path, t: Path) -> dict[str, tuple[str, list]]:
    got = {}
    for tag in SCRIPTS:
        a, b = one(exe, t, tag, "ref"), one(exe, t, tag, "c")
        jobs = [ln.split() for ln in SCRIPTS[tag].splitlines() if ln[:1] in "JB"]
        moves = [j[1] == "2" for j in jobs]
        if any(moves):                                                    # TK2: a same-device move differs in the scan totals only
            strip = lambda o: [" ".join(w for w in ln.split() if not (m and w.startswith(("total=", "done=")))) for ln, m in zip(o.splitlines(), moves)]
            assert strip(a[0]) == strip(b[0]) and a[1] == b[1], f"{tag}: oracle and C differ beyond the scan:\n{a[0]}\n{b[0]}"
            if tag == "move":
                ra, rc = a[0].splitlines(), b[0].splitlines()
                assert " total=3/100 " in ra[0] and " total=2/0 " in rc[0], ("asm scans a same-device move, C renames", ra[0], rc[0])
                assert " total=1/5000 " in ra[1] and " total=1/0 " in rc[1], (ra[1], rc[1])
            got[tag] = b
            continue
        assert a[0] == b[0], f"{tag}: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a[0].splitlines(), b[0].splitlines()) if x != y)
        assert a[1] == b[1], f"{tag}: the trees differ afterwards"
        got[tag] = b
    text = "".join(o for o, _ in got.values())
    for code in ("res=0 ", "res=-2 ", "res=-36 ", "res=-125 ", "again=-16", "phase=3", "after=0,-1"):
        assert code in text, f"coverage: {code}"
    print("[PASS] TK2. fixed: a move within one file system is renamed without scanning its tree (asm: TW_DEV overwritten, always scanned)")
    print(f"[PASS] TK1. task worker identical to the asm in {sum(o.count(chr(10)) for o, _ in got.values())} jobs on identical trees "
          "(copy / move / delete, batches, too deep, too long, missing item, rename move, cancel, EBUSY, totals, resync, wake fd)")
    return got


MUTANTS = [
    ("src/fs/task.c", "seqlock", "    __atomic_add_fetch(&s->seq, 1, __ATOMIC_RELEASE);\n    (void)str_copy", "    (void)str_copy"),
    ("src/fs/task.c", "bytes ignored", "if (g_fs_progress) g_fs_progress->done_bytes += n;", "(void)n;"),
    ("src/fs/task.c", "items ignored", "if (g_fs_progress) g_fs_progress->done_files++;", ""),
    ("src/fs/task.c", "cancel ignored", "if (__atomic_load_n(&s->cancel, __ATOMIC_RELAXED)) return 1;", ""),
    ("src/fs/task.c", "depth", "#define MAX_DIR_DEPTH 512", "#define MAX_DIR_DEPTH 600"),
    ("src/fs/task.c", "file sizes skipped", "if ((st.mode & S_IFMT) == S_IFREG) { s->total_bytes += (uint64_t)st.size; continue; }", "if ((st.mode & S_IFMT) == S_IFREG) continue;"),
    ("src/fs/task.c", "entries not counted", "            s->total_files++;\n", ""),
    ("src/fs/task.c", "top size", "        s->total_bytes += (uint64_t)st.size;\n        return 0;", "        return 0;"),
    ("src/fs/task_worker.c", "busy", "if (g_task_pid) return -EBUSY;", ""),
    ("src/fs/task_worker.c", "rename scanned", "&& st.dev == dev) shm->total_files++;", "&& false) shm->total_files++;"),
    ("src/fs/task_worker.c", "no resync", "        shm->done_bytes = cum[i].bytes;                               /* exact resync after each item */\n", ""),
    ("src/fs/task_worker.c", "run goes on", "if ((r = tw_item(job, name)) < 0) task_worker_exit(shm, r);", "(void)tw_item(job, name);"),
    ("src/fs/task_worker.c", "dst verbatim joined", "    if (job->join_dst) {", "    if (true) {"),
    ("src/fs/task_worker.c", "cancel at exit", "if (res != -ECANCELED && fs_progress_cancelled()) res = -ECANCELED;", ""),
    ("src/fs/task_worker.c", "write end kept", "    (void)os_close(g_task_pipe[1]);                                   /* only the worker", "    (void)0;                                   /* only the worker"),
    ("src/fs/task_worker.c", "wake fd", "return g_task_pid ? g_task_wake_fd : -1;", "return g_task_wake_fd;"),
    ("src/fs/task_worker.c", "move dev of dst", "if (!job->join_dst) {\n        path_dirname", "if (false) {\n        path_dirname"),
]


# Not mutated: O_NOFOLLOW on the top-level open of task_measure (a symlink is S_IFLNK by lstat and never opened; the flag only
# guards against a swap in between).
def test_mutants(t: Path, expect: dict[str, tuple[str, list]]) -> None:
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
                noticed[name] = any(one(exe, mt, tag, "c") != expect[tag] for tag in SCRIPTS)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] TK4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for tag in SCRIPTS:
                assert one(a64, t, tag, "c", "aarch64") == expect[tag], f"qemu-aarch64 differs in {tag}"
            print("[PASS] TK3. qemu-aarch64: the C modules give the x86_64 results")
        else:
            print("[SKIP] TK3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C TASK TESTS PASSED.")


if __name__ == "__main__":
    main()
