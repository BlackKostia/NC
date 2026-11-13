#!/usr/bin/env python3
"""
End-to-end PTY test suite for NeoCommander (pure x86-64 assembly).
Simulates a real 120x35 (and resized 100x28) terminal with SGR 1006 mouse events,
keyboard sequences, ANSI TrueColor framebuffer parsing, and real filesystem ops.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


class VirtualTerminal:
    """Minimal ANSI/UTF-8 virtual terminal screen buffer for verifying TUI rendering."""

    def __init__(self, cols=120, rows=35):
        self.cols = cols
        self.rows = rows
        self.reset_grid()
        self.raw_stream = ""
        self._buf = b""
        self.saw_alt_enter = False
        self.saw_alt_exit = False
        self.saw_mouse_enable = False
        self.saw_mouse_disable = False

    def reset_grid(self):
        self.grid = [[" " for _ in range(self.cols)] for _ in range(self.rows)]
        self.fg = [[None for _ in range(self.cols)] for _ in range(self.rows)]
        self.bg = [[None for _ in range(self.cols)] for _ in range(self.rows)]
        self.cx = 0
        self.cy = 0
        self.cur_fg = None
        self.cur_bg = None

    def resize(self, cols, rows):
        self.cols = cols
        self.rows = rows
        self.reset_grid()

    def feed(self, data: bytes):
        self._buf += data
        # Decode valid complete UTF-8 prefix, keep trailing incomplete UTF-8 bytes
        valid_end = len(self._buf)
        for back in range(1, min(4, len(self._buf)) + 1):
            b = self._buf[-back]
            if b >= 0xC0:
                need = 2 if b < 0xE0 else (3 if b < 0xF0 else 4)
                if back < need:
                    valid_end = len(self._buf) - back
                break
            elif b < 0x80:
                break
        chunk = self._buf[:valid_end]
        self._buf = self._buf[valid_end:]

        text = chunk.decode("utf-8", errors="replace")
        self.raw_stream += text
        if "\x1b[?1049h" in self.raw_stream:
            self.saw_alt_enter = True
        if "\x1b[?1049l" in self.raw_stream:
            self.saw_alt_exit = True
        if "\x1b[?1006h" in self.raw_stream:
            self.saw_mouse_enable = True
        if "\x1b[?1006l" in self.raw_stream:
            self.saw_mouse_disable = True

        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self._buf = text[i:].encode("utf-8") + self._buf
                    break
                if text[i + 1] == "[":
                    j = i + 2
                    while j < n and not (0x40 <= ord(text[j]) <= 0x7E):
                        j += 1
                    if j >= n:
                        self._buf = text[i:].encode("utf-8") + self._buf
                        break
                    params = text[i + 2 : j]
                    fin = text[j]
                    if fin == "H":
                        parts = params.split(";") if params else ["1", "1"]
                        r = int(parts[0]) - 1 if len(parts) >= 1 and parts[0] else 0
                        c = int(parts[1]) - 1 if len(parts) >= 2 and parts[1] else 0
                        self.cy = max(0, min(self.rows - 1, r))
                        self.cx = max(0, min(self.cols - 1, c))
                    elif fin == "m":
                        if not params or params == "0":
                            self.cur_fg = None
                            self.cur_bg = None
                        else:
                            toks = params.split(";")
                            k = 0
                            while k < len(toks):
                                t = toks[k]
                                if t == "0":
                                    self.cur_fg = None
                                    self.cur_bg = None
                                elif t == "38" and k + 4 < len(toks) and toks[k + 1] == "2":
                                    self.cur_fg = (int(toks[k + 2]), int(toks[k + 3]), int(toks[k + 4]))
                                    k += 4
                                elif t == "48" and k + 4 < len(toks) and toks[k + 1] == "2":
                                    self.cur_bg = (int(toks[k + 2]), int(toks[k + 3]), int(toks[k + 4]))
                                    k += 4
                                k += 1
                    i = j + 1
                    continue
            elif ch >= " ":
                if 0 <= self.cy < self.rows and 0 <= self.cx < self.cols:
                    self.grid[self.cy][self.cx] = ch
                    self.fg[self.cy][self.cx] = self.cur_fg
                    self.bg[self.cy][self.cx] = self.cur_bg
                self.cx += 1
            i += 1

    def row_text(self, r: int) -> str:
        return "".join(self.grid[r])

    def full_text(self) -> str:
        return "\n".join(self.row_text(r) for r in range(self.rows))

    def find_text(self, needle: str, rightmost=False):
        for r in range(self.rows):
            line = self.row_text(r)
            idx = line.rfind(needle) if rightmost else line.find(needle)
            if idx != -1:
                return (idx, r)
        return None


class PtySession:
    def __init__(self, binary, args, cols=120, rows=35, extra_env=None):
        self.cols = cols
        self.rows = rows
        self.vt = VirtualTerminal(cols, rows)
        self.master, slave = pty.openpty()
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)

        self.pid = os.fork()
        if self.pid == 0:
            os.close(self.master)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0)
            os.dup2(slave, 1)
            os.dup2(slave, 2)
            if slave > 2:
                os.close(slave)
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            env.pop("LC_ALL", None)
            env.pop("LC_MESSAGES", None)
            env["LANG"] = "C.UTF-8"
            if extra_env:
                env.update(extra_env)
            os.execve(binary, [binary] + args, env)
            os._exit(127)
        os.close(slave)

    def drain(self, wait=0.15):
        deadline = time.monotonic() + wait
        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                break
            r, _, _ = select.select([self.master], [], [], min(rem, 0.05))
            if not r:
                continue
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    break
                self.vt.feed(chunk)
                # Keep draining immediately available bursts
                deadline = max(deadline, time.monotonic() + 0.05)
            except OSError:
                break

    def send(self, seq: bytes, wait=0.12):
        os.write(self.master, seq)
        self.drain(wait)

    def send_mouse(self, btn: int, x0: int, y0: int, kind="M", wait=0.12):
        seq = f"\x1b[<{btn};{x0 + 1};{y0 + 1}{kind}".encode("ascii")
        self.send(seq, wait)

    def resize(self, cols: int, rows: int):
        self.cols = cols
        self.rows = rows
        self.vt.resize(cols, rows)
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)
        os.kill(self.pid, signal.SIGWINCH)
        self.drain(0.20)

    def wait_exit(self, timeout=2.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid != 0:
                self.drain(0.05)
                os.close(self.master)
                return os.waitstatus_to_exitcode(status)
            self.drain(0.05)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        os.close(self.master)
        raise AssertionError("Process did not exit within timeout")


def run_tests():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    binary = os.path.join(repo_root, "nc")
    assert os.path.exists(binary), f"Binary not found: {binary}"

    with tempfile.TemporaryDirectory() as tmp:
        left_dir = os.path.join(tmp, "left")
        right_dir = os.path.join(tmp, "right")
        os.makedirs(left_dir)
        os.makedirs(right_dir)
        os.makedirs(os.path.join(left_dir, "alpha_dir"))
        os.makedirs(os.path.join(left_dir, "nested", "sub"))
        with open(os.path.join(left_dir, "nested", "sub", "deep.txt"), "w") as f:
            f.write("deep content\n")
        with open(os.path.join(left_dir, ".hidden_file"), "w") as f:
            f.write("secret\n")
        with open(os.path.join(left_dir, "hello.txt"), "w") as f:
            f.write("Hello NeoCommander\nLine two in assembly!\n")
        os.symlink("hello.txt", os.path.join(left_dir, "ln_hello"))
        with open(os.path.join(left_dir, "notes_cyr.txt"), "w") as f:
            f.write("Привіт світ!\n")
        with open(os.path.join(left_dir, "script.sh"), "w") as f:
            f.write("#!/bin/sh\necho ok\n")
        os.chmod(os.path.join(left_dir, "script.sh"), 0o755)
        for i in range(40):
            with open(os.path.join(left_dir, f"item_{i:02d}.dat"), "w") as f:
                f.write("x" * (i + 1))
        with open(os.path.join(right_dir, "dest_existing.txt"), "w") as f:
            f.write("right pane file\n")

        sess = PtySession(binary, [left_dir, right_dir], cols=120, rows=35)
        try:
            sess.drain(0.25)

            # 1. Verify initial render & ANSI terminal setup
            assert sess.vt.saw_alt_enter, "Missing alternate screen entry"
            assert sess.vt.saw_mouse_enable, "Missing SGR 1006 mouse activation"
            screen = sess.vt.full_text()
            assert "NeoCommander" in sess.vt.row_text(0), f"Header missing: {sess.vt.row_text(0)!r}"
            assert "alpha_dir" in screen, "Directory entry alpha_dir missing"
            assert "hello.txt" in screen, "File entry hello.txt missing"
            assert "dest_existing.txt" in screen, "Right pane file missing"
            assert "Help" in sess.vt.row_text(34), f"FunctionBar missing: {sess.vt.row_text(34)!r}"
            print("[PASS] 1. Initial dual-pane TrueColor render & layout")

            # 2. Test Live Preview toggle via HeaderBar mouse click on " Preview "
            pos = sess.vt.find_text(" Preview ")
            assert pos is not None, "Preview button not found in HeaderBar"
            # Note: mode pill is around x=17, action button is on the right! Find rightmost " Preview "
            hdr = sess.vt.row_text(0)
            px = hdr.rfind(" Preview ")
            assert px > 50, f"Expected right-aligned Preview pill, got row0={hdr!r}"
            # Move cursor onto hello.txt first via keyboard/mouse, or check preview after toggling
            sess.send_mouse(0, px + 2, 0, "M")  # press
            sess.send_mouse(0, px + 2, 0, "m")  # release
            assert "Live Preview" in sess.vt.full_text(), "Live Preview pane did not open on click"

            # Click on hello.txt row in left pane to select it and verify live preview content!
            hx, hy = sess.vt.find_text("hello.txt")
            sess.send_mouse(0, hx, hy, "M")
            sess.send_mouse(0, hx, hy, "m")
            assert "Hello NeoCommander" in sess.vt.full_text(), "Live preview did not load hello.txt"
            print("[PASS] 2. Mouse click HeaderBar Preview pill + row selection + Live Preview")

            # 3. Double-click hello.txt -> opens built-in ViewerDialog, test Hex toggle & Close click
            sess.send_mouse(0, hx, hy, "M")
            sess.send_mouse(0, hx, hy, "m")
            assert "File Viewer" in sess.vt.full_text(), "Double-click did not open File Viewer"
            assert "Line two in assembly!" in sess.vt.full_text(), "Viewer text content missing"
            # Toggle Hex mode with 'h'
            sess.send(b"h")
            assert "48 65 6c 6c 6f" in sess.vt.full_text(), "Viewer Hex mode missing 'Hello' hex bytes"
            # Close viewer via mouse click on rightmost " Close " button
            cy = 32
            cx = sess.vt.row_text(cy).rfind(" Close ")
            assert cx > 80, f"Close button missing on row 32: {sess.vt.row_text(cy)!r}"
            sess.send_mouse(0, cx + 2, cy, "M")
            sess.send_mouse(0, cx + 2, cy, "m")
            assert "File Viewer" not in sess.vt.full_text(), "Viewer did not close on button click"
            print("[PASS] 3. Double-click File Viewer (Text + Hex mode) & Close click")

            # Toggle back to Dual-pane mode via Ctrl+P
            sess.send(b"\x10")
            assert "dest_existing.txt" in sess.vt.full_text(), "Did not switch back to Dual pane"

            # 4. Right-click mark file + Mouse wheel scroll + Scrollbar verification
            hx, hy = sess.vt.find_text("hello.txt")
            sess.send_mouse(2, hx, hy, "M")  # right-click press
            sess.send_mouse(2, hx, hy, "m")
            assert "1 selected" in sess.vt.full_text(), "Right-click did not mark file"
            # Wheel down 3 times on left pane
            for _ in range(4):
                sess.send_mouse(65, 10, 10, "M", wait=0.05)
            assert "item_2" in sess.vt.full_text() or "item_3" in sess.vt.full_text(), "Mouse wheel did not scroll left pane"
            # Wheel back up
            for _ in range(5):
                sess.send_mouse(64, 10, 10, "M", wait=0.05)
            print("[PASS] 4. Right-click selection + Mouse wheel scrolling")

            # 5. Click column header "Size" to sort by size, then verify Theme switch
            sx, sy = sess.vt.find_text("Size")
            old_bg = sess.vt.bg[1][1]
            sess.send_mouse(0, sx + 1, sy, "M")
            sess.send_mouse(0, sx + 1, sy, "m")
            assert "Size ▲" in sess.vt.row_text(sy), f"Sort indicator missing: {sess.vt.row_text(sy)!r}"

            # Theme switch via Alt+T
            sess.send(b"\x1bt")
            assert "Catppuccin" in sess.vt.row_text(0), f"Theme did not switch: {sess.vt.row_text(0)!r}"
            assert sess.vt.bg[1][1] != old_bg, "TrueColor theme palette did not update"
            print("[PASS] 5. Clickable column sorting & TrueColor theme switching")

            # 6. Click FunctionBar [7 Mkdir] -> InputDialog -> create directory
            mx, my = sess.vt.find_text("Mkdir")
            sess.send_mouse(0, mx, my, "M")
            sess.send_mouse(0, mx, my, "m")
            assert "Create Directory" in sess.vt.full_text(), "Mkdir dialog did not open"
            sess.send(b"new_folder\r", wait=0.2)
            assert os.path.isdir(os.path.join(left_dir, "new_folder")), "Mkdir did not create directory on disk"
            print("[PASS] 6. FunctionBar click Mkdir -> InputDialog -> real mkdir")

            # 7. Filter for hello.txt, mark it with Space, Copy to right_dir via F5, then clear filter
            sess.send(b"/")
            sess.send(b"hello.txt\r")
            sess.send(b"\x1b[B")  # Down from ".." to hello.txt
            sess.send(b" ")       # Mark with Space
            assert "1 selected" in sess.vt.full_text(), "Space did not mark hello.txt"
            sess.send(b"\x1b[15~")  # F5
            assert "Copy destination path:" in sess.vt.full_text(), "Copy dialog did not open"
            sess.send(b"\r", wait=0.2)
            assert os.path.isfile(os.path.join(right_dir, "hello.txt")), "F5 Copy did not copy hello.txt to right_dir"
            sess.send(b"\x1b")    # Clear filter
            print("[PASS] 7. Space mark + F5 Copy file to opposite panel")

            # 7b. Create new file via Ctrl+N and Move it via F6 to right_dir
            sess.send(b"\x0e")    # Ctrl+N
            assert "Create New File" in sess.vt.full_text(), "New file dialog did not open"
            sess.send(b"moved_file.txt\r", wait=0.2)
            assert os.path.isfile(os.path.join(left_dir, "moved_file.txt")), "Ctrl+N NewFile failed"
            sess.send(b"\x1b[17~")  # F6 Move
            assert "Move destination path:" in sess.vt.full_text(), "Move dialog did not open"
            sess.send(b"\r", wait=0.2)
            assert not os.path.exists(os.path.join(left_dir, "moved_file.txt")), "F6 Move left source behind"
            assert os.path.isfile(os.path.join(right_dir, "moved_file.txt")), "F6 Move did not arrive in right_dir"
            print("[PASS] 7b. Ctrl+N New File + F6 Move to opposite panel")

            # 8. Rename via F2 -> select notes_cyr.txt with filter '/', rename it
            sess.send(b"/")
            assert "Live Filter" in sess.vt.full_text(), "Filter dialog did not open"
            sess.send(b"notes_cyr\r")
            assert "filter:notes_cyr" in sess.vt.full_text(), "Filter badge missing"
            # Move cursor down from ".." to notes_cyr.txt
            sess.send(b"\x1b[B")  # Down arrow
            sess.send(b"\x1bOQ")  # F2
            assert "Rename" in sess.vt.full_text(), "Rename dialog did not open"
            sess.send(b"\x15renamed_ua.txt\r", wait=0.2)  # Ctrl+U + new name + Enter
            assert os.path.isfile(os.path.join(left_dir, "renamed_ua.txt")), "Rename failed"
            # Clear filter with Esc
            sess.send(b"\x1b")
            print("[PASS] 8. Live Filter (/) + F2 Rename + Esc clear")

            # 9. Delete renamed_ua.txt via F8 -> ConfirmDialog -> Yes
            sess.send(b"/")
            sess.send(b"renamed_ua\r")
            sess.send(b"\x1b[B")  # Down to renamed_ua.txt
            sess.send(b"\x1b[19~")  # F8
            assert "Confirm Delete" in sess.vt.full_text(), "Confirm Delete dialog did not open"
            sess.send(b"\r", wait=0.2)
            assert not os.path.exists(os.path.join(left_dir, "renamed_ua.txt")), "F8 Delete did not remove file"
            sess.send(b"\x1b")
            print("[PASS] 9. F8 Delete via ConfirmDialog")

            # 9b. Recursive Copy + Recursive Delete on nested/
            sess.send(b"/")
            sess.send(b"nested\r")
            sess.send(b"\x1b[B")  # nested
            sess.send(b"\x1b[15~")  # F5 Copy
            sess.send(b"\r", wait=0.25)
            assert os.path.isfile(os.path.join(right_dir, "nested", "sub", "deep.txt")), "Recursive F5 Copy failed"
            sess.send(b"\x1b[19~")  # F8 Delete nested in left_dir
            assert "Confirm Delete" in sess.vt.full_text()
            sess.send(b"\r", wait=0.25)
            assert not os.path.exists(os.path.join(left_dir, "nested")), "Recursive F8 Delete failed"
            sess.send(b"\x1b")
            print("[PASS] 9b. Recursive Directory Copy (F5) & Recursive Delete (F8)")

            # 9c. Symlink StatusBar target + Dot:ON -> Dot:OFF mouse toggle + UTF-8 Ukrainian Mkdir
            sess.send(b"/")
            sess.send(b"ln_hello\r")
            sess.send(b"\x1b[B")
            assert "→ hello.txt" in sess.vt.row_text(33), f"Symlink target missing in StatusBar: {sess.vt.row_text(33)!r}"
            sess.send(b"\x1b")

            # Click Dot:ON -> Dot:OFF in HeaderBar
            dx, dy = sess.vt.find_text(" Dot:ON ")
            assert ".hidden_file" in sess.vt.full_text(), "Dotfile should be visible initially"
            sess.send_mouse(0, dx + 2, dy, "M")
            sess.send_mouse(0, dx + 2, dy, "m")
            assert "Dot:OFF" in sess.vt.row_text(0), "Dot:OFF toggle failed"
            assert ".hidden_file" not in sess.vt.full_text(), "Dotfile still visible when Dot:OFF"

            # UTF-8 Ukrainian directory creation
            sess.send(b"\x1b[18~")  # F7 Mkdir
            sess.send("тест_укр\r".encode("utf-8"), wait=0.2)
            assert os.path.isdir(os.path.join(left_dir, "тест_укр")), "UTF-8 Cyrillic mkdir failed"
            print("[PASS] 9c. Symlink StatusBar target, Dotfiles mouse toggle & UTF-8 Cyrillic mkdir")

            # 9d. Double-click alpha_dir -> enter, Backspace -> back, Hover highlight & Scrollbar drag
            ax, ay = sess.vt.find_text("alpha_dir")
            sess.send_mouse(0, ax, ay, "M")
            sess.send_mouse(0, ax, ay, "m")
            sess.send_mouse(0, ax, ay, "M")
            sess.send_mouse(0, ax, ay, "m")
            assert "alpha_dir" in sess.vt.row_text(1), f"Double-click did not enter alpha_dir: {sess.vt.row_text(1)!r}"
            sess.send(b"\x7f")  # Backspace
            assert "alpha_dir" not in sess.vt.row_text(1), "Backspace did not return to parent"

            # Hover over Help button in HeaderBar and check background color change
            hx2, hy2 = sess.vt.find_text(" Help ")
            bg_before = sess.vt.bg[hy2][hx2 + 2]
            sess.send_mouse(35, hx2 + 2, hy2, "M")  # SGR motion (btn 35 = 32 + 3)
            bg_after = sess.vt.bg[hy2][hx2 + 2]
            assert bg_after != bg_before, f"Hover did not highlight HeaderBar button ({bg_before} vs {bg_after})"

            # Scrollbar drag on left pane col 59
            sess.send_mouse(0, 59, 4, "M", wait=0.05)
            sess.send_mouse(32, 59, 28, "M", wait=0.1)
            sess.send_mouse(0, 59, 28, "m", wait=0.1)
            assert "item_3" in sess.vt.full_text(), "Scrollbar drag did not scroll to bottom items"
            print("[PASS] 9d. Double-click enter dir + Backspace + Mouse Hover + Scrollbar Drag")

            # 10. Help Dialog (F1) + Developer/License Metadata + Terminal Resize (SIGWINCH)
            sess.send(b"\x1bOP")  # F1
            assert "NeoCommander Help" in sess.vt.full_text(), "Help dialog did not open"
            for token in (
                "◆ AUTHOR & OPEN-SOURCE LICENSE",
                "Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович)",
                "ChessPlayerSedoy@gmail.com",
                "MIT License",
            ):
                assert token in sess.vt.full_text(), f"Missing metadata in HelpDialog: {token!r}"
            sess.resize(80, 22)
            sess.send(b"\x1b[B\x1b[B\x1b[B\x1b[B")
            assert "MIT License" in sess.vt.full_text(), "Scrolled HelpDialog missing license line"
            sess.send(b"\x1b")
            sess.resize(100, 26)
            assert "NeoCommander" in sess.vt.row_text(0), "Header missing after SIGWINCH resize"
            assert "Quit" in sess.vt.row_text(25), f"FunctionBar missing at row 25 after resize: {sess.vt.row_text(25)!r}"
            print("[PASS] 10. Help Dialog (F1 + Author/License) & SIGWINCH responsive resize (120x35 -> 80x22 -> 100x26)")

            # 11. Click Quit button in HeaderBar -> clean exit & terminal restoration
            qx, qy = sess.vt.find_text(" Quit ")
            sess.send_mouse(0, qx + 1, qy, "M", wait=0.1)
            code = sess.wait_exit(timeout=2.0)
            assert code == 0, f"Expected exit code 0, got {code}"
            assert sess.vt.saw_alt_exit, "Missing alternate screen exit restore sequence"
            assert sess.vt.saw_mouse_disable, "Missing SGR mouse disable restore sequence"
            print("[PASS] 11. Mouse click Quit -> clean exit (code 0) & terminal restoration")
        except Exception:
            print("\n--- LAST VIRTUAL TERMINAL SCREEN ---")
            print(sess.vt.full_text())
            print("------------------------------------")
            raise

        # 12 & 13. Ukrainian localization runtime toggle (HeaderBar click + Alt+L + Alt+Cyrillic) & Ukrainian Dialog HitZones
        sess_ua = PtySession(binary, [left_dir, right_dir], cols=120, rows=35)
        try:
            sess_ua.drain(0.35)
            lx, ly = sess_ua.vt.find_text(" Lang:EN ")
            assert lx is not None, "Lang:EN pill missing in HeaderBar"
            sess_ua.send_mouse(0, lx + 2, ly, "M")
            sess_ua.send_mouse(0, lx + 2, ly, "m")

            hdr = sess_ua.vt.row_text(0)
            for token in (" 2 панелі ", " Прев'ю ", " Прих:", " Мова:UA ", " Довідка ", " Вихід ", " Тема:"):
                assert token in hdr, f"Ukrainian HeaderBar token {token!r} missing: {hdr!r}"
            assert "Ім'я" in sess_ua.vt.row_text(2) and "Розмір" in sess_ua.vt.row_text(2)
            assert "<ТЕКА>" in sess_ua.vt.full_text()
            assert "Мова інтерфейсу: Українська" in sess_ua.vt.row_text(33)
            fbar = sess_ua.vt.row_text(34)
            for flbl in ("1Довід", "2Перейм", "3Перегл", "5Копія", "7Тека", "8Видал", "9Прев'ю", "0Вихід"):
                assert flbl in fbar, f"Ukrainian FunctionBar label {flbl!r} missing: {fbar!r}"

            # Verify dynamic UTF-8 HeaderBar HitZone for Preview pill
            px, py = sess_ua.vt.find_text(" Прев'ю ")
            sess_ua.send_mouse(0, px + 2, py, "M")
            sess_ua.send_mouse(0, px + 2, py, "m")
            assert " Перегляд " in sess_ua.vt.row_text(0)
            assert "◈ Швидкий перегляд" in sess_ua.vt.full_text()
            assert "Розмір:" in sess_ua.vt.full_text()
            sess_ua.send_mouse(0, px + 2, py, "M")
            sess_ua.send_mouse(0, px + 2, py, "m")

            # Verify Alt+д (Cyrillic layout Alt+L) -> EN, then Alt+L -> UA
            sess_ua.send(b"\x1b" + "д".encode("utf-8"))
            assert " Lang:EN " in sess_ua.vt.row_text(0), "Alt+Cyrillic д did not toggle back to EN"
            sess_ua.send(b"\x1bl")
            assert " Мова:UA " in sess_ua.vt.row_text(0), "Alt+L did not toggle to UA"
            print("[PASS] 12. Ukrainian runtime switch (HeaderBar pill, Alt+L & Alt+д) + UA Preview")

            # Test 13: Ukrainian Dialogs + UTF-8 button HitZones + F8 Confirm + SIGWINCH
            sess_ua.send(b"\x1b[18~")  # F7 Mkdir
            assert "Створити теку" in sess_ua.vt.full_text()
            assert "Назва теки:" in sess_ua.vt.full_text()
            cx, cy = sess_ua.vt.find_text(" Скасувати ")
            assert cx is not None, "Ukrainian Cancel button missing"
            sess_ua.send_mouse(0, cx + 2, cy, "M")
            sess_ua.send_mouse(0, cx + 2, cy, "m")
            assert "Створити теку" not in sess_ua.vt.full_text(), "Click on Скасувати did not cancel dialog"

            sess_ua.send(b"\x1bOP")  # F1 Help
            assert "Довідка та архітектура NeoCommander" in sess_ua.vt.full_text()
            ver_str = open(os.path.join(repo_root, "VERSION"), encoding="utf-8").read().strip()
            assert f"v{ver_str}" in sess_ua.vt.full_text(), f"Version v{ver_str} missing in HelpDialog"
            assert "◆ НАВІГАЦІЯ З КЛАВІАТУРИ" in sess_ua.vt.full_text()
            for token in (
                "◆ РОЗРОБНИК І ВІДКРИТА ЛІЦЕНЗІЯ",
                "Недбайло Костянтин Геннадійович",
                "ChessPlayerSedoy@gmail.com",
                "MIT License",
            ):
                assert token in sess_ua.vt.full_text(), f"UA HelpDialog missing {token!r}"
            hx, hy = sess_ua.vt.find_text(" Закрити ", rightmost=True)
            sess_ua.send_mouse(0, hx + 2, hy, "M")
            sess_ua.send_mouse(0, hx + 2, hy, "m")
            assert "◆ НАВІГАЦІЯ З КЛАВІАТУРИ" not in sess_ua.vt.full_text(), "Click on Закрити did not close Help"

            # Open Viewer via F3 on hello.txt, click Hex/Текст and Закрити
            sess_ua.send(b"/")
            sess_ua.send(b"hello.txt\r")
            sess_ua.send(b"\x1b[B")
            sess_ua.send(b"\x1bOR")  # F3 View
            assert "Переглядач файлів" in sess_ua.vt.full_text()
            bx, by = sess_ua.vt.find_text(" Hex/Текст ", rightmost=True)
            sess_ua.send_mouse(0, bx + 2, by, "M")
            sess_ua.send_mouse(0, bx + 2, by, "m")
            assert "00000000:" in sess_ua.vt.full_text(), "Click on Hex/Текст did not switch Viewer to hex"
            cx2, cy2 = sess_ua.vt.find_text(" Закрити ", rightmost=True)
            sess_ua.send_mouse(0, cx2 + 2, cy2, "M")
            sess_ua.send_mouse(0, cx2 + 2, cy2, "m")
            sess_ua.send(b"\x1b")

            # SIGWINCH resize 100x26 in Ukrainian mode
            sess_ua.resize(100, 26)
            assert " Мова:UA " in sess_ua.vt.row_text(0)
            assert " Вихід " in sess_ua.vt.row_text(0)
            assert "0Вихід" in sess_ua.vt.row_text(25)

            qx, qy = sess_ua.vt.find_text(" Вихід ")
            sess_ua.send_mouse(0, qx + 2, qy, "M", wait=0.1)
            assert sess_ua.wait_exit(timeout=2.0) == 0
            print("[PASS] 13. Ukrainian Dialogs, UTF-8 HitZones (Скасувати/Закрити/Hex/Вихід) & resize")
        except Exception:
            print("\n--- LAST UKRAINIAN TERMINAL SCREEN ---")
            print(sess_ua.vt.full_text())
            print("--------------------------------------")
            raise

        # 14. Auto-detection via LANG=uk_UA.UTF-8 & --lang ua CLI flag
        sess_env = PtySession(binary, [left_dir, right_dir], cols=120, rows=35, extra_env={"LANG": "uk_UA.UTF-8"})
        try:
            sess_env.drain(0.3)
            assert " Мова:UA " in sess_env.vt.row_text(0), "LANG=uk_UA.UTF-8 auto-detection failed"
            assert "0Вихід" in sess_env.vt.row_text(34)
            sess_env.send(b"q", wait=0.1)
            assert sess_env.wait_exit(timeout=2.0) == 0
        except Exception:
            print(sess_env.vt.full_text())
            raise

        sess_cli = PtySession(binary, ["--lang", "ua", left_dir, right_dir], cols=120, rows=35)
        try:
            sess_cli.drain(0.3)
            assert " Мова:UA " in sess_cli.vt.row_text(0), "--lang ua CLI flag failed"
            sess_cli.send(b"q", wait=0.1)
            assert sess_cli.wait_exit(timeout=2.0) == 0

            # Verify --version / -V / --help / --license output against VERSION & metadata
            out_ver = subprocess.check_output([binary, "--version"], text=True)
            assert f"NeoCommander v{ver_str}" in out_ver, f"--version mismatch: {out_ver!r}"
            assert "Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович)" in out_ver
            assert "ChessPlayerSedoy@gmail.com" in out_ver and "MIT License" in out_ver
            out_ver_ua = subprocess.check_output([binary, "-V", "--lang", "ua"], text=True)
            assert "без libc" in out_ver_ua and ver_str in out_ver_ua, f"-V ua mismatch: {out_ver_ua!r}"
            assert "Недбайло Костянтин Геннадійович" in out_ver_ua and "MIT License" in out_ver_ua
            out_help = subprocess.check_output([binary, "--help"], text=True)
            assert "Kostiantyn Nedbailo" in out_help and "MIT License" in out_help
            out_help_ua = subprocess.check_output([binary, "-h", "--lang", "ua"], text=True)
            assert "Недбайло Костянтин Геннадійович" in out_help_ua and "MIT License" in out_help_ua
            out_lic = subprocess.check_output([binary, "--license"], text=True)
            assert "MIT License" in out_lic and "Copyright (c) 2026 Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович)" in out_lic
            out_lic_short = subprocess.check_output([binary, "-L"], text=True)
            assert out_lic_short == out_lic
            print("[PASS] 14. Locale auto-detection, --lang ua, --version, --help & --license CLI flags")
        except Exception:
            print(sess_cli.vt.full_text())
            raise

        print("\nALL 14 END-TO-END PTY TESTS PASSED!")


if __name__ == "__main__":
    run_tests()
