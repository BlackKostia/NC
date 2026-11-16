#!/usr/bin/env python3
"""ZIP extraction hardening (audit 2026-11-16): inflate capacity must survive mem_alloc.

AH1 deflated entries of any size (incl. > 64 KiB slab limit) open in the viewer
AH2 an entry whose real output exceeds its declared size never overflows the heap
"""

import os
import struct
import sys
import tempfile
import zipfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")
KEY_DOWN = b"\x1b[B"
KEY_F3 = b"\x1b[13~"
MARKER = "telemetry frame 00000000 ok"


def alive(sess: PtySession) -> bool:
    pid, _ = os.waitpid(sess.pid, os.WNOHANG)
    return pid == 0


def kill_session(sess: PtySession) -> None:
    try:
        os.kill(sess.pid, 9)
        os.waitpid(sess.pid, 0)
    except OSError:
        pass
    try:
        os.close(sess.master)
    except OSError:
        pass


def telemetry(size: int) -> bytes:
    body = b"".join(b"telemetry frame %08d ok\n" % i for i in range(size // 25 + 1))
    return body[:size]


def open_first_entry(sess: PtySession, key_after: bytes = KEY_F3) -> None:
    sess.drain(0.5)
    sess.send(KEY_DOWN, wait=0.2)       # archive file
    sess.send(b"\r", wait=0.7)          # enter archive
    sess.send(KEY_DOWN, wait=0.3)       # first entry
    sess.send(key_after, wait=1.5)      # F3: extract + view
    sess.drain(1.0)


def test_deflated_entries_of_all_sizes_open() -> None:
    for size in (1000, 65000, 66000, 200000, 3000000):
        with tempfile.TemporaryDirectory(prefix="ah1_") as tmp:
            left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
            os.makedirs(left)
            os.makedirs(right)
            with zipfile.ZipFile(os.path.join(left, "a.zip"), "w", zipfile.ZIP_DEFLATED) as z:
                z.writestr("data.txt", telemetry(size))
            sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env={"HOME": tmp})
            try:
                open_first_entry(sess)
                assert alive(sess), f"{size} B deflated entry: process died"
                assert MARKER in sess.vt.full_text(), f"{size} B deflated entry did not open in the viewer"
            finally:
                kill_session(sess)
    print("[PASS] AH1. Deflated ZIP entries up to 3 MB (incl. > 64 KiB) open in the viewer")


def lying_zip(path: str, declared: int, real: int) -> None:
    raw = b"A" * real
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    cdata = comp.compress(raw) + comp.flush()
    name = b"lie.bin"
    crc = zlib.crc32(raw) & 0xFFFFFFFF
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 8, 0, 0x21, crc, len(cdata), declared, len(name), 0) + name
    central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 8, 0, 0x21, crc, len(cdata), declared,
                          len(name), 0, 0, 0, 0, 0, 0) + name
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(central), len(local) + len(cdata), 0)
    with open(path, "wb") as f:
        f.write(local + cdata + central + eocd)


def test_understated_size_is_rejected_without_overflow() -> None:
    for declared in (100, 5000, 60000):
        with tempfile.TemporaryDirectory(prefix="ah2_") as tmp:
            left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
            os.makedirs(left)
            os.makedirs(right)
            lying_zip(os.path.join(left, "lie.zip"), declared, 3000000)
            for i in range(20):
                with open(os.path.join(left, f"file{i:02d}.txt"), "w") as f:
                    f.write("x")
            sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env={"HOME": tmp})
            try:
                sess.drain(0.5)
                sess.send(b"\x1b[F", wait=0.2)        # End -> lie.zip (sorted last)
                sess.send(b"\r", wait=0.7)
                sess.send(KEY_DOWN, wait=0.3)
                sess.send(KEY_F3, wait=1.5)
                sess.drain(1.0)
                assert alive(sess), f"declared {declared} B / real 3 MB: process died (heap overflow)"
                for k in (b"\x1b", b"\x1b[A", b"\x1b[B", b"\x1b[6~", b"\x1b[5~"):
                    sess.send(k, wait=0.2)
                assert alive(sess), "process died while navigating after the rejected extraction"
                assert "Name" in sess.vt.full_text(), "UI stopped redrawing after the rejected extraction"
            finally:
                kill_session(sess)
    print("[PASS] AH2. Understated ZIP sizes are rejected; no heap overflow, UI stays healthy")


def main() -> None:
    test_deflated_entries_of_all_sizes_open()
    test_understated_size_is_rejected_without_overflow()
    print("ALL ARCHIVE HARDENING TESTS PASSED.")


if __name__ == "__main__":
    main()
