#!/usr/bin/env python3
"""Background (non-blocking) file operations: worker process, ProgressDialog, pause/cancel, EN/UA.

A named FIFO is used as a deterministic "slow" source: the background worker blocks in
open()/read() until the test feeds it, so UI responsiveness, progress, pause and
cancellation can be verified without timing races.
"""

import errno
import fcntl
import hashlib
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_ESC = b"\x1b"
KEY_F5 = b"\x1b[15~"
KEY_F6 = b"\x1b[17~"
KEY_F8 = b"\x1b[19~"
KEY_ALT_J = b"\x1bj"
KEY_ALT_O_UA = b"\x1b" + "о".encode("utf-8")   # Alt+J on Ukrainian layout
KEY_UA_C = "с".encode("utf-8")                  # 'C' key on Ukrainian layout
ROWS = 35
STATUS_ROW = ROWS - 2


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def wait_for_text(sess: PtySession, needle: str, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        if needle in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {needle!r}; screen:\n{sess.vt.full_text()}")


def wait_for_gone(sess: PtySession, needle: str, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        if needle not in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {needle!r} to disappear; screen:\n{sess.vt.full_text()}")


def wait_until(pred, what: str, timeout: float = 3.0, sess: PtySession | None = None) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sess is not None:
            sess.drain(wait=0.03)
        else:
            time.sleep(0.03)
        if pred():
            return
    raise AssertionError(f"Timed out waiting for: {what}")


def focus_by_filter(sess: PtySession, name_substr: str) -> None:
    sess.send(b"/", wait=0.05)
    sess.send(name_substr.encode("utf-8") + b"\r", wait=0.06)
    sess.send(KEY_DOWN, wait=0.05)


def start_copy(sess: PtySession, title: str = "Copy") -> None:
    sess.send(KEY_F5, wait=0.06)
    wait_for_text(sess, title)
    sess.send(b"\r", wait=0.08)


def open_fifo_writer(path: str, timeout: float = 3.0) -> int:
    """Open FIFO for writing once the background worker has opened it for reading."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno != errno.ENXIO:
                raise
            time.sleep(0.02)
            continue
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
        return fd
    raise AssertionError("Background worker never opened the FIFO for reading")


def fifo_has_no_reader(path: str) -> bool:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        return exc.errno == errno.ENXIO
    os.close(fd)
    return False


def safe_close(fd: int) -> None:
    try:
        os.close(fd)
    except OSError:
        pass


def make_tree(left: str, right: str) -> dict:
    os.makedirs(left)
    os.makedirs(right)
    fifo = os.path.join(left, "slow.fifo")
    os.mkfifo(fifo)
    small = os.path.join(left, "small.txt")
    with open(small, "wb") as f:
        f.write(b"small-keep\n")
    big = os.path.join(left, "big.bin")
    block = bytes((i * 131 + 7) & 0xFF for i in range(1 << 20))
    with open(big, "wb") as f:
        for i in range(24):
            f.write(block[i:] + block[:i])
        f.write(b"tail-bytes-123")
    tree = os.path.join(left, "tree_dir")
    for d in range(4):
        sub = os.path.join(tree, f"sub_{d}")
        os.makedirs(sub)
        for i in range(60):
            with open(os.path.join(sub, f"f_{i:03d}.txt"), "w", encoding="utf-8") as f:
                f.write(f"payload {d}/{i}\n")
    return {"fifo": fifo, "small": small, "big": big, "tree": tree}


def test_nonblocking_ui_background_and_cancel(tmp: str) -> None:
    left, right = os.path.join(tmp, "l1"), os.path.join(tmp, "r1")
    p = make_tree(left, right)
    sess = PtySession(BINARY, ["--lang", "en", left, right], rows=ROWS)
    try:
        sess.drain(0.25)
        focus_by_filter(sess, "slow.fifo")
        start_copy(sess)

        # B1: Progress dialog appears while the worker is blocked on the FIFO
        wait_for_text(sess, "Copying")
        for token in (" Pause ", " Background ", " Cancel ", "slow.fifo", "ETA"):
            wait_for_text(sess, token, timeout=1.5)
        assert "Copy destination path:" not in sess.vt.full_text()
        print("[PASS] B1. ProgressDialog (title, file, ETA, Pause/Background/Cancel) while worker runs")

        # B2: Esc hides dialog to background; status bar carries progress + hotkey
        sess.send(KEY_ESC, wait=0.1)
        wait_for_gone(sess, " Background ")
        wait_for_text(sess, "Alt+J")
        assert "Copying" in sess.vt.row_text(STATUS_ROW), f"Status row lacks task: {sess.vt.row_text(STATUS_ROW)!r}"

        # UI stays fully interactive while the worker is still blocked
        t0 = time.monotonic()
        sess.send(b"/", wait=0.05)
        wait_for_text(sess, "Live Filter", timeout=1.0)
        assert time.monotonic() - t0 < 1.0, "UI blocked while background task runs"
        sess.send(KEY_ESC, wait=0.08)
        wait_for_gone(sess, "Live Filter")
        print("[PASS] B2. Background mode: status-bar progress + fully responsive UI (dialogs open instantly)")

        # B3: Click on status bar reopens the dialog; Alt+J toggles it
        sess.send_mouse(0, 5, STATUS_ROW, "M", wait=0.05)
        sess.send_mouse(0, 5, STATUS_ROW, "m", wait=0.05)
        wait_for_text(sess, " Background ")
        sess.send(KEY_ALT_J, wait=0.1)
        wait_for_gone(sess, " Background ")
        sess.send(KEY_ALT_J, wait=0.1)
        wait_for_text(sess, " Background ")
        print("[PASS] B3. Status-bar click & Alt+J reopen/hide ProgressDialog")

        # B4: Cancel interrupts a worker blocked in open() of the FIFO
        sess.send(b"c", wait=0.1)
        wait_for_text(sess, "Operation canceled")
        wait_for_gone(sess, " Background ")
        assert not os.path.lexists(os.path.join(right, "slow.fifo")), "Canceled copy left a destination file"
        assert os.path.exists(p["fifo"]), "FIFO source vanished"
        wait_until(lambda: fifo_has_no_reader(p["fifo"]), "worker released FIFO after cancel")
        print("[PASS] B4. Cancel stops blocked worker, no destination residue, source intact")

        sess.send(KEY_ESC, wait=0.05)
        sess.send(b"q", wait=0.05)
        assert sess.wait_exit(timeout=2.0) == 0
    finally:
        pass


def test_streaming_progress_pause_resume(tmp: str) -> None:
    left, right = os.path.join(tmp, "l2"), os.path.join(tmp, "r2")
    p = make_tree(left, right)
    dst = os.path.join(right, "slow.fifo")
    sess = PtySession(BINARY, ["--lang", "en", left, right], rows=ROWS)
    wfd = -1
    try:
        sess.drain(0.25)
        focus_by_filter(sess, "slow.fifo")
        start_copy(sess)
        wfd = open_fifo_writer(p["fifo"])
        wait_until(lambda: os.path.exists(dst), "destination created by worker")

        chunk1 = bytes((i * 7) & 0xFF for i in range(256 * 1024))
        os.write(wfd, chunk1)
        wait_until(lambda: os.path.getsize(dst) == len(chunk1), "first chunk copied")
        wait_for_text(sess, " Background ")       # ProgressDialog is up
        wait_for_text(sess, "256 K  ·  Files")    # bytes row of the dialog
        wait_for_text(sess, "/s")
        print("[PASS] B5. Live byte progress & transfer speed rendered while streaming")

        # Pause -> worker stopped (SIGSTOP), data must not advance
        sess.send(b"p", wait=0.1)
        wait_for_text(sess, "Paused")
        wait_for_text(sess, " Resume ")
        os.write(wfd, b"PAUSED-DATA")
        time.sleep(0.4)
        assert os.path.getsize(dst) == len(chunk1), "Worker kept copying while paused"

        # Resume -> data flows again
        sess.send(b"p", wait=0.1)
        wait_for_text(sess, " Pause ")
        wait_until(lambda: os.path.getsize(dst) == len(chunk1) + 11, "copy resumed after pause")
        print("[PASS] B6. Pause (SIGSTOP) freezes worker, Resume continues exactly where it stopped")

        os.close(wfd)
        wfd = -1
        wait_for_text(sess, "Copied successfully")
        wait_for_gone(sess, " Background ")
        with open(dst, "rb") as f:
            assert f.read() == chunk1 + b"PAUSED-DATA", "Streamed copy content mismatch"
        print("[PASS] B7. Completion closes dialog, reports success, payload byte-exact")

        # Cancel mid-stream removes the partially written destination file
        os.unlink(dst)
        sess.send(KEY_ESC, wait=0.05)
        focus_by_filter(sess, "slow.fifo")
        start_copy(sess)
        wfd = open_fifo_writer(p["fifo"])
        os.write(wfd, b"x" * 65536)
        wait_until(lambda: os.path.exists(dst) and os.path.getsize(dst) == 65536, "partial data copied")
        wait_for_text(sess, " Cancel ")
        cx, cy = sess.vt.find_text(" Cancel ", rightmost=True)
        sess.send_mouse(0, cx + 2, cy, "M", wait=0.05)
        sess.send_mouse(0, cx + 2, cy, "m", wait=0.05)
        wait_for_text(sess, "Operation canceled")
        assert not os.path.lexists(dst), "Canceled copy left a partial (corrupt) destination file"
        safe_close(wfd)
        wfd = -1
        print("[PASS] B8. Mouse Cancel mid-stream unlinks partial destination (no corrupt residue)")

        sess.send(KEY_ESC, wait=0.05)
        sess.send(b"q", wait=0.05)
        assert sess.wait_exit(timeout=2.0) == 0
    finally:
        if wfd >= 0:
            safe_close(wfd)


def test_busy_quit_and_bulk(tmp: str) -> None:
    left, right = os.path.join(tmp, "l3"), os.path.join(tmp, "r3")
    p = make_tree(left, right)
    big_hash = sha256_file(p["big"])
    sess = PtySession(BINARY, ["--lang", "en", left, right], rows=ROWS)
    try:
        sess.drain(0.25)

        # Bulk regression: progress hooks must not corrupt data (24 MiB copy, tree move, tree delete)
        focus_by_filter(sess, "big.bin")
        start_copy(sess)
        wait_for_text(sess, "Copied successfully", timeout=10.0)
        assert sha256_file(os.path.join(right, "big.bin")) == big_hash, "Background copy corrupted data"
        sess.send(KEY_ESC, wait=0.05)

        focus_by_filter(sess, "tree_dir")
        sess.send(KEY_F6, wait=0.06)
        wait_for_text(sess, "Move destination path:")
        sess.send(b"\r", wait=0.08)
        wait_for_text(sess, "Moved successfully", timeout=10.0)
        moved = os.path.join(right, "tree_dir")
        assert not os.path.exists(p["tree"]) and len(os.listdir(os.path.join(moved, "sub_3"))) == 60
        sess.send(KEY_ESC, wait=0.05)

        sess.send(b"\t", wait=0.05)
        focus_by_filter(sess, "tree_dir")
        sess.send(KEY_F8, wait=0.06)
        wait_for_text(sess, "Confirm Delete")
        sess.send(b"\r", wait=0.08)
        wait_for_text(sess, "Deleted successfully", timeout=10.0)
        assert not os.path.exists(moved)
        sess.send(KEY_ESC, wait=0.05)
        sess.send(b"\t", wait=0.05)
        print("[PASS] B9. Background bulk copy (24 MiB SHA-256), tree move & recursive delete")

        # Second operation while one is running -> refused, data untouched
        focus_by_filter(sess, "slow.fifo")
        start_copy(sess)
        wait_for_text(sess, " Background ")
        sess.send(KEY_ESC, wait=0.1)
        wait_for_gone(sess, " Background ")
        sess.send(KEY_ESC, wait=0.05)
        focus_by_filter(sess, "small.txt")
        sess.send(KEY_F8, wait=0.06)
        wait_for_text(sess, "Confirm Delete")
        sess.send(b"\r", wait=0.08)
        wait_for_text(sess, "Another background operation is running")
        assert os.path.isfile(p["small"]), "Busy refusal still deleted the file"
        print("[PASS] B10. Concurrent second operation refused (EBUSY) without touching data")

        # Quit while running: confirmation; 'No' keeps running, 'Yes' cancels worker & exits 0
        sess.send(KEY_ESC, wait=0.05)
        sess.send(b"q", wait=0.1)
        wait_for_text(sess, "Cancel it and quit?")
        sess.send(KEY_ESC, wait=0.1)
        wait_for_gone(sess, "Cancel it and quit?")
        # (the EBUSY notice may still occupy the status bar for its 3.5 s lifetime)
        wait_until(lambda: "Copying" in sess.vt.row_text(STATUS_ROW),
                   "task progress back in status bar after declining quit", timeout=5.0, sess=sess)
        sess.send(b"q", wait=0.1)
        wait_for_text(sess, "Cancel it and quit?")
        sess.send(b"\r", wait=0.05)
        rc = sess.wait_exit(timeout=3.0)
        assert rc == 0, f"Unexpected exit code {rc}"
        assert fifo_has_no_reader(p["fifo"]), "Orphaned background worker still holds the FIFO"
        assert not os.path.lexists(os.path.join(right, "slow.fifo"))
        print("[PASS] B11. Quit confirmation while busy: No keeps task, Yes cancels worker & exits 0")
    finally:
        pass


def test_ukrainian(tmp: str) -> None:
    left, right = os.path.join(tmp, "l4"), os.path.join(tmp, "r4")
    p = make_tree(left, right)
    sess = PtySession(BINARY, ["--lang", "ua", left, right], rows=ROWS)
    try:
        sess.drain(0.25)
        focus_by_filter(sess, "slow.fifo")
        start_copy(sess, title="Копіювати")
        wait_for_text(sess, "Копіювання")
        for token in (" Пауза ", " У фоні ", " Скасувати ", "Залишилось"):
            wait_for_text(sess, token, timeout=1.5)
        sess.send(KEY_ESC, wait=0.1)
        wait_for_gone(sess, " У фоні ")
        wait_for_text(sess, "Alt+J: деталі")
        sess.send(KEY_ALT_O_UA, wait=0.1)
        wait_for_text(sess, " У фоні ")
        sess.send("з".encode("utf-8"), wait=0.1)   # 'P' key on Ukrainian layout
        wait_for_text(sess, "Призупинено")
        wait_for_text(sess, " Продовжити ")
        sess.send(KEY_UA_C, wait=0.1)
        wait_for_text(sess, "Операцію скасовано")
        wait_until(lambda: fifo_has_no_reader(p["fifo"]), "UA cancel released FIFO")
        assert not os.path.lexists(os.path.join(right, "slow.fifo"))
        print("[PASS] B12. Ukrainian ProgressDialog, Alt+о, з (pause), с (cancel) & status texts")
        sess.send(KEY_ESC, wait=0.05)
        sess.send(b"q", wait=0.05)
        assert sess.wait_exit(timeout=2.0) == 0
    finally:
        pass


def main() -> None:
    if not os.path.isfile(BINARY):
        raise SystemExit(f"Binary not found: {BINARY}")
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="duop_bg_") as tmp:
        test_nonblocking_ui_background_and_cancel(tmp)
        test_streaming_progress_pause_resume(tmp)
        test_busy_quit_and_bulk(tmp)
        test_ukrainian(tmp)
    print(f"ALL BACKGROUND TASK TESTS PASSED ({time.monotonic() - t0:.2f}s).")


if __name__ == "__main__":
    main()
