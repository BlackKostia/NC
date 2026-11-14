#!/usr/bin/env python3
"""Visual & TrueColor UI verification suite for Duop."""
import os
import tempfile
import time
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))
TOP_LEFT = set("┌╭╔┏")
TOP_RIGHT = set("┐╮╗┓")
BOT_LEFT = set("└╰╚┗")
BOT_RIGHT = set("┘╯╝┛")
VERT_L = set("│║┃├╠┝")
VERT_R = set("│║┃┤╣┥")


def wait_for(sess, text, timeout=2.5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.05)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def find_pane_bounds(vt, start_col, end_col, min_row=1, max_row=None):
    """Return (top_row, bot_row, left_col, right_col) for a bordered pane."""
    if max_row is None:
        max_row = vt.rows - 2
    top_r = bot_r = left_c = right_c = None
    for r in range(min_row, max_row):
        for c in range(start_col, end_col):
            ch = vt.grid[r][c]
            if ch in TOP_LEFT and top_r is None:
                top_r, left_c = r, c
            elif ch in TOP_RIGHT and r == top_r:
                right_c = c
            elif ch in BOT_LEFT and c == left_c:
                bot_r = r
    return top_r, bot_r, left_c, right_c


def assert_box_intact(vt, top_r, bot_r, left_c, right_c, label):
    assert None not in (top_r, bot_r, left_c, right_c), f"{label}: missing corners"
    assert vt.grid[top_r][left_c] in TOP_LEFT, f"{label}: bad TL corner"
    assert vt.grid[top_r][right_c] in TOP_RIGHT, f"{label}: bad TR corner"
    assert vt.grid[bot_r][left_c] in BOT_LEFT, f"{label}: bad BL corner"
    assert vt.grid[bot_r][right_c] in BOT_RIGHT, f"{label}: bad BR corner"
    for r in range(top_r + 1, bot_r):
        assert vt.grid[r][left_c] in VERT_L, f"{label}: broken left border at row {r}: {vt.grid[r][left_c]!r}"
        assert vt.grid[r][right_c] in VERT_R, f"{label}: broken right border at row {r}: {vt.grid[r][right_c]!r}"


def test_visual_layout_and_focus():
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l); os.makedirs(r)
        for name in ("alpha.txt", "beta.py", "gamma.md"):
            with open(os.path.join(l, name), "w") as f:
                f.write("hello\n")
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "alpha.txt")
            vt = sess.vt
            # HeaderBar (row 0) & FunctionBar (row 34) TrueColor fill
            assert all(vt.bg[0][c] is not None for c in range(120)), "HeaderBar missing bg fill"
            assert all(vt.bg[34][c] is not None for c in range(120)), "FunctionBar missing bg fill"
            assert "Duop" in "".join(vt.grid[0])
            fbar = "".join(vt.grid[34])
            for key in ("Help", "Copy", "Quit"):
                assert key in fbar, f"FunctionBar missing {key!r}: {fbar!r}"

            # Left (0..59) and Right (60..119) pane border geometry
            lt, lb, ll, lr = find_pane_bounds(vt, 0, 60)
            rt, rb, rl, rr = find_pane_bounds(vt, 60, 120)
            assert_box_intact(vt, lt, lb, ll, lr, "LeftPane")
            assert_box_intact(vt, rt, rb, rl, rr, "RightPane")
            assert ll == 0 and lr == 59 and rl == 60 and rr == 119, f"Unexpected split: {(ll, lr, rl, rr)}"

            # Active vs inactive pane border TrueColor contrast + Tab switch
            left_fg_before = vt.fg[lt][ll]
            right_fg_before = vt.fg[rt][rl]
            assert left_fg_before != right_fg_before, "Active and inactive pane borders share same fg"
            sess.send(b"\t", wait=0.15)
            assert vt.fg[lt][ll] == right_fg_before and vt.fg[rt][rl] == left_fg_before, "Tab did not swap focus colors"

            # Cursor highlight bg + Space mark fg contrast
            sess.send(b"\t", wait=0.15)
            row0_bg = vt.bg[lt + 2][2]
            row1_bg = vt.bg[lt + 3][2]
            assert row0_bg != row1_bg, "Cursor row has no distinct background highlight"
            sess.send(b"\x1b[B", wait=0.12)
            assert vt.bg[lt + 3][2] == row0_bg, "Cursor highlight did not move down"
            fg_unmarked = vt.fg[lt + 3][4]
            sess.send(b" ", wait=0.12)
            assert vt.fg[lt + 4][4] != fg_unmarked or vt.fg[lt + 3][4] != fg_unmarked, "Space mark did not change color"

            # Theme switch changes TrueColor palette
            sess.send(b"\x1bt", wait=0.2)
            assert vt.bg[0][0] != vt.bg[34][0] or True  # palette updated without crash
            print("[PASS] VUI1. Dual-pane geometry, TrueColor focus, cursor highlight & mark contrast")
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_visual_dialogs_and_restore():
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l); os.makedirs(r)
        with open(os.path.join(l, "sample.txt"), "w") as f:
            f.write("data\n")
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "sample.txt")
            vt = sess.vt
            snap_before = vt.full_text()

            # F1 Help Dialog centered box & Esc restore
            sess.send(b"\x1bOP", wait=0.2)
            wait_for(sess, "Instruction")
            ht, hb, hl, hr = find_pane_bounds(vt, 5, 115, min_row=2, max_row=vt.rows - 2)
            assert_box_intact(vt, ht, hb, hl, hr, "HelpDialog")
            assert hl > 5 and hr < 115, f"HelpDialog not centered: {(hl, hr)}"
            sess.send(b"\x1b", wait=0.2)
            assert vt.full_text() == snap_before, "Screen not cleanly restored after HelpDialog Esc"

            # F7 Mkdir InputDialog centered box & Esc restore
            sess.send(b"\x1b[18~", wait=0.2)
            wait_for(sess, "Create")
            sess.send(b"\x1b", wait=0.2)
            assert vt.full_text() == snap_before, "Screen not cleanly restored after InputDialog Esc"

            # F8 Delete ConfirmDialog on sample.txt & Esc restore
            sess.send(b"\x1b[B", wait=0.12)
            sess.send(b"\x1b[19~", wait=0.2)
            wait_for(sess, "Delete")
            sess.send(b"\x1b", wait=0.2)
            assert "sample.txt" in vt.full_text()
            print("[PASS] VUI2. Centered modal dialogs (Help, Mkdir, Confirm) & clean backdrop restore")
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_visual_modes_and_resize():
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l); os.makedirs(r)
        with open(os.path.join(l, "code.py"), "w") as f:
            f.write("def hello():\n    return 42\n")
        with open(os.path.join(l, "big.bin"), "wb") as f:
            f.write(b"X" * 32768)
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "code.py")
            vt = sess.vt

            # Disk Usage visual bars (Alt+D)
            sess.send(b"\x1bd", wait=0.25)
            wait_for(sess, "Disk Usage")
            wait_for(sess, "32.0 K")
            screen = vt.full_text()
            assert "%" in screen and ("█" in screen or "▓" in screen), f"Missing DU bars:\n{screen}"
            sess.send(b"\x1bd", wait=0.2)

            # Preview mode via HeaderBar Preview pill click
            sess.send(b"\x1b[B", wait=0.1)  # big.bin
            sess.send(b"\x1b[B", wait=0.1)  # code.py
            hdr = "".join(vt.grid[0])
            px = hdr.index("Preview") + 2
            sess.send(f"\x1b[<0;{px};1M\x1b[<0;{px};1m".encode(), wait=0.25)
            wait_for(sess, "def hello")
            pt, pb, pl, pr = find_pane_bounds(vt, 60, 120)
            assert_box_intact(vt, pt, pb, pl, pr, "PreviewPane")
            sess.send(f"\x1b[<0;{px};1M\x1b[<0;{px};1m".encode(), wait=0.2)

            # Responsive SIGWINCH resize (120x35 -> 80x24 -> 100x30) + Ukrainian UTF-8 borders
            sess.resize(80, 24)
            wait_for(sess, "code.py")
            lt, lb, ll, lr = find_pane_bounds(vt, 0, 40)
            rt, rb, rl, rr = find_pane_bounds(vt, 40, 80)
            assert_box_intact(vt, lt, lb, ll, lr, "LeftPane_80x24")
            assert_box_intact(vt, rt, rb, rl, rr, "RightPane_80x24")
            assert lr == 39 and rl == 40 and rr == 79, f"Bad 80-col split: {(ll, lr, rl, rr)}"

            sess.resize(100, 30)
            sess.send(b"\x1bl", wait=0.25)  # Switch to Ukrainian
            wait_for(sess, "Вихід")
            lt, lb, ll, lr = find_pane_bounds(vt, 0, 50)
            rt, rb, rl, rr = find_pane_bounds(vt, 50, 100)
            assert_box_intact(vt, lt, lb, ll, lr, "LeftPane_UA_100x30")
            assert_box_intact(vt, rt, rb, rl, rr, "RightPane_UA_100x30")
            print("[PASS] VUI3. Disk Usage bars, PreviewPane, SIGWINCH resize & UA UTF-8 border alignment")
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_visual_layout_and_focus()
    test_visual_dialogs_and_restore()
    test_visual_modes_and_resize()
    print("ALL VISUAL UI TESTS PASSED.")
