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
            os.write(sess.master, b"\x1b[B")    # Down to a_pic.png (decoded by the async helper)
            raw = b""
            end = time.monotonic() + 3.0
            while b"\x1b_Ga=T,f=32" not in raw and time.monotonic() < end:
                raw += drain_raw(sess, 0.3)
            assert b"\x1b_Ga=T,f=32" in raw, f"Missing Kitty f=32 RGBA transmission in raw output"
            # Switch to b_note.txt -> must emit Kitty delete sequence
            os.write(sess.master, b"\x1b[B")
            raw2 = drain_raw(sess, 0.4)
            assert b"\x1b_Ga=d" in raw2, "Missing Kitty cleanup (a=d) when leaving image"
            print("[PASS] IMG1. Kitty Graphics Protocol (f=32) & cleanup (a=d)")
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


def make_png_grid(path, w=200, h=200):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            if y == h // 2:
                raw.extend((0, 0, 0, 255))
            elif y < h // 2 and x < w // 2:
                raw.extend((240, 20, 20, 255))
            elif y < h // 2:
                raw.extend((20, 240, 20, 255))
            elif x < w // 2:
                raw.extend((20, 20, 240, 255))
            else:
                raw.extend((240, 240, 20, 255))
    idat = zlib.compress(bytes(raw))

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def test_img_zoom_and_quality():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "grid.png"), 600, 600)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # select grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as dialog
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # i -> Image mode
            drain_raw(sess, 0.3)
            screen = sess.vt.full_text()
            assert "[Fit]" in screen, f"Expected [Fit] zoom indicator:\n{screen}"

            os.write(sess.master, b"1")         # 100% native 1:1
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[100%]" in screen, f"Expected [100%] after pressing '1':\n{screen}"

            os.write(sess.master, b"+")         # Zoom in
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[125%]" in screen or "[150%]" in screen or "[200%]" in screen, (
                f"Expected zoomed >100% after '+':\n{screen}"
            )

            os.write(sess.master, b"\x1b[C\x1b[B")  # Pan right + down
            drain_raw(sess, 0.2)
            os.write(sess.master, b"0")         # Reset to Fit
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[Fit]" in screen, f"Expected [Fit] after pressing '0':\n{screen}"
            print("[PASS] IMG3. Image viewer zoom (+/-, 1, 0) and pan")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_viewer_scrollbars():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "a_grid.png"), 200, 200)
        with open(os.path.join(l, "b_long.txt"), "w") as f:
            for i in range(120):
                f.write(f"line {i:03d}\n")

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # a_grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # Image mode (Fit)
            drain_raw(sess, 0.3)
            lines = sess.vt.full_text().splitlines()
            right_col = "".join(ln[-3] for ln in lines[2:27] if len(ln) >= 3)
            assert "█" not in right_col and "░" not in right_col, (
                f"Unexpected scrollbar in Fit mode:\n" + "\n".join(lines)
            )

            os.write(sess.master, b"1")         # 100% zoom -> needs scrollbars
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            right_col = "".join(ln[-3] for ln in lines[2:27] if len(ln) >= 3)
            bot_row = lines[-2] if len(lines) >= 2 else ""
            assert "█" in right_col and "░" in right_col, (
                f"Missing vertical scrollbar when zoomed:\n" + "\n".join(lines)
            )
            assert "█" in bot_row and "░" in bot_row, (
                f"Missing horizontal scrollbar when zoomed:\n" + "\n".join(lines)
            )

            os.write(sess.master, b"0")         # Fit again -> scrollbars hidden
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            right_col = "".join(ln[-3] for ln in lines[2:27] if len(ln) >= 3)
            assert "█" not in right_col, "Scrollbar remained after Fit"

            os.write(sess.master, b"\x1b")      # Close viewer
            drain_raw(sess, 0.15)
            os.write(sess.master, b"\x1b[B")    # b_long.txt
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 text viewer
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            right_col = "".join(ln[-3] for ln in lines[2:27] if len(ln) >= 3)
            assert "█" in right_col and "░" in right_col, (
                f"Missing vertical scrollbar in long text viewer:\n" + "\n".join(lines)
            )
            print("[PASS] IMG4. ViewerDialog scrollbars (image zoom H/V + text overflow)")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_braille_mode():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "grid.png"), 600, 600)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # Image mode
            drain_raw(sess, 0.3)

            os.write(sess.master, b"b")         # Toggle 2x4 Braille mode
            drain_raw(sess, 0.3)
            screen = sess.vt.full_text()
            assert "[Fit B]" in screen, f"Expected [Fit B] badge after 'b':\n{screen}"
            has_braille = any("\u2800" <= ch <= "\u28ff" for ch in screen)
            assert has_braille, f"Expected Unicode Braille characters in screen:\n{screen}"

            os.write(sess.master, b"o")         # External open (no-op without DISPLAY, must not crash)
            drain_raw(sess, 0.15)

            os.write(sess.master, b"b")         # Toggle back to quadrant
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[Fit]" in screen, f"Expected [Fit] after second 'b':\n{screen}"
            print("[PASS] IMG5. 2x4 Braille high-detail mode ('b') & external open ('o')")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_scrollbar_mouse():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "grid.png"), 600, 600)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # Image mode
            drain_raw(sess, 0.3)
            os.write(sess.master, b"1")         # 100% zoom -> scrollbars active
            drain_raw(sess, 0.25)

            # Click top of vertical scrollbar (1-based col=98, row=3)
            os.write(sess.master, b"\x1b[<0;98;3M\x1b[<0;98;3m")
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            assert lines[2][-3] == "█", f"Expected V-thumb at top after click:\n" + "\n".join(lines)

            # Click bottom of vertical scrollbar (1-based col=98, row=27)
            os.write(sess.master, b"\x1b[<0;98;27M\x1b[<0;98;27m")
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            assert lines[26][-3] == "█", f"Expected V-thumb at bottom after click:\n" + "\n".join(lines)

            # Click left of horizontal scrollbar (1-based col=4, row=29 -> y=28)
            os.write(sess.master, b"\x1b[<0;4;29M\x1b[<0;4;29m")
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            assert lines[28][3] == "█", f"Expected H-thumb at left after click:\n" + "\n".join(lines)

            # Click right of horizontal scrollbar (1-based col=97, row=29 -> y=28)
            os.write(sess.master, b"\x1b[<0;97;29M\x1b[<0;97;29m")
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            assert lines[28][96] == "█", f"Expected H-thumb at right after click:\n" + "\n".join(lines)
            print("[PASS] IMG6. Interactive mouse click/drag on ViewerDialog H/V scrollbars")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_wheel_scroll_and_drag():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "grid.png"), 600, 600)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # Image mode
            drain_raw(sess, 0.3)
            os.write(sess.master, b"1")         # 100% zoom -> scrollbars active
            drain_raw(sess, 0.25)

            # Plain wheel down must scroll vertically, NOT zoom out!
            os.write(sess.master, b"\x1b[<65;50;15M" * 4)
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[100%]" in screen, f"Wheel down zoomed instead of scrolling:\n{screen}"

            # Press on V-scrollbar top (col=98, row=3) then drag off-column (col=90, row=27)
            os.write(sess.master, b"\x1b[<0;98;3M\x1b[<32;90;27M\x1b[<0;90;27m")
            drain_raw(sess, 0.25)
            lines = sess.vt.full_text().splitlines()
            assert lines[26][-3] == "█", f"Off-column V-scrollbar drag failed:\n" + "\n".join(lines)

            # Ctrl+Wheel down (64 | 16 | 1 = 81) must zoom out
            os.write(sess.master, b"\x1b[<81;50;15M")
            drain_raw(sess, 0.25)
            screen = sess.vt.full_text()
            assert "[100%]" not in screen, f"Ctrl+Wheel down did not zoom out:\n{screen}"
            print("[PASS] IMG7. Mouse wheel scroll, off-column scrollbar drag & Ctrl+Wheel zoom")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_kitty_scroll_no_flicker():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        make_png_grid(os.path.join(l, "grid.png"), 600, 600)

        sess = PtySession(
            BINARY, ["--lang", "en", l, r], cols=100, rows=30,
            extra_env={"KITTY_WINDOW_ID": "1"},
        )
        try:
            drain_raw(sess, 0.25)
            os.write(sess.master, b"\x1b[B")    # grid.png
            drain_raw(sess, 0.1)
            os.write(sess.master, b"\x1bOR")    # F3 -> Open as
            drain_raw(sess, 0.15)
            os.write(sess.master, b"i")         # Image mode
            drain_raw(sess, 0.4)
            os.write(sess.master, b"1")         # 100% zoom
            drain_raw(sess, 0.4)

            # Burst of 4 wheel-down events in one write must coalesce (<= 2 Kitty redraws, no a=d)
            os.write(sess.master, b"\x1b[<65;50;15M" * 4)
            raw = drain_raw(sess, 0.4)
            emits = raw.count(b"\x1b_Ga=T,f=32")
            assert 1 <= emits <= 2, f"Expected coalesced Kitty redraws (1..2), got {emits}"
            assert b"\x1b_Ga=d" not in raw, "Unexpected a=d during Kitty same-rect scroll (causes flicker)"
            sync_on = raw.rfind(b"\x1b[?2026h")
            emit_pos = raw.find(b"\x1b_Ga=T,f=32", sync_on if sync_on != -1 else 0)
            sync_off = raw.find(b"\x1b[?2026l", emit_pos if emit_pos != -1 else 0)
            assert sync_on != -1 and sync_on < emit_pos < sync_off, (
                f"Kitty scroll emit not inside DEC 2026: sync_on={sync_on} emit={emit_pos} sync_off={sync_off}"
            )
            print("[PASS] IMG8. Kitty scroll coalesces bursts & replaces i=7 in-place without a=d")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_kitty_and_cleanup()
    test_halfblock_fallback()
    test_img_zoom_and_quality()
    test_viewer_scrollbars()
    test_braille_mode()
    test_scrollbar_mouse()
    test_wheel_scroll_and_drag()
    test_kitty_scroll_no_flicker()
    print("ALL IMAGE PREVIEW TESTS PASSED.")
