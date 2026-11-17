#!/usr/bin/env python3
"""
Benchmark directory-open latency (first rendered frame in PTY) and Peak RSS
for Duop and other TUI file managers.

Usage:
    python3 scripts/bench_compare.py --dir /home/chessplayer/duop_perf_20m
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time
from dataclasses import dataclass
from typing import Callable

ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]")


@dataclass(frozen=True)
class ManagerSpec:
    name: str
    cmd_builder: Callable[[str, str], list[str]]
    quit_seq: bytes
    install_hint: str


MANAGERS: list[ManagerSpec] = [
    ManagerSpec(
        name="duop",
        cmd_builder=lambda bin_path, d: [bin_path, d, d],
        quit_seq=b"\x1b[21~",  # F10
        install_hint="make release (у корені репозиторію)",
    ),
    ManagerSpec(
        name="mc",
        cmd_builder=lambda bin_path, d: [bin_path, "-u", d],
        quit_seq=b"\x1b[21~",  # F10
        install_hint="sudo apt install mc",
    ),
    ManagerSpec(
        name="yazi",
        cmd_builder=lambda bin_path, d: [bin_path, d],
        quit_seq=b"q",
        install_hint="cargo install yazi-fm yazi-cli  (або snap/brew/deb)",
    ),
    ManagerSpec(
        name="lf",
        cmd_builder=lambda bin_path, d: [bin_path, d],
        quit_seq=b"q",
        install_hint="sudo apt install lf  (або go install github.com/gokcehan/lf@latest)",
    ),
    ManagerSpec(
        name="nnn",
        cmd_builder=lambda bin_path, d: [bin_path, d],
        quit_seq=b"q",
        install_hint="sudo apt install nnn",
    ),
    ManagerSpec(
        name="ranger",
        cmd_builder=lambda bin_path, d: [bin_path, d],
        quit_seq=b"Q",
        install_hint="sudo apt install ranger",
    ),
    ManagerSpec(
        name="vifm",
        cmd_builder=lambda bin_path, d: [bin_path, d],
        quit_seq=b":q\r",
        install_hint="sudo apt install vifm",
    ),
]


def sample_dir_entries(target_dir: str, limit: int = 25) -> tuple[list[bytes], re.Pattern[bytes] | None]:
    """Read only the first `limit` non-dot entries without scanning the whole dir."""
    samples: list[bytes] = []
    exts: dict[bytes, int] = {}
    with os.scandir(target_dir) as it:
        for entry in it:
            if entry.name.startswith("."):
                continue
            token = entry.name[:24].encode("utf-8", errors="ignore")
            if len(token) >= 3:
                samples.append(token)
            if "." in entry.name and not entry.name.startswith("."):
                ext = entry.name.rsplit(".", 1)[1].encode("utf-8", errors="ignore")
                if 1 <= len(ext) <= 6 and ext.isalnum():
                    exts[ext] = exts.get(ext, 0) + 1
            if len(samples) >= limit:
                break
    pattern: re.Pattern[bytes] | None = None
    if exts:
        top_ext, cnt = max(exts.items(), key=lambda kv: kv[1])
        if cnt >= max(3, len(samples) // 2):
            pattern = re.compile(rb"[A-Za-z0-9_-]{3,}\." + re.escape(top_ext))
    return samples, pattern


def set_pty_size(fd: int, rows: int = 40, cols: int = 120) -> None:
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def read_proc_rss_kb(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("VmHWM:") or line.startswith("VmRSS:"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        return int(parts[1])
    except OSError:
        pass
    return 0


def wait_proc_bounded(pid: int, timeout_s: float = 2.0) -> int:
    """Wait up to timeout_s for pid, returning peak RSS in KB, else terminate."""
    peak_rss_kb = 0
    end = time.perf_counter() + timeout_s
    while time.perf_counter() < end:
        peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(pid))
        try:
            wpid, _, rusage = os.wait4(pid, os.WNOHANG)
            if wpid == pid:
                return max(peak_rss_kb, rusage.ru_maxrss)
        except ChildProcessError:
            return peak_rss_kb
        time.sleep(0.02)
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        pass
    end_term = time.perf_counter() + 1.0
    while time.perf_counter() < end_term:
        peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(pid))
        try:
            wpid, _, rusage = os.wait4(pid, os.WNOHANG)
            if wpid == pid:
                return max(peak_rss_kb, rusage.ru_maxrss)
        except ChildProcessError:
            return peak_rss_kb
        time.sleep(0.02)
    try:
        os.killpg(pid, signal.SIGKILL)
        _, _, rusage = os.wait4(pid, 0)
        peak_rss_kb = max(peak_rss_kb, rusage.ru_maxrss)
    except OSError:
        pass
    return peak_rss_kb


def run_single(
    spec: ManagerSpec,
    bin_path: str,
    target_dir: str,
    markers: list[bytes],
    marker_re: re.Pattern[bytes] | None,
    timeout_s: float,
) -> tuple[float | None, int]:
    master, slave = pty.openpty()
    set_pty_size(slave, 40, 120)
    cmd = spec.cmd_builder(bin_path, target_dir)
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")

    t0 = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave)

    raw_buf = bytearray()
    found_ms: float | None = None
    peak_rss_kb = 0

    try:
        deadline = t0 + timeout_s
        while time.perf_counter() < deadline:
            r, _, _ = select.select([master], [], [], 0.02)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                raw_buf.extend(chunk)
                plain = ANSI_RE.sub(b"", bytes(raw_buf))
                matched = any(m in plain for m in markers) or (marker_re is not None and marker_re.search(plain) is not None)
                if matched:
                    found_ms = (time.perf_counter() - t0) * 1000.0
                    peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(proc.pid))
                    break
            if proc.poll() is not None:
                break

        if found_ms is not None:
            try:
                os.write(master, spec.quit_seq)
            except OSError:
                pass
            peak_rss_kb = max(peak_rss_kb, wait_proc_bounded(proc.pid, timeout_s=2.0))
        else:
            peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(proc.pid))
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                pass
            peak_rss_kb = max(peak_rss_kb, wait_proc_bounded(proc.pid, timeout_s=1.0))
    finally:
        try:
            os.close(master)
        except OSError:
            pass

    return found_ms, peak_rss_kb


def resolve_bin(name: str, duop_bin: str) -> str | None:
    if name == "duop":
        return duop_bin if os.path.isfile(duop_bin) and os.access(duop_bin, os.X_OK) else shutil.which("duop")
    found = shutil.which(name)
    if found:
        return found
    snap_bin = f"/snap/bin/{name}"
    return snap_bin if os.path.isfile(snap_bin) and os.access(snap_bin, os.X_OK) else None


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare directory open time across TUI file managers.")
    parser.add_argument("--dir", default="/home/chessplayer/duop_perf_20m", help="Target directory to open")
    parser.add_argument("--duop-bin", default="./duop", help="Path to duop binary")
    parser.add_argument("--runs", type=int, default=3, help="Measured runs per manager")
    parser.add_argument("--warmup", type=int, default=1, help="Warmup runs per manager")
    parser.add_argument("--timeout", type=float, default=60.0, help="Timeout per run in seconds")
    parser.add_argument("--managers", nargs="*", help="Subset of managers to run")
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        print(f"ERROR: directory not found: {args.dir}", file=sys.stderr)
        return 2

    markers, marker_re = sample_dir_entries(args.dir)
    if not markers:
        print(f"ERROR: directory has no visible non-dot entries to detect render: {args.dir}", file=sys.stderr)
        return 2

    selected = set(args.managers) if args.managers else None
    missing: list[ManagerSpec] = []
    results: list[tuple[str, list[float], list[int]]] = []

    print(f"Target directory: {args.dir}")
    print(f"Sampled markers : {len(markers)} entries (e.g. {markers[0].decode('utf-8', 'replace')})")
    if marker_re is not None:
        print(f"Pattern marker  : {marker_re.pattern.decode('utf-8', 'replace')}")
    print(f"Runs / Warmup   : {args.runs} / {args.warmup} (timeout {args.timeout:.0f}s)\n")

    for spec in MANAGERS:
        if selected and spec.name not in selected:
            continue
        bin_path = resolve_bin(spec.name, args.duop_bin)
        if not bin_path:
            missing.append(spec)
            continue

        print(f"[{spec.name}] ({bin_path}) ...", flush=True)
        timed_out = False
        for _ in range(args.warmup):
            w_ms, _ = run_single(spec, bin_path, args.dir, markers, marker_re, args.timeout)
            if w_ms is None:
                print(f"  warmup: TIMEOUT (>{args.timeout:.0f}s) - skipping remaining runs", flush=True)
                timed_out = True
                break

        times_ms: list[float] = []
        rss_list: list[int] = []
        if not timed_out:
            for i in range(args.runs):
                dt_ms, rss_kb = run_single(spec, bin_path, args.dir, markers, marker_re, args.timeout)
                if dt_ms is None:
                    print(f"  run {i + 1}: TIMEOUT (>{args.timeout:.0f}s) - stopping manager", flush=True)
                    rss_list.append(rss_kb)
                    break
                print(f"  run {i + 1}: {dt_ms:.1f} ms | Peak RSS: {rss_kb / 1024:.2f} MiB", flush=True)
                times_ms.append(dt_ms)
                rss_list.append(rss_kb)
        results.append((spec.name, times_ms, rss_list))

    print("\n=== Summary ===")
    print(f"{'Manager':<10} | {'Min (ms)':>10} | {'Median (ms)':>11} | {'Mean (ms)':>10} | {'Peak RSS (MiB)':>14}")
    print("-" * 67)
    for name, times_ms, rss_list in results:
        if not times_ms:
            print(f"{name:<10} | {'TIMEOUT':>10} | {'TIMEOUT':>11} | {'TIMEOUT':>10} | {'-':>14}")
            continue
        mn = min(times_ms)
        med = statistics.median(times_ms)
        avg = statistics.mean(times_ms)
        rss_mib = max(rss_list) / 1024.0 if rss_list else 0.0
        print(f"{name:<10} | {mn:10.1f} | {med:11.1f} | {avg:10.1f} | {rss_mib:14.2f}")

    if missing:
        print("\nNot installed (skipped):")
        for spec in missing:
            print(f"  - {spec.name:<8} -> {spec.install_hint}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
