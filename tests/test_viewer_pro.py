#!/usr/bin/env python3
"""TDD test for 2.7: Syntax highlighting, ELF64 inspector, and In-place Hex editor."""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def wait_for(sess, text, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def test_viewer_pro():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)

        py_file = os.path.join(l, "a_script.py")
        with open(py_file, "w") as f:
            f.write('def greet():\n    # comment\n    return "ok"\n')

        elf_copy = os.path.join(l, "b_duop_elf")
        shutil.copy2(BINARY, elf_copy)

        bin_file = os.path.join(l, "c_patch.bin")
        with open(bin_file, "wb") as f:
            f.write(b"HELLO_WORLD_1234")

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "a_script.py")
            # VP1: Preview + F3 syntax highlighting on .py
            sess.send(b"\x1b[B")  # a_script.py
            sess.send(b"\x1bOR")  # F3
            wait_for(sess, "def greet():")
            # Verify multiple distinct foreground colors were emitted for syntax tokens
            r_idx = next(i for i, ln in enumerate(sess.vt.full_text().splitlines()) if "def greet():" in ln)
            fgs = {sess.vt.fg[r_idx][c] for c, ch in enumerate(sess.vt.grid[r_idx]) if ch.strip() and 10 <= c < 30}
            assert len(fgs) >= 2, f"Expected syntax highlight colors on 'def greet():', got {fgs}"
            sess.send(b"\x1b", wait=0.1)
            print("[PASS] VP1. Syntax highlighting in ViewerDialog")

            # VP2: ELF64 inspector on b_duop_elf
            sess.send(b"\x1b[B")  # b_duop_elf
            sess.send(b"\x1b[20~", wait=0.15)  # F9 toggle Preview
            wait_for(sess, "ELF64")
            wait_for(sess, ".text")
            sess.send(b"\x1b[20~", wait=0.1)  # F9 off
            print("[PASS] VP2. ELF64 inspector in PreviewPane")

            # VP3: In-place Hex Editor + Ctrl+Z undo + Ctrl+S save
            sess.send(b"\x1b[B")  # c_patch.bin
            sess.send(b"\x1bOR")  # F3
            wait_for(sess, "HELLO_WORLD_1234")
            sess.send(b"h")       # Hex mode
            wait_for(sess, "48 45 4c 4c")
            sess.send(b"e")       # Enter Hex Edit mode
            sess.send(b"58")      # 'H' (48) -> 'X' (58)
            wait_for(sess, "XELLO_WORLD_1234")
            sess.send(b"\x1a")    # Ctrl+Z undo
            wait_for(sess, "HELLO_WORLD_1234")
            sess.send(b"5a")      # 'H' (48) -> 'Z' (5a)
            wait_for(sess, "ZELLO_WORLD_1234")
            sess.send(b"\x13", wait=0.15)  # Ctrl+S save
            sess.send(b"\x1b", wait=0.1)   # Close viewer
            with open(bin_file, "rb") as f:
                data = f.read()
            assert data == b"ZELLO_WORLD_1234", f"Expected patched bytes on disk, got {data!r}"
            print("[PASS] VP3. In-place Hex editor + Ctrl+Z undo + Ctrl+S save")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_viewer_pro()
    print("ALL VIEWER PRO TESTS PASSED.")
