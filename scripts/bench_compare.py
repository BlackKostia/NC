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


def sample_dir_entries(target_dir: str, limit: int = 25) -> list[bytes]:
    """Read only the first `limit` non-dot entries without scanning the whole dir."""
    samples: list[bytes] = []
    with os.scandir(target_dir) as it:
        for entry in it:
            if entry.name.startswith("."):
                continue
            # Use prefix (up to 24 bytes) so truncated columns in narrow panes still match
            token = entry.name[:24].encode("utf-8", errors="ignore")
            if len(token) >= 3:
                samples.append(token)
            if len(samples) >= limit:
                break
    return samples


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


def run_single(
    spec: ManagerSpec,
    bin_path: str,
    target_dir: str,
    markers: list[bytes],
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
                if any(m in plain for m in markers):
                    found_ms = (time.perf_counter() - t0) * 1000.0
                    peak_rss_kb = max(peak_rss_kb, read_proc_rss_kb(proc.pid))
                    break
            if proc.poll() is not None:
                break

        try:
            os.write(master, spec.quit_seq)
        except OSError:
            pass

        try:
            _, status, rusage = os.wait4(proc.pid, 0)
            peak_rss_kb = max(peak_rss_kb, rusage.ru_maxrss)
        except ChildProcessError:
            pass
        except KeyboardInterrupt:
            raise
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=1.5)
            except Exception:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=1.0)
                except Exception:
                    pass
        try:
            os.close(master)
        except OSError:
            pass

    return found_ms, peak_rss_kb


def resolve_bin(name: str, duop_bin: str) -> str | None:
    if name == "duop":
        return duop_bin if os.path.isfile(duop_bin) and os.access(duop_bin, os.X_OK) else shutil.which("duop")
    return shutil.which(name)


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

    markers = sample_dir_entries(args.dir)
    if not markers:
        print(f"ERROR: directory has no visible non-dot entries to detect render: {args.dir}", file=sys.stderr)
        return 2

    selected = set(args.managers) if args.managers else None
    missing: list[ManagerSpec] = []
    results: list[tuple[str, list[float], list[int]]] = []

    print(f"Target directory: {args.dir}")
    print(f"Sampled markers : {len(markers)} entries (e.g. {markers[0].decode('utf-8', 'replace')})")
    print(f"Runs / Warmup   : {args.runs} / {args.warmup} (timeout {args.timeout:.0f}s)\n")

    for spec in MANAGERS:
        if selected and spec.name not in selected:
            continue
        bin_path = resolve_bin(spec.name, args.duop_bin)
        if not bin_path:
            missing.append(spec)
            continue

        print(f"[{spec.name}] ({bin_path}) ...", flush=True)
        for _ in range(args.warmup):
            run_single(spec, bin_path, args.dir, markers, args.timeout)

        times_ms: list[float] = []
        rss_list: list[int] = []
        for i in range(args.runs):
            dt_ms, rss_kb = run_single(spec, bin_path, args.dir, markers, args.timeout)
            if dt_ms is None:
                print(f"  run {i + 1}: TIMEOUT (>{args.timeout:.0f}s)", flush=True)
            else:
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
