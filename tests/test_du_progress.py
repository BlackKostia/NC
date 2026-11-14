#!/usr/bin/env python3
"""Disk Usage (Alt+D) progress: when the subtree walk takes long (DUOP_DU_PROGRESS_MS, default
300 ms) a progress window shows folders done / total and the running dirs / files / bytes, Esc
cancels the walk (panel returns to the normal listing, no partial sizes are cached), and short
walks never flash the window."""

import os
import select
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402
from du_util import du_text  # noqa: E402

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))
TOP, SUB, LEAF = 24, 12, 6                        # 24 * 12 * 6 = 1728 leaf dirs
FILE = 4096
TITLE_EN, TITLE_UA = "Scanning disk usage", "Аналіз розміру тек"


def make_tree(tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(right)
    for a in range(TOP):
        for b in range(SUB):
            for c in range(LEAF):
                d = os.path.join(left, f"top{a:02d}", f"s{b:02d}", f"x{c}")
                os.makedirs(d)
                with open(os.path.join(d, "f.bin"), "wb") as f:
                    f.write(b"x" * FILE)
    return left, right


def read_raw(s, wait):
    out = bytearray()
    end = time.monotonic() + wait
    while time.monotonic() < end:
        r, _, _ = select.select([s.master], [], [], 0.05)
        if r:
            try:
                d = os.read(s.master, 1 << 16)
            except OSError:
                break
            out += d
            s.vt.feed(d)
    return out.decode("utf-8", "replace")


def session(left, right, lang, env):
    s = PtySession(BINARY, ["--lang", lang, left, right], cols=120, rows=35,
                   extra_env=dict(env, HOME=os.path.dirname(left)))
    read_raw(s, 0.5)
    return s


def close(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def test_progress_window(left, right):
    for lang, title in (("en", TITLE_EN), ("ua", TITLE_UA)):
        s = session(left, right, lang, {"DUOP_DU_PROGRESS_MS": "0"})
        try:
            os.write(s.master, b"\x1bd")
            raw = read_raw(s, 2.5)
            assert title in raw, f"{lang}: no progress window in the output stream"
            assert f"/ {TOP}" in raw, f"{lang}: no 'done / {TOP}' folder counter"
            assert "Esc" in raw, f"{lang}: no Esc hint"
            txt = s.vt.full_text()
            assert title not in txt, f"{lang}: progress window left on screen:\n{txt}"
            top = du_text(os.path.join(left, "top00"))
            assert top in txt, f"{lang}: expected {top} per folder after the walk:\n{txt}"
        finally:
            close(s)
    print("[PASS] DP1. Long walk shows a progress window (EN/UA) and removes it when done")


def test_no_flash(left, right):
    s = session(left, right, "en", {})
    try:
        os.write(s.master, b"\x1bd")
        raw = read_raw(s, 1.5)
        assert TITLE_EN not in raw, "a short walk must not flash the progress window"
        assert "Disk Usage" in s.vt.full_text()
        print("[PASS] DP2. Walks shorter than DUOP_DU_PROGRESS_MS (300 ms) show no window")
    finally:
        close(s)


def test_cancel(left, right):
    s = session(left, right, "en", {"DUOP_DU_PROGRESS_MS": "0"})
    try:
        os.write(s.master, b"\x1bd\x1b")                 # Alt+D, then Esc while it walks
        read_raw(s, 1.5)
        txt = s.vt.full_text()
        assert "canceled" in txt, f"no cancel status:\n{txt}"
        assert TITLE_EN not in txt, txt
        assert "top00" in txt and "<DIR>" in txt, f"panel must return to the normal listing:\n{txt}"
        os.write(s.master, b"\x1bd")                      # full walk: cache holds no partial sizes
        read_raw(s, 2.5)
        txt = s.vt.full_text()
        top = du_text(os.path.join(left, "top00"))
        assert top in txt, f"after cancel a fresh walk must give exact sizes ({top}):\n{txt}"
        print("[PASS] DP3. Esc cancels the walk, restores the listing, and leaves no partial cache")
    finally:
        close(s)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        left, right = make_tree(tmp)
        for case in (test_progress_window, test_no_flash, test_cancel):
            case(left, right)
    print("ALL DISK USAGE PROGRESS TESTS PASSED.")


if __name__ == "__main__":
    main()
