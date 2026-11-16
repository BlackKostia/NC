#!/usr/bin/env python3
"""File-pane scrollbar thumb (audit 2026-11-16, live-register scan of FilePane_render__thumb_h).

The scrollbar loop kept the thumb start/end in caller-saved registers (r10d/r11d) across calls that overwrite them
(ScreenBuffer_set_cell_pen uses r8-r10).  After the first row the thumb start collapsed to 0, so the thumb was
smeared from the top of the bar down to its end position instead of being a block of exactly `thumb_h` cells.

SB1 a long listing: the thumb is a single contiguous block of max(1, list_h^2 / count) cells at Home, PgDn and End
SB2 a moderately long listing (thumb taller than one cell) keeps its exact height and sits at the bottom at End
"""

import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.environ.get("DUOP", os.path.join(REPO_ROOT, "duop"))
COLS, ROWS = 80, 30
BAR_COL = COLS // 2 - 1                      # right border column of the left pane
KEY_HOME, KEY_END, KEY_PGDN = b"\x1b[H", b"\x1b[F", b"\x1b[6~"


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


def scrollbar(sess: PtySession) -> str:
    column = "".join(sess.vt.grid[y][BAR_COL] for y in range(sess.vt.rows))
    return "".join(ch for ch in column if ch in "░█")


def open_listing(tmp: str, files: int) -> PtySession:
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left)
    os.makedirs(right)
    for i in range(files):
        open(os.path.join(left, f"f{i:04d}.txt"), "w").close()
    sess = PtySession(BINARY, ["--lang", "en", left, right], cols=COLS, rows=ROWS, extra_env={"HOME": tmp})
    sess.drain(0.6)
    return sess


def check_shape(bar: str, count: int, where: str) -> int:
    list_h = len(bar)
    assert list_h >= 10, f"{where}: no scrollbar found (got {bar!r})"
    assert re.fullmatch(r"░*█+░*", bar), f"{where}: thumb is not one contiguous block: {bar}"
    want = max(1, list_h * list_h // count)
    assert bar.count("█") == want, f"{where}: thumb is {bar.count('█')} cells, expected {want}: {bar}"
    return want


def test_long_listing_thumb_is_one_cell() -> None:
    with tempfile.TemporaryDirectory(prefix="sb1_") as tmp:
        sess = open_listing(tmp, 300)
        try:
            count = 301                                          # files + ".."
            check_shape(scrollbar(sess), count, "Home")
            assert scrollbar(sess).startswith("█"), "thumb must start at the top for the first page"
            sess.send(KEY_PGDN * 4, wait=0.4)
            bar = scrollbar(sess)
            check_shape(bar, count, "PgDn x4")
            assert not bar.startswith("█") and not bar.endswith("█"), f"thumb must sit inside the bar: {bar}"
            sess.send(KEY_END, wait=0.4)
            bar = scrollbar(sess)
            check_shape(bar, count, "End")
            assert bar.endswith("█"), f"thumb must sit at the bottom at End: {bar}"
        finally:
            kill(sess)
    print("[PASS] SB1. 300-entry listing: thumb is one contiguous cell at Home, middle and End")


def test_taller_thumb_keeps_height_and_bottom_position() -> None:
    with tempfile.TemporaryDirectory(prefix="sb2_") as tmp:
        sess = open_listing(tmp, 40)
        try:
            count = 41
            height = check_shape(scrollbar(sess), count, "Home")
            assert height > 1, "this listing must produce a multi-cell thumb"
            sess.send(KEY_END, wait=0.4)
            bar = scrollbar(sess)
            assert check_shape(bar, count, "End") == height
            assert bar.endswith("█" * height), f"thumb must fill the bottom of the bar at End: {bar}"
            assert bar.startswith("░"), f"track must be visible above the thumb at End: {bar}"
        finally:
            kill(sess)
    print("[PASS] SB2. 40-entry listing: thumb keeps its height and sits at the bottom at End")


def main() -> None:
    test_long_listing_thumb_is_one_cell()
    test_taller_thumb_keeps_height_and_bottom_position()
    print("ALL PANE SCROLLBAR TESTS PASSED.")


if __name__ == "__main__":
    main()
