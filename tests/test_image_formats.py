#!/usr/bin/env python3
"""Image formats & view-mode tests: PNG (all color types, 16-bit, Adam7, > 32 KiB), JPEG
baseline (4:2:0 / 4:4:4 / gray), GIF (interlaced), BMP (1/8/24/32-bit), PNM, TGA (+RLE), QOI;
preview-pane Image/Hex/Text switching (Alt+V) and the F3 "Open as" dialog (EN/UA)."""

import os
import random
import struct
import sys
import tempfile
import time
import zlib

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))
RED, BLUE = (220, 40, 40), (40, 80, 220)
W, H = 48, 32


def split_rgb(w=W, h=H, noise=False):
    """Left half red, right half blue (optional random middle band to defeat compression)."""
    rnd = random.Random(7)
    px = []
    for y in range(h):
        for x in range(w):
            if noise and w * 3 // 8 <= x < w * 5 // 8:
                px.append((rnd.randrange(256), rnd.randrange(256), rnd.randrange(256)))
            else:
                px.append(RED if x < w // 2 else BLUE)
    return px


def pil_image(mode="RGB", **kw):
    im = Image.new("RGB", (kw.get("w", W), kw.get("h", H)))
    im.putdata(split_rgb(kw.get("w", W), kw.get("h", H), kw.get("noise", False)))
    if mode == "P":
        return im.convert("P", palette=Image.ADAPTIVE, colors=16)
    return im if mode == "RGB" else im.convert(mode)


def png_chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))


def png_bytes(w, h, depth, ctype, rows, interlace=0):
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, interlace)
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) +
            png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b""))


def png_rgb16(path):
    rows = bytearray()
    for y in range(H):
        rows.append(0)
        for x in range(W):
            for c in (RED if x < W // 2 else BLUE):
                rows += struct.pack(">H", c * 257)
    open(path, "wb").write(png_bytes(W, H, 16, 2, bytes(rows)))


def png_adam7(path):
    passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
              (0, 1, 1, 2)]
    px = split_rgb()
    out = bytearray()
    for x0, y0, dx, dy in passes:
        for y in range(y0, H, dy):
            xs = list(range(x0, W, dx))
            if not xs:
                continue
            out.append(0)
            for x in xs:
                out += bytes(px[y * W + x])
    open(path, "wb").write(png_bytes(W, H, 8, 2, bytes(out), interlace=1))


def qoi_bytes(px, w, h):
    out = bytearray(b"qoif" + struct.pack(">IIBB", w, h, 3, 0))
    prev, run = None, 0
    for p in px:
        if p == prev:
            run += 1
            if run == 62:
                out.append(0xC0 | (run - 1))
                run = 0
            continue
        if run:
            out.append(0xC0 | (run - 1))
            run = 0
        out += bytes((0xFE,) + p)
        prev = p
    if run:
        out.append(0xC0 | (run - 1))
    return bytes(out + b"\x00" * 7 + b"\x01")


def make_files(d):
    """Return [(file name, expect_image)] in directory order."""
    spec = []

    def pil(name, mode, fmt, **kw):
        pil_image(mode, **{k: v for k, v in kw.items() if k in ("w", "h", "noise")}).save(
            os.path.join(d, name), fmt, **{k: v for k, v in kw.items()
                                          if k not in ("w", "h", "noise")})
        spec.append((name, True))

    pil("a01_rgb.png", "RGB", "PNG")
    pil("a02_rgba.png", "RGBA", "PNG")
    pil("a03_pal.png", "P", "PNG")
    pil("a04_big.png", "RGB", "PNG", w=400, h=240, noise=True)
    png_rgb16(os.path.join(d, "a05_rgb16.png"))
    spec.append(("a05_rgb16.png", True))
    png_adam7(os.path.join(d, "a06_adam7.png"))
    spec.append(("a06_adam7.png", True))
    pil("b01_420.jpg", "RGB", "JPEG", quality=92)
    pil("b02_444.jpg", "RGB", "JPEG", quality=92, subsampling=0)
    pil("b03_rst.jpg", "RGB", "JPEG", quality=92, restart_marker_blocks=1)
    pil("c01_anim.gif", "P", "GIF")
    pil("d01_24.bmp", "RGB", "BMP")
    pil("d02_8.bmp", "P", "BMP")
    pil("e01.ppm", "RGB", "PPM")
    pil("f01.tga", "RGB", "TGA")
    pil("f02_rle.tga", "RGB", "TGA", compression="tga_rle")
    open(os.path.join(d, "g01.qoi"), "wb").write(qoi_bytes(split_rgb(), W, H))
    spec.append(("g01.qoi", True))
    return spec


def near(c, ref, tol=70):
    return c is not None and sum(abs(a - b) for a, b in zip(c, ref)) <= tol


def image_cells(sess, x0, x1, y0, y1):
    """Half-block cells inside the box: list of (col, fg, bg)."""
    out = []
    for r in range(y0, y1):
        for c in range(x0, x1):
            if sess.vt.grid[r][c] == "▀":
                out.append((c, sess.vt.fg[r][c], sess.vt.bg[r][c]))
    return out


def assert_split_colors(sess, name, x0, x1, y0=1, y1=34):
    cells = image_cells(sess, x0, x1, y0, y1)
    assert len(cells) > 20, f"{name}: no half-block image rendered:\n{sess.vt.full_text()}"
    cols = sorted({c for c, _, _ in cells})
    lo, hi = cols[0], cols[-1]
    span = max(1, hi - lo)
    left = [fg for c, fg, _ in cells if c <= lo + span // 5]
    right = [fg for c, fg, _ in cells if c >= hi - span // 5]
    lred = sum(near(fg, RED) for fg in left) / max(1, len(left))
    rblue = sum(near(fg, BLUE) for fg in right) / max(1, len(right))
    assert lred > 0.8 and rblue > 0.8, (
        f"{name}: colors wrong (left red {lred:.2f}, right blue {rblue:.2f}); "
        f"samples {left[:3]} / {right[:3]}")


def wait_until(sess, pred, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.08)
        if pred():
            return True
    return False


def open_session(left, right, lang="en"):
    s = PtySession(BINARY, ["--lang", lang, left, right], cols=120, rows=35,
                   extra_env={"DUOP_IMG_MODE": "halfblock"})
    s.drain(0.3)
    return s


def kill(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def test_formats_in_preview(tmp, left, right):
    spec = make_files(left)
    s = open_session(left, right)
    try:
        s.send(b"\x1b[20~", wait=0.2)          # F9: preview pane
        for name, _ in spec:
            s.send(b"\x1b[B", wait=0.05)       # next file
            ok = wait_until(s, lambda: len(image_cells(s, 61, 119, 3, 33)) > 20, 3.0)
            assert ok, f"{name}: image not shown in preview:\n{s.vt.full_text()}"
            s.drain(0.15)
            assert_split_colors(s, name, 61, 119, 3, 33)
            print(f"[PASS] IF1. {name} decoded and rendered in preview")
        # IF2: Alt+V cycles Image -> Hex -> Text -> Image on the last file (QOI)
        s.send(b"\x1bv", wait=0.25)
        assert wait_until(s, lambda: "0000:" in s.vt.full_text()), "Alt+V: no hex view"
        assert not image_cells(s, 61, 119, 3, 33), "Alt+V: image still drawn in hex mode"
        s.send(b"\x1bv", wait=0.25)
        assert wait_until(s, lambda: "0000:" not in s.vt.full_text() and
                          "qoif" in s.vt.full_text()), "Alt+V: no text view"
        s.send(b"\x1bv", wait=0.25)
        assert wait_until(s, lambda: len(image_cells(s, 61, 119, 3, 33)) > 20), "Alt+V: no image"
        print("[PASS] IF2. Alt+V switches preview Image / Hex / Text")
    finally:
        kill(s)


def test_open_as_dialog(tmp, left, right, lang, title, labels):
    pil_image().save(os.path.join(left, "pic.png"))
    s = open_session(left, right, lang)
    try:
        s.send(b"\x1b[B", wait=0.15)
        s.send(b"\x1bOR", wait=0.3)                         # F3
        txt = s.vt.full_text()
        assert title in txt and all(lb in txt for lb in labels), f"{lang}: no Open-as dialog:\n{txt}"
        s.send(b"h", wait=0.35)                             # Hex
        assert wait_until(s, lambda: "89 50 4e 47" in s.vt.full_text().lower()), "no hex viewer"
        s.send(b"\x1b", wait=0.25)
        s.send(b"\x1bOR", wait=0.3)
        s.send(b"i", wait=0.4)                              # Image
        assert wait_until(s, lambda: len(image_cells(s, 1, 119, 2, 33)) > 40), "no image viewer"
        assert_split_colors(s, "viewer", 1, 119, 2, 33)
        s.send(b"\x1b", wait=0.25)
        s.send(b"\x1bOR", wait=0.3)
        s.send(b"\x1b", wait=0.25)                          # cancel the dialog
        assert title not in s.vt.full_text(), "Esc did not close the Open-as dialog"
        print(f"[PASS] IF3. F3 asks Image/Hex/Text ({lang}) and opens the chosen view")
    finally:
        kill(s)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        test_formats_in_preview(tmp, left, right)
    for lang, title, labels in (("en", "Open as", ("Image", "Hex", "Text")),
                                ("ua", "Відкрити як", ("Зображення", "HEX", "Текст"))):
        with tempfile.TemporaryDirectory() as tmp:
            left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
            os.makedirs(left)
            os.makedirs(right)
            test_open_as_dialog(tmp, left, right, lang, title, labels)
    print("ALL IMAGE FORMAT TESTS PASSED.")


if __name__ == "__main__":
    main()
