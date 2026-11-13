#!/usr/bin/env python3
"""Million-file / large-directory benchmark & syscall/RSS profiler for Duop."""

import argparse
import os
import pty
import re
import resource
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import fcntl
import struct
import time

RE_TEST_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, RE_TEST_DIR)
from test_pty import VirtualTerminal  # noqa: E402

REPO_ROOT = os.path.dirname(RE_TEST_DIR)
DEFAULT_BIN = os.path.join(REPO_ROOT, "duop")


def populate_files(target_dir: str, count: int) -> float:
    t0 = time.monotonic()
    dfd = os.open(target_dir, os.O_RDONLY)
    try:
        # Use a few varied sizes near front so lazy stat differences are observable
        for i in range(min(32, count)):
            fd = os.open(f"f_{i:07d}.txt", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd)
            if i % 3 == 0:
                os.write(fd, b"X" * (64 + i))
            os.close(fd)
        flags = os.O_CREAT | os.O_WRONLY
        for i in range(32, count):
            os.close(os.open(f"f_{i:07d}.txt", flags, 0o644, dir_fd=dfd))
    finally:
        os.close(dfd)
    return time.monotonic() - t0


def set_winsize(fd: int, cols: int, rows: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def read_proc_rss_kb(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def run_duop_pty_bench(binary: str, left_dir: str, right_dir: str, expect_count: int, timeout: float = 60.0):
    master, slave = pty.openpty()
    set_winsize(slave, 120, 35)
    t_start = time.monotonic()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        os.execve(binary, [binary, "--lang", "en", left_dir, right_dir], env)
        os._exit(127)

    os.close(slave)
    ttff = None
    t_full = None
    peak_rss_kb = 0
    vt = VirtualTerminal(120, 35)
    target_footer = f"{expect_count} files"

    try:
        deadline = t_start + timeout
        sent_quit = False
        while time.monotonic() < deadline:
            r, _, _ = select.select([master], [], [], 0.01)
            peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(pid))
            if r:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                vt.feed(data)
                now = time.monotonic()
                screen = vt.full_text()
                if ttff is None and "Duop" in screen and ".txt" in screen:
                    ttff = now - t_start
                if t_full is None and target_footer in screen and "Loading:" not in screen:
                    t_full = now - t_start
                    os.write(master, b"q")
                    sent_quit = True
                    break

        if not sent_quit:
            os.write(master, b"q")
        _, status, ru = os.wait4(pid, 0)
        exit_code = os.waitstatus_to_exitcode(status)
        peak_rss_kb = max(peak_rss_kb, ru.ru_maxrss)
        if t_full is None:
            t_full = time.monotonic() - t_start
        if ttff is None:
            ttff = t_full
    finally:
        os.close(master)

    return {
        "ttff_s": ttff,
        "full_s": t_full,
        "peak_rss_mb": peak_rss_kb / 1024.0,
        "exit_code": exit_code,
    }


def run_strace_counts(binary: str, left_dir: str, right_dir: str, expect_count: int) -> dict[str, int]:
    """Run duop inside a PTY helper while strace -f -c counts ONLY the duop child PID."""
    if not shutil.which("strace"):
        return {}
    trace_file = os.path.join(os.path.dirname(left_dir), "duop.strace")
    master, slave = pty.openpty()
    set_winsize(slave, 120, 35)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        os.execve(
            "/usr/bin/strace",
            [
                "strace",
                "-o",
                trace_file,
                "-e",
                "trace=newfstatat,statx,getdents64,io_uring_setup",
                "-c",
                "--",
                binary,
                "--lang",
                "en",
                left_dir,
                right_dir,
            ],
            env,
        )
        os._exit(127)

    os.close(slave)
    vt = VirtualTerminal(120, 35)
    target_footer = f"{expect_count} files"
    deadline = time.monotonic() + 45.0
    try:
        while time.monotonic() < deadline:
            r, _, _ = select.select([master], [], [], 0.02)
            if r:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                vt.feed(data)
                screen = vt.full_text()
                if target_footer in screen and "Loading:" not in screen:
                    break
        os.write(master, b"q")
        os.waitpid(pid, 0)
    finally:
        os.close(master)

    counts = {}
    if os.path.exists(trace_file):
        text = open(trace_file, encoding="utf-8", errors="replace").read()
        for line in text.splitlines():
            parts = line.split()
            if parts and parts[-1] in ("newfstatat", "statx", "getdents64", "io_uring_setup"):
                try:
                    counts[parts[-1]] = int(parts[3])
                except (ValueError, IndexError):
                    pass
    return counts


def main() -> None:
    ap = argparse.ArgumentParser(description="Benchmark Duop on large/1M file directories")
    ap.add_argument("--binary", default=DEFAULT_BIN)
    ap.add_argument("--count", type=int, default=100000, help="Files to generate (e.g. 100000 or 1000000)")
    ap.add_argument("--dir-base", default="/dev/shm", help="Parent directory (/dev/shm for tmpfs, /tmp for NVMe)")
    ap.add_argument("--strace", action="store_true", help="Also collect strace syscall summary")
    args = ap.parse_args()

    if not os.path.exists(args.binary):
        raise SystemExit(f"Binary not found: {args.binary}")

    base = args.dir_base if os.path.isdir(args.dir_base) else "/tmp"
    with tempfile.TemporaryDirectory(dir=base, prefix="duop_bench_") as tmp:
        left_dir = os.path.join(tmp, "many")
        right_dir = os.path.join(tmp, "empty")
        os.makedirs(left_dir)
        os.makedirs(right_dir)
        t_gen = populate_files(left_dir, args.count)
        print(f"Generated {args.count} files in {left_dir} ({t_gen:.2f}s)")

        res = run_duop_pty_bench(args.binary, left_dir, right_dir, args.count)
        print(
            f"Duop ({os.path.basename(args.binary)}): "
            f"TTFF={res['ttff_s']*1000:.1f}ms, "
            f"Full={res['full_s']*1000:.1f}ms, "
            f"PeakRSS={res['peak_rss_mb']:.2f} MiB, "
            f"exit={res['exit_code']}"
        )
        if args.strace:
            sc = run_strace_counts(args.binary, left_dir, right_dir, args.count)
            print(f"Syscalls: {sc}")


if __name__ == "__main__":
    main()
