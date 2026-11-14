#!/usr/bin/env python3
"""Phase-3: multiplexed event loop (zero idle wake-ups), inotify auto-refresh, debounced async
preview (never blocks the UI), DEC 2026 synchronized output and lean frame diffs."""

import os
import re
import select
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")
STRACE = shutil.which("strace")
KEY_DOWN = b"\x1b[B"
KEY_ESC = b"\x1b"


def wait_for(sess, pred, desc, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.03)
        if pred():
            return
    raise AssertionError(f"Timeout waiting for {desc}\n--- SCREEN ---\n{sess.vt.full_text()}")


def wait_text(sess, needle, timeout=5.0):
    wait_for(sess, lambda: needle in sess.vt.full_text(), repr(needle), timeout)


def wait_gone(sess, needle, timeout=5.0):
    wait_for(sess, lambda: needle not in sess.vt.full_text(), f"{needle!r} gone", timeout)


def raw_pump(sess, seconds):
    """Read PTY output for `seconds` without drain()'s quiet-period extension."""
    out = b""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        r, _, _ = select.select([sess.master], [], [], 0.02)
        if r:
            try:
                d = os.read(sess.master, 65536)
            except OSError:
                break
            out += d
            sess.vt.feed(d)
    return out


def test_idle_and_inotify() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_ev_") as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        for i in range(5):
            with open(os.path.join(left, f"base_{i}.txt"), "w") as f:
                f.write("x" * (i + 1))
        trace = os.path.join(tmp, "idle.trace")
        if STRACE:
            sess = PtySession(STRACE, ["-f", "-qq", "-o", trace, "-e", "trace=ppoll,poll,epoll_wait",
                                       BINARY, "--lang", "en", left, right])
        else:
            sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            wait_text(sess, "base_0.txt")
            if STRACE:
                time.sleep(0.5)
                before = sum(1 for _ in open(trace))
                time.sleep(2.0)
                idle = sum(1 for _ in open(trace)) - before
                assert idle <= 2, f"Idle event loop still wakes up ({idle} polls in 2 s)"
                print(f"[PASS] E1. Idle: {idle} wake-ups in 2 s (infinite ppoll timeout)")

            # Timed status message must still expire with an infinite idle timeout
            sess.send(b"\x12", wait=0.1)
            wait_text(sess, "Refreshed")
            wait_gone(sess, "Refreshed", timeout=6.0)
            print("[PASS] E2. Status toast expires on an exact deadline timeout")

            # inotify: external create / delete / modify show up without Ctrl+R
            open(os.path.join(left, "external_new.txt"), "w").close()
            wait_text(sess, "external_new.txt", timeout=3.0)
            os.unlink(os.path.join(left, "base_4.txt"))
            wait_gone(sess, "base_4.txt", timeout=3.0)
            with open(os.path.join(left, "base_0.txt"), "ab") as f:
                f.write(b"y" * 3000)
            wait_text(sess, "2.9 K", timeout=3.0)
            open(os.path.join(right, "right_side.txt"), "w").close()
            wait_text(sess, "right_side.txt", timeout=3.0)
            print("[PASS] E3. inotify auto-refresh: create, delete, size change (both panes)")

            # Marked entries are never wiped by an auto-refresh
            sess.send(b"/", wait=0.05)
            sess.send(b"base_1\r", wait=0.1)
            sess.send(KEY_DOWN, wait=0.05)
            sess.send(b" ", wait=0.1)
            wait_text(sess, "1 selected")
            open(os.path.join(left, "base_1_twin.txt"), "w").close()
            time.sleep(0.8)
            sess.drain(0.2)
            assert "1 selected" in sess.vt.full_text(), "Auto-refresh dropped the user's selection"
            sess.send(KEY_ESC, wait=0.05)
            print("[PASS] E4. Auto-refresh preserves marked entries")
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass


def test_preview_debounce_async_and_sync_output() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_pv_") as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        for i in range(40):
            with open(os.path.join(left, f"p_{i:02d}.txt"), "w") as f:
                f.write(f"content of file number {i:02d}\n")
        os.mkfifo(os.path.join(left, "a_blocking.fifo"))
        trace = os.path.join(tmp, "pv.trace")
        if STRACE:
            sess = PtySession(STRACE, ["-f", "-qq", "-o", trace, "-e", "trace=openat",
                                       BINARY, "--lang", "en", left, right])
        else:
            sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            wait_text(sess, "p_00.txt")
            sess.send(b"\x10", wait=0.2)              # Ctrl+P: live preview
            wait_text(sess, "Live Preview")

            # FIFO preview must not freeze the UI (worker opens non-blocking)
            sess.send(KEY_DOWN, wait=0.2)              # cursor on a_blocking.fifo
            t0 = time.monotonic()
            sess.send(b"\x1bOP", wait=0.1)            # F1 help must open instantly
            wait_text(sess, "Duop Help", timeout=2.0)
            assert time.monotonic() - t0 < 1.5, "Preview of a FIFO blocked the UI"
            sess.send(KEY_ESC, wait=0.1)
            print("[PASS] E5. Async preview: FIFO under cursor never blocks the UI")

            # Burst of cursor moves: debounce collapses previews to (nearly) one read
            mark = sum(1 for _ in open(trace)) if STRACE else 0
            os.write(sess.master, KEY_DOWN * 30)
            raw_pump(sess, 0.6)
            wait_text(sess, "content of file number 29")
            if STRACE:
                lines = open(trace).read().splitlines()[mark:]
                opens = sum(1 for ln in lines if re.search(r'openat\(.*p_\d\d\.txt', ln))
                assert opens <= 4, f"Preview not debounced: {opens} file opens for a 30-key burst"
                print(f"[PASS] E6. Preview debounce: {opens} opens for 30 rapid cursor moves")

            # DEC 2026 synchronized output brackets every frame; small diffs stay small
            sess.vt.raw_stream = ""
            out = b""
            os.write(sess.master, KEY_DOWN)
            out += raw_pump(sess, 0.4)
            txt = out.decode("utf-8", "replace")
            assert "\x1b[?2026h" in txt and "\x1b[?2026l" in txt, "Frames are not wrapped in DEC 2026"
            assert txt.index("\x1b[?2026h") < txt.rindex("\x1b[?2026l")
            assert len(out) < 6000, f"Cursor move re-sent too much ({len(out)} bytes)"
            print(f"[PASS] E7. DEC 2026 synchronized frames; one-row move costs {len(out)} bytes")
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass


def main() -> None:
    t0 = time.monotonic()
    test_idle_and_inotify()
    test_preview_debounce_async_and_sync_output()
    print(f"ALL EVENT-LOOP TESTS PASSED ({time.monotonic() - t0:.2f}s).")


if __name__ == "__main__":
    main()
