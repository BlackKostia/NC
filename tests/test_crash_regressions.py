#!/usr/bin/env python3
"""Crash / hang regressions found by the 2026-11-16 deep audit (monkey fuzz + static scan).

CR1 size-sort click on a large directory (io_uring ring setup flag collision)
CR2 entering an archive while a live filter is active (unsigned count - has_dotdot)
CR3 4-byte / 3-byte UTF-8 names in archive listings and search results (clobbered r9/r10)
CR4 long pane path keeps its tail in the title (str_cat clobbered rcx)
CR5 embedded terminal pane survives 1-column / 1-row terminals (stack smash / endless fill)
"""

import os
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402
from par import run_parallel  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_ESC = b"\x1b"
KEY_CTRL_BACKTICK = b"\x00"          # Ctrl+` toggles the embedded terminal pane
KEY_CTRL_F = b"\x06"                  # search dialog


def exit_state(sess: PtySession) -> str:
    """'alive' while the process runs, else 'SIGnn' / 'exit N' (reaps the child)."""
    pid, status = os.waitpid(sess.pid, os.WNOHANG)
    if pid == 0:
        return "alive"
    if os.WIFSIGNALED(status):
        return f"SIG{os.WTERMSIG(status)}"
    return f"exit {os.WEXITSTATUS(status)}"


def kill_session(sess: PtySession) -> None:
    try:
        os.kill(sess.pid, 9)
        os.waitpid(sess.pid, 0)
    except OSError:
        pass
    try:
        os.close(sess.master)
    except OSError:
        pass


def click(sess: PtySession, x: int, y: int) -> None:
    sess.send_mouse(0, x, y, "M", wait=0.15)
    sess.send_mouse(0, x, y, "m", wait=0.3)


def quit_clean(sess: PtySession) -> None:
    sess.send(b"q", wait=0.2)
    assert sess.wait_exit(3.0) == 0, "q did not exit cleanly"


def test_size_sort_click_large_dir() -> None:
    for count in (70, 400):
        with tempfile.TemporaryDirectory(prefix="cr1_") as tmp:
            left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
            os.makedirs(left)
            os.makedirs(right)
            for i in range(count):
                with open(os.path.join(left, f"f{i:05d}.txt"), "w") as f:
                    f.write("x" * (i % 7))
            sess = PtySession(BINARY, ["--lang", "en", left, right])
            try:
                sess.drain(0.5)
                x, y = sess.vt.find_text("Size")
                click(sess, x + 1, y)
                state = exit_state(sess)
                assert state == "alive", f"{count} files: size-header click -> {state}"
                assert "Size ▲" in sess.vt.row_text(y), f"no ascending size indicator: {sess.vt.row_text(y)!r}"
                click(sess, x + 1, y)
                assert exit_state(sess) == "alive", "second size click (descending) crashed"
                assert "Size ▼" in sess.vt.row_text(y), "no descending size indicator"
                quit_clean(sess)
            finally:
                kill_session(sess)
    print("[PASS] CR1. Size-header click sorts large directories (70/400 files) without crashing")


def make_zip(path: str, names: list[str]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n in names:
            z.writestr(n, b"A" * 100)


def test_archive_with_live_filter() -> None:
    with tempfile.TemporaryDirectory(prefix="cr2_") as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        make_zip(os.path.join(left, "n.zip"), ["a.txt", "b.txt"])
        with open(os.path.join(left, "other.txt"), "w") as f:
            f.write("x")
        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            sess.drain(0.5)
            sess.send(b"/", wait=0.15)
            sess.send(b"n.zip\r", wait=0.3)
            sess.send(KEY_DOWN, wait=0.2)
            sess.send(b"\r", wait=0.7)
            assert exit_state(sess) == "alive", "Enter on archive with a live filter crashed"
            assert "« .." in sess.vt.full_text(), "parent entry must stay visible under a filter"
            sess.send(KEY_ESC, wait=0.3)
            assert "a.txt" in sess.vt.full_text() and "b.txt" in sess.vt.full_text(), "archive entries missing"
            sess.send(KEY_ESC, wait=0.2)
            assert exit_state(sess) == "alive"
        finally:
            kill_session(sess)
    print("[PASS] CR2. Entering an archive with an active live filter keeps '..' and does not crash")


NAME_SETS = {
    "cyrillic": [f"файл{i}.txt" for i in range(6)],
    "cjk": [f"中文{i}.txt" for i in range(6)],
    "emoji": [f"😀{i}.txt" for i in range(6)],
    "mixed": ["a.txt", "ünï.txt", "z.txt", "中.txt", "😀.txt", "b.txt"],
}


def listing_check(kind: str, via: str, names: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cr3_") as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        if via == "search":
            for n in names:
                with open(os.path.join(left, n), "w") as f:
                    f.write("x")
            steps = [KEY_CTRL_F, b"*.txt\r"]
        else:
            make_zip(os.path.join(left, "a.zip"), names)
            steps = [KEY_DOWN, b"\r"]
        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            sess.drain(0.5)
            for s in steps:
                sess.send(s, wait=0.5)
            sess.drain(0.4)
            assert exit_state(sess) == "alive", f"{kind} names via {via}: process died"
            screen = sess.vt.full_text()
            missing = [n for n in names if n not in screen]
            assert not missing, f"{kind} names via {via}: missing {missing}"
        finally:
            kill_session(sess)


def test_multibyte_names_in_virtual_listings() -> None:
    for kind, names in NAME_SETS.items():
        for via in ("zip", "search"):
            listing_check(kind, via, names)
    print("[PASS] CR3. 2/3/4-byte UTF-8 names list correctly in archives and search results")


def test_long_path_title_keeps_tail() -> None:
    with tempfile.TemporaryDirectory(prefix="cr4_") as tmp:
        deep = os.path.join(tmp, "a_very_long_directory_name_number_one",
                            "another_quite_long_directory_name_two", "final_dir_name_here")
        right = os.path.join(tmp, "r")
        os.makedirs(deep)
        os.makedirs(right)
        sess = PtySession(BINARY, ["--lang", "en", deep, right])
        try:
            sess.drain(0.6)
            title = sess.vt.row_text(1)
            assert "…" in title, f"long path should be ellipsized: {title!r}"
            assert "final_dir_name_here" in title, f"title lost the path tail: {title!r}"
        finally:
            kill_session(sess)
    print("[PASS] CR4. Long pane path is shortened from the left and keeps its tail")


def test_terminal_pane_tiny_sizes() -> None:
    with tempfile.TemporaryDirectory(prefix="cr5_") as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)

        def one(cols: int, rows: int) -> None:                       # one pty session per size: the sizes are independent
            sess = PtySession(BINARY, ["--lang", "en", left, right])
            try:
                sess.drain(0.5)
                sess.send(KEY_CTRL_BACKTICK, wait=0.6)
                sess.resize(cols, rows)
                sess.drain(0.8)
                assert exit_state(sess) == "alive", f"terminal pane + {cols}x{rows}: crashed"
                sess.resize(100, 30)
                sess.drain(1.0)
                assert "Name" in sess.vt.full_text(), f"UI did not redraw after restoring size from {cols}x{rows}"
                sess.send(KEY_CTRL_BACKTICK, wait=0.4)
                quit_clean(sess)
            finally:
                kill_session(sess)

        run_parallel([lambda c=c, r=r: one(c, r) for c, r in ((1, 30), (100, 2), (100, 1), (2, 2), (3, 5))])
    print("[PASS] CR5. Embedded terminal pane survives 1-column/1-row terminals and recovers")


def main() -> None:
    run_parallel([test_size_sort_click_large_dir, test_archive_with_live_filter, test_multibyte_names_in_virtual_listings, test_long_path_title_keeps_tail,
                  test_terminal_pane_tiny_sizes])
    print("ALL CRASH REGRESSION TESTS PASSED.")


if __name__ == "__main__":
    main()
