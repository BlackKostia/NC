#!/usr/bin/env python3
"""End-to-end PTY tests for Duop 2.4: Archive VFS (.tar, .tar.gz, .zip)."""
import io
import os
import sys
import tarfile
import tempfile
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def wait_for(sess, text, timeout=2.5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def build_archives(d):
    for mode, fname in [("w", "a_pack.tar"), ("w:gz", "b_pack.tar.gz")]:
        with tarfile.open(os.path.join(d, fname), mode) as tf:
            for name, data in [("readme.txt", b"hello from tar\n"), ("sub/nested.dat", b"nested tar payload\n")]:
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    with zipfile.ZipFile(os.path.join(d, "c_pack.zip"), "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("readme.txt", b"hello from zip\n")
        zf.writestr("sub/nested.dat", b"nested zip payload\n")


def test_archives():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        build_archives(l)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            # 1. Enter a_pack.tar
            sess.send(b"\x1b[B")  # a_pack.tar
            sess.send(b"\r")
            wait_for(sess, "readme.txt")
            assert "sub" in sess.vt.full_text(), f"Missing sub/ in tar:\n{sess.vt.full_text()}"
            # View readme.txt via F3
            sess.send(b"\x1b[B")  # sub
            sess.send(b"\x1b[B")  # readme.txt
            sess.send(b"\x1bOR")  # F3
            wait_for(sess, "hello from tar")
            sess.send(b"\x1b", wait=0.15)  # close viewer
            # Exit tar via Backspace
            sess.send(b"\x7f", wait=0.2)
            wait_for(sess, "b_pack.tar.gz")
            print("[PASS] ARC1. .tar VFS browse & F3 view")

            # 2. Enter b_pack.tar.gz
            sess.send(b"\x1b[B")  # b_pack.tar.gz
            sess.send(b"\r")
            wait_for(sess, "readme.txt")
            sess.send(b"\x7f", wait=0.2)
            wait_for(sess, "c_pack.zip")
            print("[PASS] ARC2. .tar.gz VFS inflate & browse")

            # 3. Enter c_pack.zip -> sub -> nested.dat -> F3 view
            sess.send(b"\x1b[B")  # c_pack.zip
            sess.send(b"\r")
            wait_for(sess, "sub")
            sess.send(b"\x1b[B")  # sub
            sess.send(b"\r")
            wait_for(sess, "nested.dat")
            sess.send(b"\x1b[B")  # nested.dat
            sess.send(b"\x1bOR")  # F3
            wait_for(sess, "nested zip payload")
            print("[PASS] ARC3. .zip VFS nested browse & F3 inflate view")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_archives()
    print("ALL ARCHIVE VFS TESTS PASSED.")
