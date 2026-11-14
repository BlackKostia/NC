#!/usr/bin/env python3
"""TDD test for 2.6 Bulk Rename (Alt+B): templates {n}/{name}/{ext}, find/replace, live preview, EN/UA."""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def wait_for(sess, text, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def test_bulk_rename():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        for fn in ["alpha.txt", "beta.txt"]:
            with open(os.path.join(l, fn), "w") as f:
                f.write(fn)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "alpha.txt")
            # Mark alpha.txt and beta.txt
            sess.send(b"\x1b[B")  # alpha.txt
            sess.send(b" ")       # mark alpha.txt (cursor advances to beta.txt)
            sess.send(b" ")       # mark beta.txt
            # Open Bulk Rename (Alt+B)
            sess.send(b"\x1bb")
            wait_for(sess, "Bulk Rename")
            # Type template: doc_{n}.{ext}
            sess.send(b"doc_{n}.{ext}")
            wait_for(sess, "doc_1.txt")
            wait_for(sess, "doc_2.txt")
            sess.send(b"\r")
            wait_for(sess, "doc_1.txt")
            assert os.path.exists(os.path.join(l, "doc_1.txt"))
            assert os.path.exists(os.path.join(l, "doc_2.txt"))
            assert not os.path.exists(os.path.join(l, "alpha.txt"))
            print("[PASS] BR1. Template {n}.{ext} + live preview + rename on disk")

            # BR2: Find & Replace
            sess.send(b"\x1b[H")  # Home -> ..
            sess.send(b"\x1b[B")  # doc_1.txt
            sess.send(b" ")       # mark doc_1.txt
            sess.send(b" ")       # mark doc_2.txt
            sess.send(b"\x1bb")
            wait_for(sess, "Bulk Rename")
            sess.send(b"\t")      # Find
            sess.send(b"doc")
            sess.send(b"\t")      # Replace
            sess.send(b"note")
            wait_for(sess, "note_1.txt")
            sess.send(b"\r")
            wait_for(sess, "note_1.txt")
            assert os.path.exists(os.path.join(l, "note_1.txt"))
            assert os.path.exists(os.path.join(l, "note_2.txt"))
            print("[PASS] BR2. Find & Replace bulk rename")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass

        # BR3: Ukrainian localization
        sess2 = PtySession(BINARY, ["--lang", "ua", l, r], cols=120, rows=35)
        try:
            wait_for(sess2, "note_1.txt")
            sess2.send(b"\x1b[B")
            sess2.send(b"\x1bb")
            wait_for(sess2, "Групове перейменування")
            sess2.send(b"\x1b", wait=0.1)
            print("[PASS] BR3. Ukrainian i18n Bulk Rename")
        finally:
            try:
                os.kill(sess2.pid, 9)
                os.waitpid(sess2.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_bulk_rename()
    print("ALL BULK RENAME TESTS PASSED.")
