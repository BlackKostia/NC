#!/usr/bin/env python3
"""Process hygiene around any command (a test suite, verify_build.sh, a manual session):

  python3 proc_health.py -- python3 tests/test_du_sizes.py

Snapshots the running duop processes, runs the command, then reports every duop process that
appeared and outlived it (leak), with its tty, state and CPU usage over one second -- a process
without a terminal burning CPU is a hung / spinning orphan. --kill terminates such leaks.
`--scan` only lists current duop processes without a terminal.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

from rt_common import cpu_ticks, duop_processes


def describe(rows):
    hz = os.sysconf("SC_CLK_TCK")
    t0 = {}
    for pid, *_ in rows:
        try:
            t0[pid] = cpu_ticks(pid)
        except OSError:
            pass
    time.sleep(1)
    out = []
    for pid, tty, state, args in rows:
        try:
            cpu = 100 * (cpu_ticks(pid) - t0.get(pid, 0)) / hz
        except OSError:
            continue
        out.append((pid, tty, state, cpu, args))
    return out


def main():
    argv = sys.argv[1:]
    do_kill = "--kill" in argv
    argv = [a for a in argv if a != "--kill"]
    if argv[:1] == ["--scan"]:
        rows = [r for r in duop_processes() if r[1] == "?"]
        leaks = describe(rows)
        rc_cmd = 0
    else:
        if "--" in argv:
            argv = argv[argv.index("--") + 1:]
        before = {r[0] for r in duop_processes()}
        rc_cmd = subprocess.call(argv) if argv else 0
        time.sleep(0.5)
        rows = [r for r in duop_processes() if r[0] not in before]
        leaks = describe(rows)
    for pid, tty, state, cpu, args in leaks:
        flag = "SPINNING " if cpu > 20 else ""
        print(f"LEAK: pid {pid} tty {tty} state {state} cpu {cpu:.0f}% {flag}-- {args[:110]}")
        if do_kill:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
    print(f"PROC HEALTH: command rc={rc_cmd}, {len(leaks)} leftover duop processes"
          + (" (killed)" if do_kill and leaks else ""))
    return 1 if leaks or rc_cmd else 0


if __name__ == "__main__":
    sys.exit(main())
