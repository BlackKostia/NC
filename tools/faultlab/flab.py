#!/usr/bin/env python3
"""faultlab runtime: PTY session under the ptrace injector, fixtures, scenarios and oracles.

One run = fresh fixture + one Duop session driven through a real PTY + post-run oracles:
exit status, fatal signals (with symbolized rip), terminal restore, data integrity."""

from __future__ import annotations

import bisect
import fcntl
import hashlib
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from test_pty import VirtualTerminal  # noqa: E402

FAULTLAB = os.environ.get("FAULTLAB_BIN", str(ROOT / "build" / "faultlab"))
DUOP = os.environ.get("DUOP_BIN", str(ROOT / "duop"))
SHM = Path("/dev/shm")



def ensure_faultlab():
    """Build the ptrace injector on first use (gcc, no dependencies)."""
    src = Path(__file__).resolve().parent / "faultlab.c"
    if not os.path.exists(FAULTLAB) or os.path.getmtime(FAULTLAB) < src.stat().st_mtime:
        os.makedirs(os.path.dirname(FAULTLAB), exist_ok=True)
        subprocess.run(["gcc", "-O2", "-Wall", "-Wextra", "-o", FAULTLAB, str(src)], check=True)


K_DOWN, K_ESC, K_F3, K_F5, K_F6, K_F8, K_F10 = b"\x1b[B", b"\x1b", b"\x1b[13~", b"\x1b[15~", b"\x1b[17~", b"\x1b[19~", b"\x1b[21~"
OK_MARKS = ("Copied successfully", "Moved successfully", "Deleted successfully")
ERR_MARKS = ("Filesystem operation failed", "Permission denied", "Destination already exists",
             "File or directory not found", "Directory not empty", "Target is a directory",
             "Not a directory", "Operation canceled", "Another background operation")
SEV = ["OK", "RECOVERED_FAULT", "PARTIAL_LEFT", "SILENT_FAILURE", "WORKER_CRASH", "TTY_DIRTY",
       "UNRESPONSIVE", "SILENT_CORRUPTION", "DATA_LOSS", "WRONG_TARGET", "HANG", "CRASH_UI"]


class Session:
    def __init__(self, argv, cwd, env_extra=None, cols=110, rows=32):
        self.vt = VirtualTerminal(cols, rows)
        self.raw = bytearray()
        self.seen: set[str] = set()
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.tio0 = termios.tcgetattr(self.slave)
        self.status = None
        self.pid = os.fork()
        if self.pid == 0:
            os.close(self.master)
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
            for fd in (0, 1, 2):
                os.dup2(self.slave, fd)
            os.close(self.slave)
            os.chdir(cwd)
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("XDG_", "LC_", "DUOP_"))}
            env.update(TERM="xterm-256color", LANG="C.UTF-8")
            env.update(env_extra or {})
            os.execve(argv[0], argv, env)
            os._exit(127)

    def drain(self, wait=0.03):
        end = time.monotonic() + wait
        while True:
            r, _, _ = select.select([self.master], [], [], max(0.0, min(0.02, end - time.monotonic())))
            if r:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    self.raw += chunk
                    self.vt.feed(chunk)
                    text = self.vt.full_text()
                    self.seen.update(m for m in OK_MARKS + ERR_MARKS if m in text)
                    continue
            if time.monotonic() >= end:
                return

    def send(self, data: bytes, wait=0.05):
        try:
            os.write(self.master, data)
        except OSError:
            pass
        self.drain(wait)

    def wait_for(self, pred, timeout=3.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.drain(0.02)
            if pred():
                return True
            if self.exited():
                return False
        return False

    def on_screen(self, text):
        return text in self.vt.full_text()

    def exited(self):
        if self.status is None:
            pid, st = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = st
        return self.status is not None

    def wait_exit(self, timeout):
        return self.wait_for(self.exited, timeout) or self.exited()

    def tty_dirty(self):
        """Reasons the terminal was left unusable ([] = restored)."""
        bad = []
        tio = termios.tcgetattr(self.slave)
        if tio[:4] != self.tio0[:4]:
            bad.append("termios")
        raw = bytes(self.raw)
        for on, off, what in ((b"\x1b[?1049h", b"\x1b[?1049l", "altscreen"),
                              (b"\x1b[?1000h", b"\x1b[?1000l", "mouse"),
                              (b"\x1b[?25l", b"\x1b[?25h", "cursor")):
            if raw.rfind(on) > raw.rfind(off):
                bad.append(what)
        return bad

    def close(self):
        if self.status is None:
            try:
                os.killpg(os.getpgid(self.pid), signal.SIGKILL)
            except OSError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except OSError:
                pass
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass


# ---- fixture -------------------------------------------------------------------------------
def _png(w=8, h=8):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    rows = b"".join(b"\x00" + b"".join(bytes((x * 30 % 256, y * 30 % 256, 128)) for x in range(w))
                    for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def build_template(dst: Path, big_mib=6):
    """Left-pane content: `tree` (nested dirs, 0-byte/large files, symlink, modes) plus loose files."""
    import random
    rnd = random.Random(7)
    (dst / "tree" / "sub1" / "sub2").mkdir(parents=True)
    (dst / "tree" / "empty_dir").mkdir()
    for i, rel in enumerate(["tree/f0.bin", "tree/f1.txt", "tree/sub1/f2.bin", "tree/sub1/f3.bin",
                             "tree/sub1/sub2/f4.bin", "tree/sub1/sub2/f5.bin", "tree/zero.dat"]):
        size = [70000, 1200, 300000, 17, 4096, 131072, 0][i]
        (dst / rel).write_bytes(rnd.randbytes(size))
    os.chmod(dst / "tree/f1.txt", 0o600)
    os.symlink("f1.txt", dst / "tree" / "link_f1")
    (dst / "a_note.txt").write_text("".join(f"line {i} of the note\n" for i in range(200)))
    (dst / "big.bin").write_bytes(rnd.randbytes(big_mib << 20))
    (dst / "pic.png").write_bytes(_png())


def snapshot(root: Path):
    """{relpath: digest} for files, 'L:<target>' for symlinks, 'D' for directories."""
    out = {}
    if not root.exists():
        return out
    for dirpath, dirs, files in os.walk(root):
        for name in dirs + files:
            p = Path(dirpath) / name
            rel = str(p.relative_to(root))
            if p.is_symlink():
                out[rel] = "L:" + os.readlink(p)
            elif p.is_dir():
                out[rel] = "D"
            else:
                try:
                    out[rel] = hashlib.sha1(p.read_bytes()).hexdigest()
                except OSError as exc:
                    out[rel] = f"E:{exc.errno}"
    return out


class Fixture:
    """left = tmpfs (/dev/shm), right = disk or tmpfs: cross-device forces the read/write path."""

    def __init__(self, template: Path, xdev: bool):
        self.base_l = Path(subprocess.run(["mktemp", "-d", "-p", str(SHM), "flab.XXXXXX"], capture_output=True, text=True).stdout.strip())
        self.base_r = Path(subprocess.run(["mktemp", "-d", "-p", "/tmp" if xdev else str(SHM), "flab.XXXXXX"], capture_output=True, text=True).stdout.strip())
        self.left, self.right, self.home = self.base_l / "L", self.base_r / "R", self.base_l / "home"
        shutil.copytree(template, self.left, symlinks=True)
        self.right.mkdir()
        self.home.mkdir()
        (self.right / "keep.txt").write_text("right pane sentinel\n")
        self.before_l, self.before_r = snapshot(self.left), snapshot(self.right)
        self.report = self.base_l / "report.txt"

    def cleanup(self):
        shutil.rmtree(self.base_l, ignore_errors=True)
        shutil.rmtree(self.base_r, ignore_errors=True)


# ---- symbols -------------------------------------------------------------------------------
class Symbols:
    def __init__(self, binary):
        self.addrs, self.names = [], []
        out = subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1] in "tTbBrR":
                self.addrs.append(int(parts[0], 16))
                self.names.append(parts[2])

    def name(self, addr):
        i = bisect.bisect_right(self.addrs, addr) - 1
        if i < 0 or addr - self.addrs[i] > 0x20000:
            return hex(addr)
        off = addr - self.addrs[i]
        return self.names[i] + (f"+{off:#x}" if off else "")


def parse_report(path: Path):
    rep = {"faults": [], "hits": [], "blocked": [], "counts": {"ui": {}, "child": {}}, "seu": None}
    if not path.exists():
        return rep
    for line in path.read_text(errors="replace").splitlines():
        key, _, val = line.partition("=")
        if key == "fault":
            f = dict(kv.split("=") for kv in ("sig=" + val).split())
            rep["faults"].append({"sig": int(f["sig"]), "role": int(f["role"]), "rip": int(f["rip"], 16), "addr": int(f["addr"], 16)})
        elif key == "hit":
            rep["hits"].append(val)
        elif key == "blocked":
            rep["blocked"].append(val)
        elif key == "seu":
            rep["seu"] = val
        elif key.startswith("count."):
            _, role, nr = key.split(".")
            rep["counts"][role][int(nr)] = int(val)
        elif key in ("exit", "killed", "hang", "orphans"):
            rep[key] = int(val)
        elif key.endswith(".hits"):
            rep.setdefault("rule_hits", []).append(int(val))
    return rep
