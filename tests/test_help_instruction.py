#!/usr/bin/env python3
"""End-to-end PTY test for HelpDialog Overview & Instruction tabs (EN + UA)."""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "duop")


def test_help_instruction_en_and_ua():
    assert os.path.exists(BIN), f"Binary not found: {BIN}"
    with tempfile.TemporaryDirectory() as tmp:
        l_dir = os.path.join(tmp, "left")
        r_dir = os.path.join(tmp, "right")
        os.makedirs(l_dir)
        os.makedirs(r_dir)

        sess = PtySession(BIN, ["--lang", "en", l_dir, r_dir], cols=100, rows=28)
        try:
            sess.drain(0.30)
            sess.send(b"\x1bOP")  # F1
            assert "Overview" in sess.vt.full_text(), "Overview tab missing in EN HelpDialog"
            ix, iy = sess.vt.find_text(" Instruction ")
            assert ix is not None, "Instruction tab missing in EN HelpDialog"
            sess.send_mouse(0, ix + 2, iy, "M")
            sess.send_mouse(0, ix + 2, iy, "m")
            assert "◆ FUNCTION KEYS" in sess.vt.full_text(), "Mouse click did not switch to Instruction"
            sess.send(b"\x1b[6~")  # PgDn
            assert "◆ VIEWER" in sess.vt.full_text() or "Ctrl+K" in sess.vt.full_text(), "Instruction scroll failed"
            sess.send(b"\t")  # Tab back to Overview
            assert "◆ AUTHOR & OPEN-SOURCE LICENSE" in sess.vt.full_text(), "Tab did not switch back to Overview"
            sess.send(b"\x1b")
            sess.send(b"\x1b[21~")  # F10 quit
            assert sess.wait_exit(timeout=3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass
        print("[PASS] H1. Help -> Instruction tab (EN): mouse click, PgDn scroll & Tab switch")

        sess_ua = PtySession(BIN, ["--lang", "ua", l_dir, r_dir], cols=100, rows=28)
        try:
            sess_ua.drain(0.30)
            sess_ua.send(b"\x1bOP")  # F1
            assert "◆ НАВІГАЦІЯ З КЛАВІАТУРИ" in sess_ua.vt.full_text()
            ix, iy = sess_ua.vt.find_text(" Інструкція ")
            assert ix is not None, "Instruction tab missing in UA HelpDialog"
            sess_ua.send_mouse(0, ix + 2, iy, "M")
            sess_ua.send_mouse(0, ix + 2, iy, "m")
            assert "◆ ФУНКЦІОНАЛЬНІ КЛАВІШІ" in sess_ua.vt.full_text(), "UA Instruction tab did not switch"
            sess_ua.send(b"\t")
            assert "◆ НАВІГАЦІЯ З КЛАВІАТУРИ" in sess_ua.vt.full_text(), "Tab did not switch back in UA"
            sess_ua.send(b"\x1b")
            sess_ua.send(b"\x1b[21~")
            assert sess_ua.wait_exit(timeout=3.0) == 0
        finally:
            try:
                os.kill(sess_ua.pid, 9)
                os.waitpid(sess_ua.pid, 0)
            except OSError:
                pass
        print("[PASS] H2. Help -> Instruction tab (UA): mouse click & Tab switch")


if __name__ == "__main__":
    test_help_instruction_en_and_ua()
    print("ALL HELP INSTRUCTION TESTS PASSED.")
