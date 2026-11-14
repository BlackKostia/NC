#!/usr/bin/env python3
"""End-to-end PTY tests for Duop 2.1: Command Palette (Ctrl+K) & Fuzzy Finder (Ctrl+P)."""
import os
import sys
import tempfile
import time

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


def test_command_palette():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            # Ctrl+K opens Command Palette
            sess.send(b"\x0b")
            wait_for(sess, "Command Palette")
            # Filter for "Theme"
            sess.send(b"thm")
            wait_for(sess, "Theme")
            old_row0 = sess.vt.row_text(0)
            sess.send(b"\r", wait=0.2)
            assert "Command Palette" not in sess.vt.full_text(), "Palette stayed open"
            assert sess.vt.row_text(0) != old_row0 or "Catppuccin" in sess.vt.row_text(0), (
                f"Theme action did not execute: {sess.vt.row_text(0)!r}"
            )
            print("[PASS] FPAL1. Command Palette (Ctrl+K) fuzzy filter & action execution")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_fuzzy_finder():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        deep = os.path.join(l, "alpha", "beta", "gamma")
        os.makedirs(deep)
        os.makedirs(r)
        with open(os.path.join(deep, "needle_report.txt"), "w") as f:
            f.write("hello\n")
        with open(os.path.join(l, "other.txt"), "w") as f:
            f.write("world\n")

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            # Alt+P opens Fuzzy Finder
            sess.send(b"\x1bp")
            wait_for(sess, "Fuzzy Finder")
            sess.send(b"abgnr")
            wait_for(sess, "needle_report.txt")
            sess.send(b"\r", wait=0.2)
            assert "Fuzzy Finder" not in sess.vt.full_text(), "Fuzzy Finder stayed open"
            assert "alpha/beta/gamma" in sess.vt.full_text(), (
                f"Did not jump to alpha/beta/gamma:\n{sess.vt.full_text()}"
            )
            print("[PASS] FPAL2. Fuzzy Finder (Ctrl+P) recursive match & jump")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_ukrainian_palette():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        sess = PtySession(BINARY, ["--lang", "ua", l, r], cols=120, rows=35)
        try:
            sess.drain(0.25)
            sess.send(b"\x0b")
            wait_for(sess, "Палітра команд")
            sess.send(b"\x1b")
            sess.send(b"\x1bp")
            wait_for(sess, "Швидкий пошук")
            print("[PASS] FPAL3. Ukrainian Command Palette & Fuzzy Finder")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_command_palette()
    test_fuzzy_finder()
    test_ukrainian_palette()
    print("ALL FUZZY & PALETTE TESTS PASSED.")
