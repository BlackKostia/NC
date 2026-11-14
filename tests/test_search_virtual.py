#!/usr/bin/env python3
"""TDD tests for ROADMAP 1.5: Recursive Search (name mask + content grep)
into Virtual Panel (VIRTUAL_SEARCH) and Enter jump to original file."""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from test_pty import PtySession

BINARY = "./duop"


def wait_for(sess: PtySession, pred, msg: str, timeout: float = 2.5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.05)
        if pred():
            return
    raise AssertionError(f"timeout waiting for: {msg}\nscreen:\n{sess.vt.full_text()}")


def wait_text(sess: PtySession, needle: str, timeout: float = 2.5) -> None:
    wait_for(sess, lambda: needle in sess.vt.full_text(), f"text {needle!r}", timeout)


def test_recursive_name_search_and_jump() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_srch_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        deep = os.path.join(left, "a", "b")
        other = os.path.join(left, "c")
        os.makedirs(deep)
        os.makedirs(other)
        os.makedirs(right)
        with open(os.path.join(deep, "app.log"), "w") as f:
            f.write("hello world\n")
        with open(os.path.join(other, "err.log"), "w") as f:
            f.write("NEEDLE_42 here\n")
        with open(os.path.join(other, "ignore.txt"), "w") as f:
            f.write("nothing\n")

        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            wait_text(sess, "a")
            # Ctrl+F opens SearchDialog
            sess.send(b"\x06", wait=0.2)
            wait_text(sess, "Recursive Search")
            sess.send(b"*.log\r", wait=0.3)

            wait_text(sess, "a/b/app.log")
            wait_text(sess, "c/err.log")
            assert "ignore.txt" not in sess.vt.full_text()

            # Press Enter on a/b/app.log -> jumps to left/a/b with app.log visible
            sess.send(b"\r", wait=0.25)
            wait_text(sess, "app.log")
            wait_for(sess, lambda: "a/b/app.log" not in sess.vt.full_text(),
                     "exited virtual search panel")

            # Navigate back to left root via Alt+Left, then test content grep search
            sess.send(b"\x1b[1;3D", wait=0.2)
            wait_text(sess, "c")

            sess.send(b"\x06", wait=0.2)
            wait_text(sess, "Recursive Search")
            # Tab to Content (grep) field and type NEEDLE_42
            sess.send(b"\tNEEDLE_42\r", wait=0.3)
            wait_text(sess, "c/err.log")
            assert "app.log" not in sess.vt.full_text()

            # Switch to UA and verify dialog title
            sess.send(b"\x1bl", wait=0.15)
            sess.send(b"\x06", wait=0.2)
            wait_text(sess, "Рекурсивний пошук")
            sess.send(b"\x1b", wait=0.1)
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] S1. Recursive name mask (*.log), content grep (NEEDLE_42), virtual panel jump & EN/UA")


def main() -> None:
    test_recursive_name_search_and_jump()
    print("ALL SEARCH VIRTUAL PANEL TESTS PASSED.")


if __name__ == "__main__":
    main()
