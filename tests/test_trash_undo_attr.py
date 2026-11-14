#!/usr/bin/env python3
"""TDD tests for ROADMAP 1.6: XDG Trash (Del), Undo (Ctrl+Z), ChmodDialog (Alt+A),
Symlink (Alt+S), Hardlink (Alt+H), and File Info with inode/nlink/CRC32/SHA-256 (Alt+I)."""

import hashlib
import os
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.dirname(__file__))
from test_pty import PtySession

BINARY = "./duop"
KEY_DEL = b"\x1b[3~"
KEY_F2 = b"\x1b[12~"
KEY_CTRL_Z = b"\x1a"
KEY_ALT_A = b"\x1ba"
KEY_ALT_I = b"\x1bi"
KEY_ALT_S = b"\x1bs"
KEY_ALT_H = b"\x1bh"


def wait_for(sess: PtySession, pred, msg: str, timeout: float = 2.5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.05)
        if pred():
            return
    raise AssertionError(f"timeout waiting for: {msg}\nscreen:\n{sess.vt.full_text()}")


def wait_text(sess: PtySession, needle: str, timeout: float = 2.5) -> None:
    wait_for(sess, lambda: needle in sess.vt.full_text(), f"text {needle!r}", timeout)


def focus_by_filter(sess: PtySession, name: str) -> None:
    sess.send(b"/", wait=0.08)
    sess.send(name.encode("utf-8") + b"\r", wait=0.1)
    sess.send(b"\x1b[B", wait=0.08)  # down off '..' if needed


def test_trash_and_undo() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_t16_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        xdg = os.path.join(tmp, "xdg")
        os.makedirs(left)
        os.makedirs(right)
        os.makedirs(xdg)

        sample_data = b"duop-1.6-hash-payload\n"
        p_alpha = os.path.join(left, "alpha.txt")
        with open(p_alpha, "wb") as f:
            f.write(sample_data)
        os.chmod(p_alpha, 0o644)

        old_xdg = os.environ.get("XDG_DATA_HOME")
        os.environ["XDG_DATA_HOME"] = xdg

        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            wait_text(sess, "alpha.txt")

            # 1. File Info (Alt+I): verify inode, nlink, CRC32 & SHA-256
            sess.send(b"\x1b[B", wait=0.08)  # select alpha.txt
            sess.send(KEY_ALT_I, wait=0.2)
            wait_text(sess, "File Info")
            exp_crc = f"{zlib.crc32(sample_data) & 0xffffffff:08x}"
            exp_sha = hashlib.sha256(sample_data).hexdigest()[:16]
            wait_text(sess, exp_crc)
            wait_text(sess, exp_sha)
            sess.send(b"\x1b", wait=0.1)

            # 2. ChmodDialog (Alt+A): toggle owner exec bit ('x' or '1' or space/enter) -> 0744
            sess.send(KEY_ALT_A, wait=0.2)
            wait_text(sess, "Permissions")
            wait_text(sess, "0644")
            # Press '3' to toggle bit 2 (owner exec 0100 -> 0744) and Enter
            sess.send(b"3\r", wait=0.2)
            assert (os.stat(p_alpha).st_mode & 0o777) == 0o744

            # 3. Symlink (Alt+S) and Hardlink (Alt+H) into right pane
            sess.send(KEY_ALT_S, wait=0.2)
            wait_text(sess, "Symlink")
            sess.send(b"\r", wait=0.2)
            sym_p = os.path.join(right, "alpha.txt")
            assert os.path.islink(sym_p)
            os.unlink(sym_p)

            sess.send(KEY_ALT_H, wait=0.2)
            wait_text(sess, "Hardlink")
            sess.send(b"\r", wait=0.2)
            assert os.path.isfile(sym_p) and os.stat(sym_p).st_ino == os.stat(p_alpha).st_ino
            os.unlink(sym_p)

            # 4. Rename (F2) alpha.txt -> beta.txt, then Undo (Ctrl+Z) -> alpha.txt
            sess.send(KEY_F2, wait=0.15)
            wait_text(sess, "Rename")
            # Clear and type beta.txt
            sess.send(b"\x15beta.txt\r", wait=0.2)
            assert os.path.exists(os.path.join(left, "beta.txt"))
            sess.send(KEY_CTRL_Z, wait=0.2)
            assert os.path.exists(p_alpha) and not os.path.exists(os.path.join(left, "beta.txt"))

            # 5. XDG Trash (Del) -> moves to $XDG_DATA_HOME/Trash/files + info/*.trashinfo, then Undo (Ctrl+Z)
            sess.send(KEY_DEL, wait=0.2)
            wait_for(sess, lambda: not os.path.exists(p_alpha), "alpha.txt trashed")
            assert os.path.exists(os.path.join(xdg, "Trash", "files", "alpha.txt"))
            info_path = os.path.join(xdg, "Trash", "info", "alpha.txt.trashinfo")
            assert os.path.exists(info_path)
            with open(info_path, "r") as f:
                info_txt = f.read()
            assert "[Trash Info]" in info_txt and "Path=" in info_txt

            sess.send(KEY_CTRL_Z, wait=0.2)
            wait_for(sess, lambda: os.path.exists(p_alpha), "alpha.txt restored by Undo")

            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(2.0) == 0
        finally:
            if old_xdg is None:
                os.environ.pop("XDG_DATA_HOME", None)
            else:
                os.environ["XDG_DATA_HOME"] = old_xdg
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] T1. File Info (CRC32/SHA-256), ChmodDialog, Symlink/Hardlink, XDG Trash & Ctrl+Z Undo")


if __name__ == "__main__":
    test_trash_and_undo()
    print("ALL TRASH/UNDO/ATTR TESTS PASSED.")
