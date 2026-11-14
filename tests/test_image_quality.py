#!/usr/bin/env python3
"""High-quality image output: quadrant blocks (2x2 per cell) by default, Sixel when the terminal
reports it (DA1 ;4) with the cell size from TIOCGWINSZ / CSI 16 t, Kitty f=32 RGBA in <= 4096-byte
chunks; terminal replies are consumed silently (never become key presses)."""

import fcntl
import os
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))
RED, BLUE = (220, 40, 40), (40, 80, 220)
QUAD = set("▘▝▀▖▌▞▛▗▚▐▜▄▙▟█")
COLS, ROWS, CW, CH = 120, 35, 9, 18


def near(c, ref, tol=60):
    return c is not None and sum(abs(a - b) for a, b in zip(c, ref)) <= tol


def make_dir(tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left)
    os.makedirs(right)
    im = Image.new("RGB", (5, 2))
    im.putdata([RED, RED, BLUE, BLUE, BLUE] * 2)  # boundary falls inside a cell
    im.save(os.path.join(left, "a_split.png"))
    big = Image.new("RGB", (1600, 1000), BLUE)        # downscaled to the preview pixels
    big.paste(RED, (0, 0, 800, 1000))
    big.save(os.path.join(left, "b_big.png"))
    open(os.path.join(left, "c_note.txt"), "w").write("text\n")
    return left, right


def read_raw(s, wait=0.6):
    out = bytearray()
    end = time.monotonic() + wait
    while time.monotonic() < end:
        r, _, _ = select.select([s.master], [], [], max(0, end - time.monotonic()))
        if not r:
            break
        try:
            d = os.read(s.master, 1 << 16)
        except OSError:
            break
        if not d:
            break
        out += d
        s.vt.feed(d)
        end = time.monotonic() + 0.15
    return bytes(out)


def set_pixels(s):
    fcntl.ioctl(s.master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, COLS * CW, ROWS * CH))
    os.kill(s.pid, signal.SIGWINCH)


def session(left, right, env):
    s = PtySession(BINARY, ["--lang", "en", left, right], cols=COLS, rows=ROWS, extra_env=env)
    read_raw(s, 0.4)
    return s


def kill(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def test_quadrants(left, right):
    s = session(left, right, {})
    try:
        s.send(b"\x1b[20~", wait=0.2)
        s.send(b"\x1b[B", wait=0.05)
        read_raw(s, 0.8)
        cells = [(r, c) for r in range(3, 33) for c in range(61, 119) if s.vt.grid[r][c] in QUAD]
        assert len(cells) > 40, f"no block image:\n{s.vt.full_text()}"
        half = [(r, c) for r, c in cells if s.vt.grid[r][c] in "▌▐"]
        assert half, f"no 2x2 sub-cell detail (expected a ▌/▐ boundary cell):\n{s.vt.full_text()}"
        r, c = half[0]
        pair = {s.vt.fg[r][c], s.vt.bg[r][c]}
        assert any(near(x, RED) for x in pair) and any(near(x, BLUE) for x in pair), pair
        print("[PASS] IQ1. Default output uses 2x2 quadrant blocks with two colors per cell")
    finally:
        kill(s)


def test_sixel(left, right):
    s = session(left, right, {"DUOP_IMG_MODE": "sixel"})
    try:
        set_pixels(s)
        read_raw(s, 0.3)
        s.send(b"\x1b[20~", wait=0.2)
        os.write(s.master, b"\x1b[B\x1b[B")          # payload is captured in raw output
        raw = read_raw(s, 1.0)
        m = re.search(rb'\x1bP[0-9;]*q"1;1;(\d+);(\d+)', raw)
        assert m, f"no Sixel image in output ({len(raw)} bytes)"
        w, h = int(m.group(1)), int(m.group(2))
        assert 300 <= w <= 58 * CW and h <= 30 * CH, f"sixel {w}x{h} does not fit the box"
        assert re.search(rb"#\d+;2;\d+;\d+;\d+", raw) and raw.rfind(b"\x1b\\") > m.start()
        print(f"[PASS] IQ2. Sixel image sized to the preview pixels ({w}x{h})")
    finally:
        kill(s)


def test_sixel_detect(left, right):
    s = session(left, right, {})
    try:
        os.write(s.master, b"\x1b[?62;4;22c\x1b[6;18;9t")   # terminal: VT220 + sixel, 9x18 cells
        read_raw(s, 0.3)
        s.send(b"\x1b[20~", wait=0.2)
        os.write(s.master, b"\x1b[B\x1b[B")          # payload is captured in raw output
        raw = read_raw(s, 1.0)
        assert re.search(rb'\x1bP[0-9;]*q"1;1;\d+;\d+', raw), "DA1 ;4 reply did not enable Sixel"
        assert "b_big.png" in s.vt.row_text(ROWS - 2), "terminal reply leaked into key input"
        print("[PASS] IQ3. DA1 / CSI 16 t replies enable Sixel and never reach key input")
    finally:
        kill(s)


def test_kitty(left, right):
    s = session(left, right, {"KITTY_WINDOW_ID": "1"})
    try:
        set_pixels(s)
        read_raw(s, 0.3)
        s.send(b"\x1b[20~", wait=0.2)
        os.write(s.master, b"\x1b[B\x1b[B")          # payload is captured in raw output
        raw = read_raw(s, 1.0)
        assert b"\x1b_Ga=T,f=32," in raw, "no Kitty RGBA transmission"
        chunks = re.findall(rb"\x1b_G([^;]*);([A-Za-z0-9+/=]*)\x1b\\", raw)
        assert len(chunks) >= 2 and all(len(p) <= 4096 for _, p in chunks), "Kitty payload not chunked"
        assert b"m=1" in chunks[0][0] and b"m=0" in chunks[-1][0], [c[0] for c in chunks]
        os.write(s.master, b"\x1b[B")
        raw2 = read_raw(s, 0.6)
        assert b"\x1b_Ga=d" in raw2, "Kitty image not deleted when leaving it"
        print(f"[PASS] IQ4. Kitty f=32 RGBA in {len(chunks)} chunks, deleted on leave")
    finally:
        kill(s)


def test_viewer_pixels(left, right):
    s = session(left, right, {"KITTY_WINDOW_ID": "1"})
    try:
        set_pixels(s)
        read_raw(s, 0.3)
        os.write(s.master, b"\x1b[B\x1b[B")
        read_raw(s, 0.3)
        os.write(s.master, b"\x1bOR")                     # F3 -> Open as
        read_raw(s, 0.4)
        os.write(s.master, b"i")                           # Image
        raw = read_raw(s, 1.5)
        m = re.search(rb"\x1b_Ga=T,f=32,i=7,q=2,C=1,s=(\d+),v=(\d+)", raw)
        assert m, "viewer did not send a Kitty image"
        w, h = int(m.group(1)), int(m.group(2))
        assert w > 58 * CW, f"viewer image {w}x{h} not sized to the window"
        os.write(s.master, b"\x1b")
        assert b"\x1b_Ga=d" in read_raw(s, 0.6), "viewer image not deleted on close"
        print(f"[PASS] IQ5. F3 viewer sends a window-sized Kitty image ({w}x{h}) and removes it")
    finally:
        kill(s)


def main():
    for case in (test_quadrants, test_sixel, test_sixel_detect, test_kitty, test_viewer_pixels):
        with tempfile.TemporaryDirectory() as tmp:
            case(*make_dir(tmp))
    print("ALL IMAGE QUALITY TESTS PASSED.")


if __name__ == "__main__":
    main()
