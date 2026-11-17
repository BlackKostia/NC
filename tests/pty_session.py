"""Terminal test fixtures shared by the PTY suites: a minimal ANSI/UTF-8 virtual screen (VirtualTerminal) and a forked child on a pseudo-terminal
(PtySession). Moved out of test_pty.py unchanged except for the adaptive drain; test_pty re-exports both names."""

import fcntl
import os
import pty
import select
import signal
import struct
import termios
import time


class VtScreen:
    """The cell grid of the virtual terminal: colours, cursor and the text accessors the tests assert on."""

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




class VirtualTerminal(VtScreen):
    """Minimal ANSI/UTF-8 virtual terminal: feed() decodes the byte stream (SGR colours, cursor moves, erase, alternate screen) into the grid."""

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

    # A long wait is a budget ("done by now"), not a goal: once the program has drawn something and then been silent for QUIET seconds the
    # frame is complete (QUIET > WATCH_DEBOUNCE_MS = 150, the longest delay inside the app), so the drain ends early. Short waits keep
    # their exact length. DUOP_PTY_FULL_WAIT=1 restores the fixed waits (debugging a timing-sensitive failure).
    QUIET = 0.25
    EARLY_FROM = 0.4
    FULL_WAIT = os.environ.get("DUOP_PTY_FULL_WAIT") == "1"

    def drain(self, wait=0.15):
        start = time.monotonic()
        deadline = start + wait
        last_data = None
        early = wait >= self.EARLY_FROM and not self.FULL_WAIT
        while True:
            now = time.monotonic()
            rem = deadline - now
            if rem <= 0 or (early and last_data is not None and now - last_data >= self.QUIET):
                break
            r, _, _ = select.select([self.master], [], [], min(rem, 0.05))
            if not r:
                continue
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    break
                self.vt.feed(chunk)
                last_data = time.monotonic()
                # Keep draining immediately available bursts
                deadline = max(deadline, last_data + 0.05)
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
