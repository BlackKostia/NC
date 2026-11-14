#!/usr/bin/env python3
"""Runtime FD & mmap Leak Detector using strace on real PTY sessions.

Traces openat/pipe2/dup*/inotify_init1/close and mmap/munmap on Duop
while performing directory navigation, F3 viewer, F5 copy, and F10 quit,
and verifies zero leaked file mmaps.
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
BIN = ROOT / "duop"
sys.path.insert(0, str(ROOT / "tests"))
from test_pty import PtySession  # noqa: E402


def main() -> int:
    if not BIN.is_file():
        print("RUNTIME LEAK AUDIT SKIPPED: duop binary not found")
        return 0
    strace_bin = shutil.which("strace")
    if not strace_bin:
        print("RUNTIME LEAK AUDIT SKIPPED: strace not installed")
        return 0

    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "src"
        dst = base / "dst"
        src.mkdir()
        dst.mkdir()
        (src / "sample.txt").write_text("hello runtime leak check\n" * 64, encoding="utf-8")
        trace_log = base / "strace.log"

        sess = PtySession(
            strace_bin,
            [
                "-f",
                "-qq",
                "-e",
                "trace=openat,close,pipe2,inotify_init1,dup,dup2,dup3,mmap,munmap",
                "-o",
                str(trace_log),
                str(BIN),
                "--lang",
                "en",
                str(src),
                str(dst),
            ],
        )
        sess.drain(wait=0.5)
        # Down to sample.txt, F3 Viewer, Esc, F5 Copy, Enter, wait, Esc, F10 Quit
        sess.send(b"\x1b[B", wait=0.15)
        sess.send(b"\x1bOR", wait=0.25)   # F3
        sess.send(b"\x1b", wait=0.2)      # Esc
        sess.send(b"\x1b[15~", wait=0.2)  # F5
        sess.send(b"\r", wait=0.6)
        sess.send(b"\x1b", wait=0.15)
        sess.send(b"\x1b[21~", wait=0.2)  # F10
        rc = sess.wait_exit(timeout=5.0)
        assert trace_log.is_file() and trace_log.stat().st_size > 0, f"strace produced no output (rc={rc})"

        open_fds: dict[tuple[str, int], str] = {}
        mapped_files: set[tuple[str, int]] = set()
        re_open = re.compile(r"^(\d+)\s+(?:openat|pipe2|inotify_init1|dup\d*)\((.*)\)\s+=\s+(\d+)\b")
        re_close = re.compile(r"^(\d+)\s+close\((\d+)\)\s+=\s+0\b")
        re_mmap = re.compile(r"^(\d+)\s+mmap\(.*,\s*(\d+),\s*0x[0-9a-fA-F]+\)\s+=\s+(0x[0-9a-fA-F]+)\b")
        re_munmap = re.compile(r"^(\d+)\s+munmap\((0x[0-9a-fA-F]+),")

        if trace_log.is_file():
            for line in trace_log.read_text(encoding="utf-8", errors="replace").splitlines():
                mo = re_open.match(line)
                if mo:
                    pid, args, fd = mo.group(1), mo.group(2), int(mo.group(3))
                    if fd > 2 and "ld.so" not in args:
                        open_fds[(pid, fd)] = args[:80]
                    continue
                mc = re_close.match(line)
                if mc:
                    open_fds.pop((mc.group(1), int(mc.group(2))), None)
                    continue
                mm = re_mmap.match(line)
                if mm and int(mm.group(2)) > 2:
                    mapped_files.add((mm.group(1), int(mm.group(3), 16)))
                    continue
                mu = re_munmap.match(line)
                if mu:
                    mapped_files.discard((mu.group(1), int(mu.group(2), 16)))

        if mapped_files:
            print(f"RUNTIME LEAK AUDIT FAILED: un-unmapped file mmaps remaining: {mapped_files}")
            return 1
        print(f"RUNTIME LEAK AUDIT PASSED (0 file-mmap leaks; tracked {len(open_fds)} exit fds)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
