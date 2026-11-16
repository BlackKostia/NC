#!/usr/bin/env python3
"""Overwrite is crash-safe: the target stays the complete old file until the new one is complete.

OW1 a canceled overwrite keeps the old destination byte-exact and leaves no temp file behind
OW2 a finished overwrite swaps the new content in atomically (never a partial file at the final name)
OW3 a file in a directory the user cannot write into is still overwritten (in-place fallback)
"""

import os
import stat
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_bg_tasks import open_fifo_writer, safe_close, start_copy, wait_for_text, wait_until  # noqa: E402
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.environ.get("DUOP", os.path.join(REPO_ROOT, "duop"))
KEY_DOWN = b"\x1b[B"
OLD = b"OLD-CONTENT-" * 400


def kill(sess: PtySession) -> None:
    try:
        os.kill(sess.pid, 9)
        os.waitpid(sess.pid, 0)
    except OSError:
        pass
    try:
        os.close(sess.master)
    except OSError:
        pass


def temp_files(directory: str) -> list[str]:
    return [n for n in os.listdir(directory) if n.startswith(".duop-ovw.")]


def streaming_overwrite(tmp: str):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left)
    os.makedirs(right)
    fifo = os.path.join(left, "data.bin")
    os.mkfifo(fifo)
    dst = os.path.join(right, "data.bin")
    with open(dst, "wb") as f:
        f.write(OLD)
    sess = PtySession(BINARY, ["--lang", "en", left, right], rows=35)
    sess.drain(0.4)
    sess.send(KEY_DOWN, wait=0.1)
    start_copy(sess)
    wfd = open_fifo_writer(fifo)
    wait_for_text(sess, "File Conflict", timeout=3.0)
    sess.send(b"o", wait=0.3)                       # Overwrite
    return sess, wfd, left, right, dst


def test_cancel_keeps_old_destination() -> None:
    with tempfile.TemporaryDirectory(prefix="ow1_") as tmp:
        sess, wfd, left, right, dst = streaming_overwrite(tmp)
        try:
            os.write(wfd, b"PARTIAL-NEW-DATA" * 64)
            wait_until(lambda: bool(temp_files(right)) or open(dst, "rb").read() != OLD, "copy started", 3.0, sess)
            time.sleep(0.3)
            assert open(dst, "rb").read() == OLD, "target changed while the new version was still incomplete"
            sess.send(b"c", wait=0.4)
            wait_for_text(sess, "Operation canceled", timeout=3.0)
            assert open(dst, "rb").read() == OLD, "canceled overwrite damaged the old destination"
            assert not temp_files(right), f"temp file left behind: {temp_files(right)}"
            assert os.path.exists(os.path.join(left, "data.bin")), "FIFO source vanished"
        finally:
            safe_close(wfd)
            kill(sess)
    print("[PASS] OW1. Canceled overwrite keeps the old destination byte-exact, no temp residue")


def test_finished_overwrite_is_atomic() -> None:
    with tempfile.TemporaryDirectory(prefix="ow2_") as tmp:
        sess, wfd, left, right, dst = streaming_overwrite(tmp)
        new = bytes((i * 7) & 0xFF for i in range(300000))
        try:
            os.write(wfd, new[:100000])
            time.sleep(0.4)
            assert open(dst, "rb").read() == OLD, "partial new data visible at the final name"
            os.write(wfd, new[100000:])
            os.close(wfd)
            wfd = -1
            wait_for_text(sess, "Copied successfully", timeout=5.0)
            assert open(dst, "rb").read() == new, "overwritten content differs from the source stream"
            assert not temp_files(right), f"temp file left behind: {temp_files(right)}"
            assert stat.S_IMODE(os.stat(dst).st_mode) & 0o600 == 0o600
        finally:
            if wfd >= 0:
                safe_close(wfd)
            kill(sess)
    print("[PASS] OW2. Finished overwrite appears atomically; no partial file at the final name")


def test_unwritable_directory_falls_back_in_place() -> None:
    with tempfile.TemporaryDirectory(prefix="ow3_") as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, "a.txt"), "w") as f:
            f.write("NEW-A")
        dst = os.path.join(right, "a.txt")
        with open(dst, "w") as f:
            f.write("OLD-A")
        os.chmod(right, 0o555)                       # files inside stay writable, the directory is not
        sess = PtySession(BINARY, ["--lang", "en", left, right], rows=35)
        try:
            sess.drain(0.4)
            sess.send(KEY_DOWN, wait=0.1)
            start_copy(sess)
            wait_for_text(sess, "File Conflict", timeout=3.0)
            sess.send(b"o", wait=0.5)
            wait_until(lambda: open(dst).read() == "NEW-A", "in-place overwrite", 3.0, sess)
            assert os.listdir(right) == ["a.txt"]
        finally:
            os.chmod(right, 0o755)
            kill(sess)
    print("[PASS] OW3. Overwrite in a directory without write permission still works in place")


def main() -> None:
    test_cancel_keeps_old_destination()
    test_finished_overwrite_is_atomic()
    test_unwritable_directory_falls_back_in_place()
    print("ALL OVERWRITE ATOMICITY TESTS PASSED.")


if __name__ == "__main__":
    main()
