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

            # TP3: UTF-8 (Cyrillic) keystrokes reach the shell
            for ch in "echo ПРИВІТ_ТЕРМ\r":
                os.write(s.master, ch.encode())
                time.sleep(0.01)
            assert wait_for_text(s, "\nПРИВІТ_ТЕРМ", timeout=3.0) or \
                s.vt.full_text().count("ПРИВІТ_ТЕРМ") >= 2, (
                f"Cyrillic input did not reach the shell:\n{s.vt.full_text()}"
            )
            print("[PASS] TP3. UTF-8 keystrokes are forwarded to the shell")

            # TP4: Tab, Esc and arrows are forwarded as VT bytes (seen through cat -vT)
            os.write(s.master, b"clear\r")
            time.sleep(0.3)
            os.write(s.master, b"cat -vT\r")
            time.sleep(0.3)
            for seq in (b"\t", b"\x1b", b"\x1b[A", b"\x1b[D"):
                os.write(s.master, seq)
                time.sleep(0.15)
            os.write(s.master, b"\r")
            assert wait_for_text(s, "^I^[^[[A^[[D", timeout=3.0), (
                f"Tab/Esc/arrow keys were not forwarded to the shell:\n{s.vt.full_text()}"
            )
            os.write(s.master, b"\x04")
            time.sleep(0.3)
            print("[PASS] TP4. Tab/Esc/arrow keys are forwarded as VT sequences")

            # TP5: a visible cursor marks the input position
            os.write(s.master, b"zq")
            assert wait_for_text(s, "$ zq", timeout=2.0), s.vt.full_text()
            c, r = s.vt.find_text("$ zq", rightmost=True)
            cur_bg = s.vt.bg[r][c + 4]
            plain_bg = s.vt.bg[r][c + 8]
            assert cur_bg != plain_bg, (
                f"No visible cursor after typed text ({cur_bg} vs {plain_bg})"
            )
            os.write(s.master, b"\x7f\x7f")
            time.sleep(0.2)
            print("[PASS] TP5. Terminal pane draws a visible input cursor")

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
