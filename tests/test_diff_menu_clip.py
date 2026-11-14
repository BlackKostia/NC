#!/usr/bin/env python3
"""TDD tests for Level 2.8: Dir Diff/Sync, Context Menu, Mouse DnD, OSC 52."""

import base64
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
    tmp = tempfile.mkdtemp(prefix="duop_dmc_")
    try:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, "same.txt"), "w") as f:
            f.write("abc")
        with open(os.path.join(right, "same.txt"), "w") as f:
            f.write("abc")
        with open(os.path.join(left, "diff.txt"), "w") as f:
            f.write("12345")
        with open(os.path.join(right, "diff.txt"), "w") as f:
            f.write("1")
        with open(os.path.join(left, "only_l.txt"), "w") as f:
            f.write("new")

        s = PtySession(BINARY, ["--lang", "en", left, right], cols=100, rows=30)
        try:
            assert wait_for_text(s, "only_l.txt"), "Initial left pane did not render"

            # DM1: Dir Diff (Alt+=) marks diff.txt and only_l.txt (2 items)
            os.write(s.master, b"\x1b=")
            assert wait_for_text(s, "Diff: 2", timeout=2.0), (
                f"Expected 'Diff: 2' after Alt+=, screen:\n{s.vt.full_text()}"
            )
            print("[PASS] DM1. Dir Diff (Alt+=) detected 2 differing/missing entries")

            # DM2: Right-click context menu on row 6 (1-based) col 6 (1-based) -> diff.txt
            os.write(s.master, b"\x1b[<2;6;6M")
            os.write(s.master, b"\x1b[<2;6;6m")
            assert wait_for_text(s, "Copy Path", timeout=2.0), (
                f"Context menu did not appear on right-click:\n{s.vt.full_text()}"
            )
            # Move down to "Copy Path" (items: View, Copy, Move, Copy Path, Delete -> 3 Downs)
            os.write(s.master, b"\x1b[B\x1b[B\x1b[B\r")
            expected_b64 = base64.b64encode(
                os.path.join(left, "diff.txt").encode()
            ).decode()
            osc_seq = f"\x1b]52;c;{expected_b64}\x07"
            deadline = time.monotonic() + 2.0
            found_osc = False
            while time.monotonic() < deadline:
                s.drain(0.05)
                if osc_seq in s.vt.raw_stream:
                    found_osc = True
                    break
            assert found_osc, f"OSC 52 clipboard sequence not emitted: expected {osc_seq!r}"
            print("[PASS] DM2. Right-click context menu + OSC 52 Copy Path")

            # DM3: Mouse Drag-and-Drop from left pane (col 6, row 6) to right pane (col 65, row 6)
            os.write(s.master, b"\x1b[<0;6;6M")
            os.write(s.master, b"\x1b[<32;65;6M")
            os.write(s.master, b"\x1b[<0;65;6m")
            assert wait_for_text(s, "Copy", timeout=2.0), (
                f"Mouse DnD did not open Copy confirmation:\n{s.vt.full_text()}"
            )
            os.write(s.master, b"\x1b")  # cancel dialog
            time.sleep(0.1)
            print("[PASS] DM3. Mouse Drag-and-Drop from left pane to right pane")

            os.write(s.master, b"\x1b[21~")
            s.wait_exit(2.0)
        finally:
            try:
                os.kill(s.pid, 9)
                os.waitpid(s.pid, 0)
            except OSError:
                pass

        print("ALL DIFF/MENU/CLIP TESTS PASSED.")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    run_tests()
