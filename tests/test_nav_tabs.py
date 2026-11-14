#!/usr/bin/env python3
"""TDD tests for ROADMAP 1.3: History (Alt+Left/Right), Tabs (Ctrl+T/W + mouse),
Bookmarks Hotlist (Ctrl+D), and Frecency jump (z)."""

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


def test_history_back_forward() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_hist_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        sub1 = os.path.join(left, "sub1")
        sub2 = os.path.join(sub1, "sub2")
        os.makedirs(sub2)
        os.makedirs(right)
        open(os.path.join(left, "root_mark.txt"), "w").close()
        open(os.path.join(sub1, "sub1_mark.txt"), "w").close()
        open(os.path.join(sub2, "sub2_mark.txt"), "w").close()

        sess = PtySession(BINARY, ["--lang", "en", left, right],
                          extra_env={"XDG_DATA_HOME": tmp})
        try:
            wait_text(sess, "root_mark.txt")
            # Enter sub1 (cursor starts on '..', down 1 -> root_mark or sub1; dirs sort first -> sub1 is row 1)
            sess.send(b"\x1b[B\r", wait=0.2)
            wait_text(sess, "sub1_mark.txt")
            # Enter sub2
            sess.send(b"\x1b[B\r", wait=0.2)
            wait_text(sess, "sub2_mark.txt")

            # Alt+Left -> sub1
            sess.send(b"\x1b[1;3D", wait=0.2)
            wait_text(sess, "sub1_mark.txt")
            # Alt+Left -> left (root)
            sess.send(b"\x1b[1;3D", wait=0.2)
            wait_text(sess, "root_mark.txt")

            # Alt+Right -> sub1
            sess.send(b"\x1b[1;3C", wait=0.2)
            wait_text(sess, "sub1_mark.txt")
            # Alt+Right -> sub2
            sess.send(b"\x1b[1;3C", wait=0.2)
            wait_text(sess, "sub2_mark.txt")

            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] NT1. History Back/Forward (Alt+Left / Alt+Right)")


def test_panel_tabs_kbd_and_mouse() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_tabs_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        dir_a = os.path.join(left, "dir_alpha")
        os.makedirs(dir_a)
        os.makedirs(right)
        open(os.path.join(left, "in_left.txt"), "w").close()
        open(os.path.join(dir_a, "in_alpha.txt"), "w").close()

        sess = PtySession(BINARY, ["--lang", "en", left, right],
                          extra_env={"XDG_DATA_HOME": tmp})
        try:
            wait_text(sess, "in_left.txt")
            # Ctrl+T opens a new tab in active pane
            sess.send(b"\x14", wait=0.2)
            # Tab strip should show 2 tabs: [1:...] [2:...]
            wait_for(sess, lambda: "[1:" in sess.vt.row_text(1) and "[2:" in sess.vt.row_text(1),
                     "two tabs in top border")
            # Enter dir_alpha in tab 2
            sess.send(b"\x1b[B\r", wait=0.2)
            wait_text(sess, "in_alpha.txt")
            wait_for(sess, lambda: "dir_alpha" in sess.vt.row_text(1), "tab 2 title updated")

            # Click tab 1 in row 1
            row1 = sess.vt.row_text(1)
            x1 = row1.find("[1:")
            assert x1 >= 0
            sess.send_mouse(0, x1 + 1, 1, "M", wait=0.05)
            sess.send_mouse(0, x1 + 1, 1, "m", wait=0.2)
            wait_text(sess, "in_left.txt")

            # Middle-click tab 2 to close it
            row1 = sess.vt.row_text(1)
            x2 = row1.find("[2:")
            assert x2 >= 0
            sess.send_mouse(1, x2 + 1, 1, "M", wait=0.05)
            sess.send_mouse(1, x2 + 1, 1, "m", wait=0.2)
            wait_for(sess, lambda: "[2:" not in sess.vt.row_text(1), "tab 2 closed by middle-click")

            # Ctrl+T then Ctrl+W closes tab 2 via keyboard
            sess.send(b"\x14", wait=0.15)
            wait_for(sess, lambda: "[2:" in sess.vt.row_text(1), "tab 2 reopened")
            sess.send(b"\x17", wait=0.15)
            wait_for(sess, lambda: "[2:" not in sess.vt.row_text(1), "tab 2 closed by Ctrl+W")

            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] NT2. Panel Tabs (Ctrl+T, Ctrl+W, left-click switch, middle-click close)")


def test_bookmarks_and_frecency_persistence() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_bm_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        proj = os.path.join(left, "omega_project")
        deep = os.path.join(proj, "deep_target")
        os.makedirs(deep)
        os.makedirs(right)
        open(os.path.join(left, "root_file.txt"), "w").close()
        open(os.path.join(deep, "deep_file.txt"), "w").close()

        env = {"XDG_DATA_HOME": tmp}
        # Session 1: navigate to deep_target (records frecency) and bookmark it (Ctrl+D -> 'a')
        sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env=env)
        try:
            wait_text(sess, "root_file.txt")
            sess.send(b"\x1b[B\r", wait=0.18)  # enter omega_project
            sess.send(b"\x1b[B\r", wait=0.18)  # enter deep_target
            wait_text(sess, "deep_file.txt")

            # Ctrl+D opens Bookmarks dialog
            sess.send(b"\x04", wait=0.2)
            wait_text(sess, "Bookmarks")
            # Press 'a' to add current directory to bookmarks
            sess.send(b"a", wait=0.2)
            wait_text(sess, "deep_target")
            sess.send(b"\x1b", wait=0.15)  # close dialog
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass

        # Session 2: start in root 'left', jump via Ctrl+D bookmark, then back to root & jump via 'z' frecency
        sess2 = PtySession(BINARY, ["--lang", "en", left, right], extra_env=env)
        try:
            wait_text(sess2, "root_file.txt")
            sess2.send(b"\x04", wait=0.2)
            wait_text(sess2, "deep_target")
            sess2.send(b"\r", wait=0.2)
            wait_text(sess2, "deep_file.txt")

            # Go back to root via Alt+Left
            sess2.send(b"\x1b[1;3D", wait=0.2)
            wait_text(sess2, "root_file.txt")

            # Press 'z' for frecency jump
            sess2.send(b"z", wait=0.2)
            wait_text(sess2, "Frecency")
            sess2.send(b"deep\r", wait=0.25)
            wait_text(sess2, "deep_file.txt")

            # Verify UA title on Bookmarks dialog
            sess2.send(b"\x1bl", wait=0.15)
            sess2.send(b"\x04", wait=0.2)
            wait_text(sess2, "Закладки")
            sess2.send(b"\x1b", wait=0.1)
            sess2.send(b"q", wait=0.1)
            assert sess2.wait_exit(2.0) == 0
        finally:
            try:
                sess2.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] NT3. Bookmarks (Ctrl+D) & Frecency (z) with disk persistence + EN/UA")


def main() -> None:
    test_history_back_forward()
    test_panel_tabs_kbd_and_mouse()
    test_bookmarks_and_frecency_persistence()
    print("ALL NAV/TABS/BOOKMARKS/FRECENCY TESTS PASSED.")


if __name__ == "__main__":
    main()
