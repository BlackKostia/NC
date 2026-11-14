#!/usr/bin/env python3
"""TDD tests for ~/.config/duop/duoprc config parser, custom theme, keybinds, open rules & User Menu."""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")


def test_missing_config_uses_defaults() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cfg0_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, "hello.txt"), "w") as f:
            f.write("hi")
        env = {"DUOP_CONFIG": os.path.join(tmp, "does_not_exist"), "HOME": tmp}
        sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env=env)
        try:
            sess.drain(0.2)
            assert "hello.txt" in sess.vt.full_text()
            sess.send(b"q", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] CFG1. Missing duoprc falls back cleanly to built-in defaults")


def test_config_theme_hidden_sort_bind() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cfg1_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, ".secret"), "w") as f:
            f.write("s")
        with open(os.path.join(left, "small.txt"), "w") as f:
            f.write("a")
        with open(os.path.join(left, "big.txt"), "w") as f:
            f.write("a" * 5000)

        cfg = os.path.join(tmp, "duoprc")
        with open(cfg, "w") as f:
            f.write(
                "# Duop config test\n"
                "theme 1\n"
                "color accent #FF5500\n"
                "show_hidden 0\n"
                "sort size\n"
                "bind x quit\n"
            )
        sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env={"DUOP_CONFIG": cfg})
        try:
            sess.drain(0.25)
            screen = sess.vt.full_text()
            assert "Catppuccin" in screen, f"expected theme 1 Catppuccin in header: {screen}"
            assert ".secret" not in screen, f"show_hidden 0 should hide .secret: {screen}"
            assert screen.find("small.txt") < screen.find("big.txt"), "sort size should order small.txt before big.txt"
            sess.send(b"x", wait=0.15)
            assert sess.wait_exit(2.0) == 0, "bind x quit should exit 0"
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] CFG2. duoprc theme, color, show_hidden, sort, and bind directives work")


def test_open_rule_and_user_menu_placeholders() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cfg2_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, "a.myext"), "w") as f:
            f.write("1")
        with open(os.path.join(left, "b.myext"), "w") as f:
            f.write("2")

        open_out = os.path.join(tmp, "open.out")
        menu_out = os.path.join(tmp, "menu.out")
        cfg = os.path.join(tmp, "duoprc")
        with open(cfg, "w") as f:
            f.write(
                f"open myext printf '%s' '%f' > '{open_out}'\n"
                f"menu DumpArgs printf '%%s|%%s|%%s|%%s' '%f' '%F' '%d' '%D' > '{menu_out}'\n"
            )

        sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env={"DUOP_CONFIG": cfg})
        try:
            sess.drain(0.2)
            # Move down from '..' to 'a.myext' and press Enter -> open rule runs
            sess.send(b"\x1b[B\r", wait=0.25)
            deadline = time.monotonic() + 2.0
            while not os.path.exists(open_out) and time.monotonic() < deadline:
                time.sleep(0.05)
            assert os.path.exists(open_out), "open rule did not execute on Enter"
            assert open(open_out).read().strip() == "a.myext"

            # Mark a.myext and b.myext with Space, open User Menu via Alt+u
            sess.send(b"  ", wait=0.12)
            sess.send(b"\x1bu", wait=0.2)
            assert "User Menu" in sess.vt.full_text()
            assert "DumpArgs" in sess.vt.full_text()
            sess.send(b"\r", wait=0.25)
            deadline = time.monotonic() + 2.0
            while not os.path.exists(menu_out) and time.monotonic() < deadline:
                time.sleep(0.05)
            assert os.path.exists(menu_out), "User Menu command did not execute"
            got = open(menu_out).read().strip()
            parts = got.split("|")
            assert len(parts) == 4, f"unexpected menu output: {got!r}"
            assert "a.myext" in parts[1] and "b.myext" in parts[1], f"%F should list marked files: {parts[1]!r}"
            assert parts[2] == os.path.realpath(left)
            assert parts[3] == os.path.realpath(right)

            # Switch to UA and verify User Menu title
            sess.send(b"\x1bl", wait=0.15)
            sess.send(b"\x1bu", wait=0.18)
            assert "Меню користувача" in sess.vt.full_text()
            sess.send(b"\x1b", wait=0.1)
            sess.send(b"q", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] CFG3. open <ext> and User Menu (Alt+U) with %f/%F/%d/%D + EN/UA titles")


def main() -> None:
    test_missing_config_uses_defaults()
    test_config_theme_hidden_sort_bind()
    test_open_rule_and_user_menu_placeholders()
    print("ALL CONFIG & USER MENU TESTS PASSED.")


if __name__ == "__main__":
    main()
