#!/usr/bin/env python3
"""End-to-end PTY tests for Duop 2.2: Terminal Image Preview (Kitty f=100 + Half-block fallback)."""
import os
import struct
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def make_png_4x4(path):
    w, h = 4, 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter None
        for x in range(w):
            # Red top half, Blue bottom half
            if y < 2:
                raw.extend((220, 40, 40, 255))
            else:
                raw.extend((40, 80, 220, 255))
    idat = zlib.compress(bytes(raw))

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def drain_raw(sess, wait=0.25):
    import select
    buf = bytearray()
    end = time.monotonic() + wait
    while True:
        rem = end - time.monotonic()
        if rem <= 0:
            break
        rlist, _, _ = select.select([sess.master], [], [], rem)
        if not rlist:
            break
        try:
            d = os.read(sess.master, 65536)
        except OSError:
            break
        if not d:
            break
        buf.extend(d)
        sess.vt.feed(d)
        end = time.monotonic() + 0.05
    return bytes(buf)


def test_kitty_and_cleanup():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_4x4(os.path.join(l, "a_pic.png"))
        with open(os.path.join(l, "b_note.txt"), "w") as f:
            f.write("just text\n")

        sess = PtySession(
            BINARY, ["--lang", "en", l, r], cols=120, rows=35,
            extra_env={"KITTY_WINDOW_ID": "1"},
        )
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[20~")  # F9 Preview
            drain_raw(sess, 0.15)
            os.write(sess.master, b"\x1b[B")    # Down to a_pic.png
            raw = drain_raw(sess, 0.45)
            assert b"\x1b_Ga=T,f=100" in raw, f"Missing Kitty f=100 sequence in raw output"
            # Switch to b_note.txt -> must emit Kitty delete sequence
            os.write(sess.master, b"\x1b[B")
            raw2 = drain_raw(sess, 0.4)
            assert b"\x1b_Ga=d" in raw2, "Missing Kitty cleanup (a=d) when leaving image"
            print("[PASS] IMG1. Kitty Graphics Protocol (f=100) & cleanup (a=d)")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_halfblock_fallback():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_4x4(os.path.join(l, "a_pic.png"))

        sess = PtySession(
            BINARY, ["--lang", "en", l, r], cols=120, rows=35,
            extra_env={"DUOP_IMG_MODE": "halfblock"},
        )
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[20~")  # F9 Preview
            drain_raw(sess, 0.15)
            os.write(sess.master, b"\x1b[B")    # Down to a_pic.png
            raw = drain_raw(sess, 0.45)
            screen = sess.vt.full_text()
            assert "▀" in screen, f"Half-block fallback character missing:\n{screen}"
            assert b"38;2;" in raw and b"48;2;" in raw, "TrueColor RGB sequences missing for half-block image"
            print("[PASS] IMG2. TrueColor half-block (▀) PNG fallback")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_kitty_and_cleanup()
    test_halfblock_fallback()
    print("ALL IMAGE PREVIEW TESTS PASSED.")
