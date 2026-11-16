#!/usr/bin/env python3
"""Deterministic fault-tolerance probes for Duop (real PTY, no injection).

Each probe sets up one hazardous situation and checks an operator-level invariant:
no data destroyed without confirmation, no wrong target, no hang, terminal restored.

    probes.py [name ...]        (no names = all)
"""

from __future__ import annotations

import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import flab  # noqa: E402
from flab import K_DOWN, K_ESC, K_F3, K_F5, K_F8, K_F10  # noqa: E402

K_F2 = b"\x1bOQ"
RESULTS = []


def report(ok, name, detail):
    RESULTS.append((ok, name))
    print(f"[{'PASS' if ok else 'FAIL'}] {name} -- {detail}", flush=True)


def session(left, right, home, cwd=None, preexec_limits=None):
    argv = [flab.DUOP, str(left), str(right)]
    if preexec_limits:
        argv = ["/usr/bin/prlimit"] + preexec_limits + argv
    s = flab.Session(argv, str(cwd or left), {"HOME": str(home)})
    s.wait_for(lambda: s.on_screen("Help"), 3.0)
    s.drain(0.15)
    return s


def finish(s, timeout=2.5):
    """F10 -> (exited, tty problems)."""
    s.send(K_F10, 0.05)
    ok = s.wait_exit(timeout)
    dirty = s.tty_dirty() if ok else ["not exited"]
    s.close()
    return ok, dirty


def dirs():
    base = Path(tempfile.mkdtemp(prefix="probe.", dir="/dev/shm"))
    for d in ("L", "R", "home"):
        (base / d).mkdir()
    return base


def probe_rename_overwrite():
    b = dirs()
    (b / "L/aaa.txt").write_text("AAA-content\n")
    (b / "L/bbb.txt").write_text("BBB-precious\n")
    s = session(b / "L", b / "R", b / "home")
    s.send(K_DOWN, 0.08)                                   # aaa.txt
    s.send(K_F2, 0.15)
    s.send(b"\x15bbb.txt\r", 0.3)                          # Ctrl+U, new name, Enter
    asked = any(w in s.vt.full_text() for w in ("exists", "Overwrite", "overwrite"))
    finish(s)
    survived = (b / "L/bbb.txt").exists() and (b / "L/bbb.txt").read_text() == "BBB-precious\n"
    report(survived, "rename onto an existing file keeps the existing file",
           f"bbb.txt intact={survived}, confirmation/error shown={asked}, files={sorted(os.listdir(b / 'L'))}")
    shutil.rmtree(b)


def probe_path_truncation():
    """cwd of 4090 chars: `cwd/database` does not fit PATH_MAX and must not become `cwd/data`."""
    b = dirs()
    cur = b / "L"
    comp = "p" * 200
    while len(str(cur)) + 1 + len(comp) <= 4090:
        cur = cur / comp
    pad = 4090 - len(str(cur)) - 1
    if pad > 0:
        cur = cur / ("q" * pad)
    fd = os.open(str(b / "L"), os.O_RDONLY)
    os.chdir(str(b / "L"))
    for part in cur.relative_to(b / "L").parts:
        os.mkdir(part)
        os.chdir(part)
    Path("data").write_text("short-name file\n")
    Path("database").write_text("long-name file\n")
    deep = os.getcwd()
    os.chdir("/")
    os.close(fd)
    s = session(deep, b / "R", b / "home", cwd=deep)
    listed = s.on_screen("database")
    s.send(K_DOWN * 2, 0.1)                                # .., data, database
    s.send(K_F8, 0.2)
    s.send(b"\r", 0.6)
    s.wait_for(lambda: bool(s.seen), 2.0)
    seen = sorted(s.seen)
    finish(s)
    os.chdir(deep)
    left = sorted(os.listdir("."))
    os.chdir("/")
    wrong = "data" not in left and "database" in left
    report(not wrong, "delete at the PATH_MAX boundary hits the selected file only",
           f"cwd={len(deep)} chars, listed={listed}, selected 'database', remaining={left}, messages={seen}")
    subprocess.run(["rm", "-rf", str(b)])


def probe_deep_tree(levels=60000):
    """Unbounded recursion: a very deep tree must fail cleanly, never take the UI down."""
    b = dirs()
    os.chdir(str(b / "L"))
    os.mkdir("deep")
    os.chdir("deep")
    for _ in range(levels):
        os.mkdir("d")
        os.chdir("d")
    os.chdir("/")
    s = session(b / "L", b / "R", b / "home")
    s.send(K_DOWN, 0.1)
    s.send(K_F8, 0.2)
    s.send(b"\r", 0.3)
    s.wait_for(lambda: bool(s.seen), 30.0)
    seen = sorted(s.seen)
    alive = not s.exited()
    ok, dirty = finish(s, 4.0)
    still = (b / "L/deep").exists()
    report(alive and ok and not dirty and (not still or "Deleted successfully" not in seen),
           f"delete of a {levels}-level tree fails cleanly or completes",
           f"ui alive={alive}, exit={ok}, tty={dirty or 'restored'}, tree left={still}, messages={seen}")
    subprocess.run(["rm", "-rf", str(b)])


def probe_fifo_view():
    b = dirs()
    os.mkfifo(b / "L/a_fifo")
    (b / "L/z.txt").write_text("z\n")
    s = session(b / "L", b / "R", b / "home")
    s.send(K_DOWN, 0.1)
    s.send(K_F3, 0.5)
    s.send(K_ESC, 0.2)
    ok, dirty = finish(s, 3.0)
    report(ok and not dirty, "F3 on a FIFO without a writer does not freeze the UI",
           f"quit after F3={'ok' if ok else 'HANG (blocked in open/read)'}, tty={dirty or 'restored'}")
    shutil.rmtree(b)


def probe_no_tty():
    b = dirs()
    t0 = time.monotonic()
    p = subprocess.Popen([flab.DUOP, str(b / "L"), str(b / "R")], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"HOME": str(b / "home"), "TERM": "xterm"})
    try:
        p.wait(2.0)
        detail, ok = f"exit code {p.returncode} after {time.monotonic() - t0:.2f}s", True
    except subprocess.TimeoutExpired:
        ticks = sum(int(x) for x in Path(f"/proc/{p.pid}/stat").read_text().rsplit(")", 1)[1].split()[11:13])
        p.kill()
        detail, ok = f"still running after 2 s with stdin=/dev/null ({ticks} CPU ticks -> busy loop)", False
    report(ok, "stdin at EOF / not a terminal: exits instead of spinning", detail)
    shutil.rmtree(b)


def probe_signals():
    names = ["SIGHUP", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGUSR1", "SIGUSR2", "SIGALRM", "SIGXCPU",
             "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGPWR", "SIGSYS", "SIGSTKFLT", "SIGIO", "SIGBUS"]
    bad = []
    for name in names:
        b = dirs()
        s = session(b / "L", b / "R", b / "home")
        os.kill(s.pid, getattr(signal, name))
        s.wait_exit(1.5)
        if s.exited() and s.tty_dirty():
            bad.append(f"{name}:{'+'.join(s.tty_dirty())}")
        elif not s.exited():
            ok, dirty = finish(s)
            if not ok or dirty:
                bad.append(f"{name}:ignored-then-{dirty}")
            shutil.rmtree(b)
            continue
        s.close()
        shutil.rmtree(b)
    report(not bad, "every terminating signal restores the terminal first",
           f"terminal left raw / alt-screen after: {', '.join(bad) or 'none'}")


def probe_tstp():
    b = dirs()
    s = session(b / "L", b / "R", b / "home")
    os.kill(s.pid, signal.SIGTSTP)
    time.sleep(0.4)
    s.drain(0.1)
    stopped = Path(f"/proc/{s.pid}/stat").read_text().rsplit(")", 1)[1].split()[0] == "T"
    dirty = s.tty_dirty() if stopped else []
    os.kill(s.pid, signal.SIGCONT)
    s.drain(0.3)
    ok, _ = finish(s)
    report(not (stopped and dirty), "job-control stop (SIGTSTP) hands back a usable terminal",
           f"stopped={stopped}, terminal while stopped={dirty or 'restored'}, resumes and quits={ok}")
    shutil.rmtree(b)


def probe_escape_names():
    b = dirs()
    evil = "evil\x1b[2J\x1b]0;PWNED\x07name"
    (b / "L" / evil).write_text("x")
    (b / "L" / "line\nbreak\rname").write_text("x")
    s = session(b / "L", b / "R", b / "home")
    s.send(K_DOWN, 0.2)
    raw = bytes(s.raw)
    finish(s)
    leaked = b"\x1b]0;PWNED" in raw or b"evil\x1b[2J" in raw or b"line\nbreak" in raw
    report(not leaked, "control bytes in file names never reach the terminal",
           f"raw ESC/CR/LF from a file name written to the tty={leaked}")
    shutil.rmtree(b)


def probe_worker_kill():
    """SIGKILL the worker (OOM killer) / the UI in the middle of a copy."""
    out = []
    for victim in ("worker", "ui"):
        b = dirs()
        os.mkfifo(b / "L/slow_fifo")
        s = session(b / "L", b / "R", b / "home")
        s.send(K_DOWN, 0.1)
        s.send(K_F5, 0.2)
        s.send(b"\r", 0.5)
        kids = [int(x) for x in subprocess.run(["pgrep", "-P", str(s.pid)], capture_output=True, text=True).stdout.split()]
        if not kids:
            out.append(f"{victim}: no worker found")
            s.close(); shutil.rmtree(b)
            continue
        if victim == "worker":
            os.kill(kids[0], signal.SIGKILL)
            s.wait_for(lambda: bool(s.seen), 3.0)
            ok, dirty = finish(s)
            good = "Copied successfully" not in s.seen and bool(s.seen) and ok and not dirty
            out.append(f"worker killed: messages={sorted(s.seen)}, ui quits={ok} -> {'ok' if good else 'BAD'}")
        else:
            os.kill(s.pid, signal.SIGKILL)
            time.sleep(1.5)
            orphan = Path(f"/proc/{kids[0]}").exists()
            if orphan:
                os.kill(kids[0], signal.SIGKILL)
            out.append(f"ui killed: worker keeps running as an orphan={orphan} -> {'BAD' if orphan else 'ok'}")
            s.close()
        shutil.rmtree(b, ignore_errors=True)
    report(not any("BAD" in o for o in out), "process death in the middle of a copy is contained", "; ".join(out))


def probe_fsize_limit():
    """RLIMIT_FSIZE: the kernel answers with SIGXFSZ, whose default action kills the process."""
    b = dirs()
    (b / "L/blob.bin").write_bytes(os.urandom(300000))
    s = session(b / "L", b / "R", b / "home", preexec_limits=["--fsize=4096"])
    s.send(K_DOWN, 0.1)
    s.send(K_F5, 0.2)
    s.send(b"\r", 0.3)
    s.wait_for(lambda: bool(s.seen), 3.0)
    seen = sorted(s.seen)
    ok, dirty = finish(s)
    dst = b / "R/blob.bin"
    partial = dst.exists() and dst.stat().st_size != 300000
    report(ok and not dirty and "Copied successfully" not in seen and not partial,
           "file-size limit during a copy is reported and leaves no partial file",
           f"messages={seen}, partial destination left={partial}, quit={ok}, tty={dirty or 'restored'}")
    shutil.rmtree(b)


def probe_symlink_delete():
    b = dirs()
    (b / "R/precious").mkdir()
    (b / "R/precious/keep.dat").write_text("keep")
    os.symlink(b / "R/precious", b / "L/alink")
    s = session(b / "L", b / "R", b / "home")
    s.send(K_DOWN, 0.1)
    s.send(K_F8, 0.2)
    s.send(b"\r", 0.4)
    s.wait_for(lambda: bool(s.seen), 2.0)
    finish(s)
    kept = (b / "R/precious/keep.dat").exists()
    report(kept and not os.path.lexists(b / "L/alink"), "deleting a symlink to a directory removes only the link",
           f"target contents intact={kept}, link removed={not os.path.lexists(b / 'L/alink')}")
    shutil.rmtree(b)


PROBES = {"rename": probe_rename_overwrite, "pathmax": probe_path_truncation, "fifo": probe_fifo_view,
          "notty": probe_no_tty, "signals": probe_signals, "tstp": probe_tstp, "escnames": probe_escape_names,
          "kill": probe_worker_kill, "fsize": probe_fsize_limit, "symlink": probe_symlink_delete,
          "deep": probe_deep_tree}


def main() -> int:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    for name in sys.argv[1:] or list(PROBES):
        try:
            PROBES[name]()
        except Exception as exc:                            # a probe must never hide the others
            report(False, name, f"probe error: {exc!r}")
    bad = [n for ok, n in RESULTS if not ok]
    print(f"PROBES: {len(RESULTS) - len(bad)}/{len(RESULTS)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
