#!/usr/bin/env python3
"""End-to-end PTY tests for Duop 2.3: ncdu Disk Usage Mode (Alt+D)."""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def wait_for(sess, text, timeout=2.5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def test_disk_usage_en():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        big = os.path.join(l, "big_dir")
        small = os.path.join(l, "small_dir")
        os.makedirs(os.path.join(big, "nested_sub"))
        os.makedirs(small)
        os.makedirs(r)
        with open(os.path.join(big, "nested_sub", "sub.bin"), "wb") as f:
            f.write(b"S" * 32768)
        # 70 small files (70 * 1024 = 70 KiB) to exercise DU_BATCH=64 io_uring batching
        many_dir = os.path.join(l, "many_dir")
        os.makedirs(many_dir)
        for i in range(70):
            with open(os.path.join(many_dir, f"f{i:03d}.dat"), "wb") as f:
                f.write(b"M" * 1024)
        with open(os.path.join(big, "payload.bin"), "wb") as f:
            f.write(b"A" * 65536)
        with open(os.path.join(l, "medium.bin"), "wb") as f:
            f.write(b"B" * 16384)
        with open(os.path.join(small, "tiny.txt"), "wb") as f:
            f.write(b"C" * 1024)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            # Alt+D enters Disk Usage mode
            sess.send(b"\x1bd")
            wait_for(sess, "Disk Usage")
            wait_for(sess, "96.0 K")
            screen = sess.vt.full_text()
            assert "█" in screen or "▓" in screen or "%" in screen, f"Missing usage bar:\n{screen}"
            pos_big = screen.find("big_dir")
            pos_sml = screen.find("small_dir")
            assert 0 <= pos_big < pos_sml, (
                f"Expected descending size order big_dir < small_dir:\n{screen}"
            )
            assert "16.0 K" in screen and "1.0 K" in screen, f"Missing file/dir sizes:\n{screen}"
            assert "70.0 K" in screen, f"Missing 70-file batched dir size (70.0 K):\n{screen}"
            # Descend into big_dir
            sess.send(b"\x1b[B")  # Down from .. to big_dir
            sess.send(b"\r")
            wait_for(sess, "32.0 K")
            # Return to parent with Backspace -> big_dir must still show 96.0 K
            sess.send(b"\x7f")
            wait_for(sess, "96.0 K")
            sess.send(b"\r", wait=0.2)
            wait_for(sess, "payload.bin")
            # Exit Disk Usage mode via Alt+D
            sess.send(b"\x1bd", wait=0.2)
            assert "Disk Usage" not in sess.vt.full_text(), "Did not exit Disk Usage mode"
            print("[PASS] DU1. Disk Usage mode (Alt+D) recursive sizes, descending sort & bars")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_disk_usage_ua():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        with open(os.path.join(l, "data.bin"), "wb") as f:
            f.write(b"X" * 4096)
        sess = PtySession(BINARY, ["--lang", "ua", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            sess.send(b"\x1bd")
            wait_for(sess, "Аналіз диска")
            print("[PASS] DU2. Ukrainian Disk Usage mode")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_disk_usage_en()
    test_disk_usage_ua()
    print("ALL DISK USAGE TESTS PASSED.")
