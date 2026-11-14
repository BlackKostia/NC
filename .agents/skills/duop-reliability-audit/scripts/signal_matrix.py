#!/usr/bin/env python3
"""Signal & terminal-lifecycle matrix for Duop, launched like a shell launches it.

  S1  preview helper dies (SIGKILL)  -> Duop survives the next image preview (no SIGPIPE death)
  S2  helper crashes (SIGSEGV)       -> the UI terminal is not touched by the helper
  S3  SIGTERM / SIGINT               -> clean exit, terminal restored (cooked tty, main screen)
  S4  SIGSEGV / SIGABRT / SIGFPE     -> terminal restored before Duop dies by that signal
  S5  terminal hangup, SIGHUP ignored (nohup / PID 1 in a container) -> Duop exits, no spinning
  S6  SIGWINCH storm (200 in 1 s)    -> still alive and redrawing
  S7  idle for 3 s                   -> ~0 % CPU (no busy loop)
"""

from __future__ import annotations

import os
import signal
import sys
import tempfile
import termios
import time

from PIL import Image

from rt_common import Report, alive, children, cpu_ticks, kill, launch, read_raw, wait_exit

RESTORE = (b"\x1b[?1049l", b"\x1b[?1000l")


def dirs(tmp, images=False):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left, exist_ok=True)
    os.makedirs(right, exist_ok=True)
    if images:
        for i in range(6):
            Image.new("RGB", (60 + i, 40), (30 * i, 90, 200)).save(os.path.join(left, f"p{i}.png"))
    return ["--lang", "en", left, right]


def restored(s, out):
    try:
        lflag = termios.tcgetattr(s.master)[3]
    except termios.error:
        lflag = 0
    return all(r in out for r in RESTORE) and bool(lflag & termios.ICANON)


def helper_death(rep, tmp, sig, name):
    s = launch(dirs(tmp, images=True), {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        s.send(b"\x1b[20~", 0.6)
        s.send(b"\x1b[B", 0.5)
        kids = children(s.pid)
        if not kids:
            rep.add(False, name, "no preview helper found")
            return
        for k in kids:
            os.kill(k, sig)
        out = read_raw(s, 0.4)
        for _ in range(4):
            os.write(s.master, b"\x1b[B")
            out += read_raw(s, 0.3)
        st = wait_exit(s.pid, 0.5)
        if name.startswith("S1"):
            rep.add(st is None, name, "" if st is None else f"Duop died, signal {os.WTERMSIG(st) if os.WIFSIGNALED(st) else st}")
        else:
            rep.add(st is None and b"\x1b[?1049l" not in out, name,
                    "" if st is None else "Duop died")
    finally:
        kill(s)


def graceful(rep, tmp, sig):
    s = launch(dirs(tmp), {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        os.kill(s.pid, sig)
        out = read_raw(s, 0.8)
        st = wait_exit(s.pid, 2)
        rep.add(st is not None and restored(s, out), f"S3 {signal.Signals(sig).name}: clean exit + tty restored",
                "still running" if st is None else ("" if restored(s, out) else "terminal left raw"))
    finally:
        kill(s)


def fatal(rep, tmp, sig):
    s = launch(dirs(tmp), {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        os.kill(s.pid, sig)
        st = wait_exit(s.pid, 2)
        out = read_raw(s, 0.3)
        ok = st is not None and os.WIFSIGNALED(st) and restored(s, out)
        rep.add(ok, f"S4 {signal.Signals(sig).name}: tty restored, then dies by it",
                "" if ok else ("still running" if st is None else "terminal left raw / alt screen"))
    finally:
        kill(s)


def hangup(rep, tmp):
    s = launch(dirs(tmp), {"HOME": tmp}, extra_env_args=["--ignore-signal=HUP"])
    try:
        read_raw(s, 0.5)
        os.close(s.master)
        st = wait_exit(s.pid, 3)
        detail = ""
        if st is None:
            t0 = cpu_ticks(s.pid)
            time.sleep(1)
            detail = f"still running after hangup, {cpu_ticks(s.pid) - t0} CPU ticks/s"
        rep.add(st is not None, "S5 hangup with SIGHUP ignored: exits", detail)
    finally:
        try:
            os.kill(s.pid, 9)
            os.waitpid(s.pid, 0)
        except OSError:
            pass


def winch_storm(rep, tmp):
    args = dirs(tmp)
    for i in range(5):
        open(os.path.join(args[2], f"f{i}.txt"), "w").write("x")
    s = launch(args, {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        for _ in range(200):
            os.kill(s.pid, signal.SIGWINCH)
            time.sleep(0.005)
        read_raw(s, 0.5)
        os.write(s.master, b"\x1b[B")
        out = read_raw(s, 0.5)
        rep.add(alive(s.pid) and len(out) > 0, "S6 SIGWINCH storm: alive and redrawing",
                "" if out else "no redraw after the storm")
    finally:
        kill(s)


def idle_cpu(rep, tmp):
    s = launch(dirs(tmp), {"HOME": tmp})
    try:
        read_raw(s, 0.8)
        t0 = cpu_ticks(s.pid)
        read_raw(s, 3.0)
        used = cpu_ticks(s.pid) - t0
        hz = os.sysconf("SC_CLK_TCK")
        rep.add(used <= 0.03 * 3 * hz, "S7 idle 3 s: ~0 % CPU", f"{used} ticks ({100 * used / (3 * hz):.1f} %)")
    finally:
        kill(s)


def main():
    rep = Report("SIGNAL MATRIX")
    cases = [lambda t: helper_death(rep, t, signal.SIGKILL, "S1 preview helper killed: Duop survives"),
             lambda t: helper_death(rep, t, signal.SIGSEGV, "S2 helper SIGSEGV: UI tty untouched"),
             lambda t: graceful(rep, t, signal.SIGTERM), lambda t: graceful(rep, t, signal.SIGINT),
             lambda t: fatal(rep, t, signal.SIGSEGV), lambda t: fatal(rep, t, signal.SIGABRT),
             lambda t: fatal(rep, t, signal.SIGFPE), lambda t: hangup(rep, t),
             lambda t: winch_storm(rep, t), lambda t: idle_cpu(rep, t)]
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            case(tmp)
    return rep.finish()


if __name__ == "__main__":
    sys.exit(main())
