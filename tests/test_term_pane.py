#!/usr/bin/env python3
"""TDD tests for Level 2.9: Embedded Bottom PTY Terminal (Ctrl+`)."""

import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def wait_for_text(sess, text, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.06)
        if text in sess.vt.full_text():
            return True
    return False


def run_tests():
    tmp = tempfile.mkdtemp(prefix="duop_tp_")
    try:
        s = PtySession(BINARY, ["--lang", "en", tmp, tmp], cols=100, rows=30)
        try:
            assert wait_for_text(s, "Help"), "Initial UI did not render"

            # TP1: Toggle embedded PTY terminal with Ctrl+` (\x00)
            os.write(s.master, b"\x00")
            assert wait_for_text(s, "Terminal", timeout=2.0), (
                f"Embedded terminal pane did not open on Ctrl+`:\n{s.vt.full_text()}"
            )
            os.write(s.master, b"echo DUOP_PTY_OK\r")
            assert wait_for_text(s, "DUOP_PTY_OK", timeout=3.0), (
                f"Did not see shell output DUOP_PTY_OK:\n{s.vt.full_text()}"
            )
            print("[PASS] TP1. Embedded PTY terminal opened and ran shell command")

            # TP2: Toggle Ctrl+` off then back on (persistent shell session)
            os.write(s.master, b"\x00")
            time.sleep(0.15)
            s.drain(0.05)
            assert "Terminal" not in s.vt.full_text(), (
                f"Terminal pane did not hide on second Ctrl+`:\n{s.vt.full_text()}"
            )
            os.write(s.master, b"\x00")
            assert wait_for_text(s, "DUOP_PTY_OK", timeout=2.0), (
                f"Persistent terminal buffer not restored:\n{s.vt.full_text()}"
            )
            print("[PASS] TP2. Terminal pane toggles cleanly and preserves session")

            os.write(s.master, b"\x00")
            time.sleep(0.05)
            os.write(s.master, b"\x1b[21~")
            s.wait_exit(2.0)
        finally:
            try:
                os.kill(s.pid, 9)
                os.waitpid(s.pid, 0)
            except OSError:
                pass

        print("ALL TERMINAL PANE TESTS PASSED.")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    run_tests()
