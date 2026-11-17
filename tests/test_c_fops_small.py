#!/usr/bin/env python3
"""src/fs/file_ops_read.c versus the frozen assembly: fs_read_file_alloc on regular files of many sizes with caps around them,
empty and /proc files (st_size 0), directories, fifos (must not hang), links, missing and unreadable files; copy_link_at on
links of 1 .. 4095 target bytes, non-links, missing sources, existing and unwritable destinations (result and progress tick)."""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CLI_C = ["tests/harness/fops_small_cli.c", "src/fs/file_ops_read.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c",
         "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    ref = t / "fops_small_ref.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "tests/harness/file_ops_read_reference.s"), "-o", str(ref)], check=True)
    link = t / "file_ops_copy_link_ref.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "tests/harness/file_ops_copy_link_reference.s"), "-o", str(link)], check=True)
    H.rename_defined_globals([ref, link], "ref_")
    return H.build("x86_64", t, CLI_C, [ref, link])


def run(exe: Path, *args: str) -> str:
    res = subprocess.run([str(exe), *args], capture_output=True, timeout=60, env=ENV)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode()


def test_read(exe: Path, t: Path) -> None:
    rng = random.Random(71)
    d = t / "r"
    d.mkdir()
    sizes = [0, 1, 2, 4095, 4096, 4097, 65535, 262144, 1048576 + 3]
    for s in sizes:
        (d / f"f{s}").write_bytes(bytes(rng.randrange(256) for _ in range(s)))
    count = 0
    for s in sizes:
        for cap in (0, 1, s - 1, s, s + 1, 4096, 1 << 30):
            if cap < 0:
                continue
            out = run(exe, "read", str(d / f"f{s}"), str(cap)).split()
            assert out[0] == out[1] and out[3] == "same", (s, cap, out)
            count += 1
    (d / "dir").mkdir()
    os.mkfifo(d / "fifo")
    os.symlink("f4096", d / "link")
    os.symlink("nowhere", d / "dangling")
    (d / "secret").write_bytes(b"s" * 100)
    os.chmod(d / "secret", 0)
    for name in ("dir", "fifo", "link", "dangling", "secret", "missing", "dir/missing/x"):
        out = run(exe, "read", str(d / name), "1000").split()
        assert out[0] == out[1] and out[3] == "same", (name, out)
    for path in ("/proc/self/status", "/proc/version", "/dev/null", "/dev/zero", "/proc/self/cmdline", "/proc/self", "/sys/devices/system/cpu/online"):   # sysfs reports st_size 4096 and delivers a few bytes
        out = run(exe, "read", path, "100000").split()
        assert out[0] == out[1] and out[3] == "same", (path, out)
    ok = run(exe, "read", str(d / "f4097"), "4096").split()
    assert ok[0] == "0" and ok[2] == "4096", ok                       # capped to max_bytes
    assert run(exe, "read", str(d / "dir"), "5").split()[0] == "-22" and run(exe, "read", str(d / "fifo"), "5").split()[0] == "-22"
    print(f"[PASS] FR1. fs_read_file_alloc identical to the asm on {count + 13} reads (sizes 0..1 MiB, caps around them, dir / fifo / links / proc / unreadable)")
    os.chmod(d / "secret", 0o644)


def test_link(exe: Path, t: Path) -> None:
    root = t / "l"
    (root / "src").mkdir(parents=True)
    (root / "dst").mkdir()
    ro = root / "ro"
    ro.mkdir()
    n = 0
    for tl in (1, 2, 255, 256, 1000, 4000, 4094, 4095):
        target = ("x" * tl)[:tl]
        os.symlink(target, root / "src" / f"l{tl}")
        n += 1
        out = run(exe, "link", str(root / "src"), f"l{tl}", str(root / "dst"), f"ref{tl}", f"c{tl}").split()
        assert out[0] == out[1] == "0" and out[2] == out[3] == "1", (tl, out)
        assert os.readlink(root / "dst" / f"ref{tl}") == os.readlink(root / "dst" / f"c{tl}") == target
    (root / "src" / "plain").write_text("x")
    (root / "src" / "dir").mkdir()
    os.symlink("t", root / "src" / "dangling")
    (root / "dst" / "exists").write_text("e")
    os.symlink("old", root / "dst" / "exists_link")
    os.chmod(ro, 0o555)
    for name, dst in (("plain", "p1"), ("dir", "d1"), ("missing", "m1"), ("dangling", "g1"), ("l1", "exists"), ("l1", "exists_link"), ("l1", "no/such/dir/x"), ("l1", "ro_file")):
        dd = ro if dst == "ro_file" else root / "dst"
        fresh = dst in ("p1", "d1", "m1", "g1")                         # a name both runs can create: the C run gets its own copy
        out = run(exe, "link", str(root / "src"), name, str(dd), dst, dst + "_c" if fresh else dst).split()
        n += 1
        if fresh:
            assert out[0] == out[1] and out[2] == out[3], (name, dst, out)
        else:
            assert out[0] == out[1] and out[2] == out[3] == "0", (name, dst, out)
    os.chmod(ro, 0o755)
    print(f"[PASS] FR2. copy_link_at identical to the asm on {n} links (targets 1..4095 bytes, non-links, missing, existing and read-only destinations)")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_read(exe, t)
        test_link(exe, t)
    print("ALL C FILE-OPS SMALL-MODULE TESTS PASSED.")


if __name__ == "__main__":
    main()
