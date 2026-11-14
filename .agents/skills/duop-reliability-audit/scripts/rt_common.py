#!/usr/bin/env python3
"""Shared runtime helpers: launch Duop in a PTY the way a shell does (SIGPIPE at its default
action -- Python children inherit SIG_IGN otherwise), read raw output, process inspection."""

from __future__ import annotations

import os
import select
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tests"))
from test_pty import PtySession  # noqa: E402

BINARY = os.environ.get("DUOP_BIN", str(ROOT / "duop"))
SHELL_LIKE = ["--default-signal=PIPE"]


def launch(args, env=None, cols=100, rows=30, extra_env_args=()):
    """Duop under `env --default-signal=PIPE [extra] duop args` (pid == Duop after exec)."""
    return PtySession("/usr/bin/env", SHELL_LIKE + list(extra_env_args) + [BINARY] + list(args),
                      cols=cols, rows=rows, extra_env=env or {})


def read_raw(s, wait=0.4):
    out = bytearray()
    end = time.monotonic() + wait
    while time.monotonic() < end:
        r, _, _ = select.select([s.master], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(s.master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        s.vt.feed(chunk)
    return bytes(out)


_STATUS: dict[int, int] = {}       # exit statuses already reaped by alive() / wait_exit()


def _poll(pid):
    if pid in _STATUS:
        return _STATUS[pid]
    try:
        p, st = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return None if Path(f"/proc/{pid}").exists() else _STATUS.get(pid, -1)
    if p:
        _STATUS[pid] = st
        return st
    return None


def alive(pid):
    return _poll(pid) is None


def wait_exit(pid, timeout):
    """Exit status (os.waitpid encoding), -1 if unknown, None while still running."""
    end = time.monotonic() + timeout
    while True:
        st = _poll(pid)
        if st is not None or time.monotonic() >= end:
            return st
        time.sleep(0.05)


def describe_status(st):
    if st is None:
        return "running"
    if st == -1:
        return "exited (status unknown)"
    if os.WIFSIGNALED(st):
        return f"killed by signal {os.WTERMSIG(st)}"
    return f"exit code {os.WEXITSTATUS(st)}"


def kill(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def children(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def cpu_ticks(pid):
    f = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(f[11]) + int(f[12])                 # utime + stime


def duop_processes():
    """[(pid, tty, state, args)] of every running duop binary."""
    out = subprocess.run(["ps", "-eo", "pid=,tty=,stat=,comm=,args="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5 and parts[3] == "duop":
            rows.append((int(parts[0]), parts[1], parts[2], parts[4]))
    return rows


class Report:
    def __init__(self, title):
        self.title, self.rows = title, []

    def add(self, ok, name, detail=""):
        self.rows.append((ok, name, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" -- {detail}" if detail else ""), flush=True)

    def finish(self):
        bad = [r for r in self.rows if not r[0]]
        print(f"{self.title}: {len(self.rows) - len(bad)}/{len(self.rows)} passed")
        return 1 if bad else 0
