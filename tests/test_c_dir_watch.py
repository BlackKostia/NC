#!/usr/bin/env python3
"""src/fs/dir_watch.c versus the frozen assembly on real inotify: the two-slot watcher (retargeting, a shared watch descriptor for
both panes on one directory, structural versus content events, queue overflow, cleanup and re-init) is driven by the same script
in two identically built trees; every returned event mask must match."""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CLI_C = ["tests/harness/dw_cli.c", "src/fs/dir_watch.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c",
         "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    ref = t / "dir_watch_ref.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "tests/harness/dir_watch_reference.s"), "-o", str(ref)], check=True)
    H.rename_defined_globals([ref], "ref_")
    return H.build("x86_64", t, CLI_C, [ref])


def run(exe: Path, impl: str, root: Path, script: str) -> list[str]:
    res = subprocess.run([str(exe), impl], input=script.replace("@", str(root)).encode(), capture_output=True, timeout=120, env=ENV)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode().splitlines()


def same(exe: Path, t: Path, name: str, steps: list[str]) -> list[str]:
    outs = []
    for impl in ("ref", "c"):
        root = t / f"{name}_{impl}"
        for d in ("a", "b", "c"):
            (root / d).mkdir(parents=True)
        (root / "a" / "old").write_text("x")
        outs.append(run(exe, impl, root, "\n".join(steps) + "\n"))
    assert outs[0] == outs[1], f"{name}: event masks differ\n" + "\n".join(f"{x!r:20} | {y!r}" for x, y in zip(*outs) if x != y)
    return outs[1]


def test_slots(exe: Path, t: Path) -> None:
    steps = ["POLL", "FD", "SET\t0\t@/a", "INIT", "INIT", "FD", "POLL",                         # before init: everything is a no-op
             "SET\t0\t@/a", "SET\t1\t@/b", "POLL",
             "W\t@/a/new", "POLL", "POLL",                                                       # create + modify (3), then nothing left (0)
             "W\t@/a/new", "POLL",                                                               # content (modify) -> 2
             "H\t@/a/new", "POLL",                                                               # attrib -> 2
             "R\t@/a/new", "POLL", "V\t@/a/old\t@/a/moved", "POLL",
             "W\t@/b/x", "W\t@/a/y", "POLL",                                                     # both slots at once -> 5
             "M\t@/b/sub", "W\t@/a/old2", "W\t@/a/old2", "POLL",
             "SET\t1\t@/a", "W\t@/a/shared", "POLL",                                             # slot 1 now shares slot 0's descriptor -> 5
             "SET\t0\t@/c", "W\t@/a/s2", "POLL", "W\t@/c/c1", "POLL",                            # slot 0 left the shared directory: the kernel watch must stay for slot 1
             "SET\t1\t@/c", "W\t@/a/s3", "POLL", "W\t@/c/c2", "POLL",                            # both on c
             "SET\t0\t@/c", "SET\t1\t@/c", "SET\t0\t@/missing", "W\t@/c/c3", "POLL",             # unchanged = no-op; missing directory: no watch for slot 0
             "SET\t5\t@/b", "W\t@/b/odd", "POLL",                                                # slot is masked to 0 / 1: 5 -> slot 1
             "D\t@/b/sub", "POLL", "R\t@/b/odd", "R\t@/b/x", "D\t@/b", "POLL",                   # the watched directory itself disappears
             "CLEAN", "POLL", "FD", "CLEAN", "INIT", "FD", "SET\t0\t@/a", "W\t@/a/again", "POLL", "CLEAN"]
    out = same(exe, t, "slots", steps)
    polls = [int(o) for s, o in zip(steps, out) if s == "POLL"]
    assert {0, 1, 2, 3, 4, 12, 15}.issubset(set(polls)), polls        # none, structural, content, both, slot 1 only, both slots
    print("[PASS] DWT1. two-slot watcher (retarget, shared descriptor, structural / content, unchanged set, missing directory, cleanup / re-init) identical to the asm")


def test_overflow(exe: Path, t: Path) -> None:
    steps = ["INIT", "SET\t0\t@/a", "SET\t1\t@/b", "MANY\t@/c\t20", "POLL", f"MANY\t@/a\t17000", "POLL", "POLL", "CLEAN"]   # more events than the 16384-entry queue
    out = same(exe, t, "overflow", steps)
    assert out[-3] == "5" and out[-2] == "0", out[-4:]
    print("[PASS] DWT2. queue overflow refreshes both panes (bits 1 and 4), identical to the asm")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_slots(exe, t)
        test_overflow(exe, t)
    print("ALL C DIR WATCH TESTS PASSED.")


if __name__ == "__main__":
    main()
