#!/usr/bin/env python3
"""End-to-end PTY tests for Duop 2.3: ncdu Disk Usage Mode (Alt+D)."""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession
from du_util import du_text  # allocated bytes like `du` (st_blocks * 512, dirs included)

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
            f.write(b"A" * 524288)            # keeps big_dir the largest entry on any filesystem
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
            wait_for(sess, du_text(big))
            screen = sess.vt.full_text()
            assert "█" in screen or "▓" in screen or "%" in screen, f"Missing usage bar:\n{screen}"
            pos_big = screen.find("big_dir")
            pos_sml = screen.find("small_dir")
            assert 0 <= pos_big < pos_sml, (
                f"Expected descending size order big_dir < small_dir:\n{screen}"
            )
            assert du_text(os.path.join(l, "medium.bin")) in screen and du_text(small) in screen, \
                f"Missing file/dir sizes:\n{screen}"
            assert du_text(many_dir) in screen, f"Missing 70-file batched dir size:\n{screen}"
            # Descend into big_dir
            sess.send(b"\x1b[B")  # Down from .. to big_dir
            sess.send(b"\r")
            wait_for(sess, du_text(os.path.join(big, "nested_sub")))
            # Return to parent with Backspace -> big_dir keeps its total
            sess.send(b"\x7f")
            wait_for(sess, du_text(big))
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


def test_disk_usage_batch_and_cache_nav():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        # 130 subdirectories (> 2 * DU_BATCH=64) to exercise batched dir stat & cache
        for i in range(130):
            d = os.path.join(l, f"d{i:03d}")
            os.makedirs(d)
            with open(os.path.join(d, "f.bin"), "wb") as f:
                f.write(b"Z" * (4096 if i == 0 else 1024))
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            sess.send(b"\x1bd")
            wait_for(sess, "Disk Usage")
            wait_for(sess, du_text(os.path.join(l, "d000")))
            # Navigate into d000 and back via Backspace (cached)
            sess.send(b"\x1b[B")
            t0 = time.monotonic()
            sess.send(b"\r")
            wait_for(sess, "f.bin", timeout=1.0)
            sess.send(b"\x7f")
            wait_for(sess, "d129" if "d129" in sess.vt.full_text() else du_text(os.path.join(l, "d000")),
                     timeout=1.0)
            elapsed = time.monotonic() - t0
            assert elapsed < 1.0, f"Cached navigation took too long: {elapsed:.3f}s"
            print(f"[PASS] DU3. Batched dir stat & fast cached navigation ({elapsed*1000:.1f} ms)")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_disk_usage_parallel_subtrees():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l); os.makedirs(r)
        # 8 independent subtrees with nested dirs to exercise multi-threaded walk
        for i in range(8):
            sub = os.path.join(l, f"tree_{i}", "nested")
            os.makedirs(sub)
            with open(os.path.join(sub, "payload.bin"), "wb") as f:
                f.write(b"P" * ((i + 1) * 4096))
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            sess.send(b"\x1bd")
            wait_for(sess, "Disk Usage")
            wait_for(sess, du_text(os.path.join(l, "tree_7")))
            screen = sess.vt.full_text()
            assert "tree_7" in screen and "tree_0" in screen, f"Missing subtrees:\n{screen}"
            assert screen.find("tree_7") < screen.find("tree_0"), f"Wrong sort order:\n{screen}"
            print("[PASS] DU4. Parallel multi-subtree Disk Usage scan & descending sort")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_disk_usage_single_nested_miss():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        deep = os.path.join(l, "parent_dir", "child_dir", "grandchild_dir")
        os.makedirs(deep); os.makedirs(r)
        with open(os.path.join(deep, "data.bin"), "wb") as f:
            f.write(b"D" * 8192)
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            # Enter parent_dir first, THEN toggle Alt+D (exercises miss_cnt == 1 with depth >= 1)
            sess.send(b"\x1b[B", wait=0.1)
            sess.send(b"\r", wait=0.2)
            wait_for(sess, "child_dir")
            sess.send(b"\x1bd", wait=0.25)
            wait_for(sess, "Disk Usage")
            wait_for(sess, du_text(os.path.join(l, "parent_dir", "child_dir")))
            print("[PASS] DU5. Single nested miss (miss_cnt == 1, depth >= 1) without crash")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_disk_usage_en()
    test_disk_usage_ua()
    test_disk_usage_batch_and_cache_nav()
    test_disk_usage_parallel_subtrees()
    test_disk_usage_single_nested_miss()
    print("ALL DISK USAGE TESTS PASSED.")
