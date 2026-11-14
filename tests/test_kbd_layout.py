#!/usr/bin/env python3
"""Keyboard layouts are data, not code: `*.layout` files (layouts/ next to the binary, the user's
~/.config/duop/layouts, or the DUOP_LAYOUTS search path) map what a non-Latin layout types to the
Latin key underneath, so Alt/Ctrl and single-letter hotkeys work in any layout and new layouts are
added by dropping a file -- no rebuild."""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(REPO, "duop")
UA_HELP = "Довідка"
GREEK = "# Greek over US QWERTY\nname = Ελληνικά\nkeys  = qwertyuiopasdfghjklzxcvbnm\n" \
        "chars = ;ςερτυθιοπασδφγηξκλζχψωβνμ\n"


def alt(ch):
    return b"\x1b" + ch.encode("utf-8")


def wait_text(s, needle, timeout=2.0, present=True):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s.drain(0.1)
        if (needle in s.vt.full_text()) == present:
            return True
    return False


def session(tmp, env):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    for d in (left, right):
        os.makedirs(d, exist_ok=True)
    open(os.path.join(left, "a.txt"), "w").write("x\n")
    base = {"XDG_CONFIG_HOME": os.path.join(tmp, "cfg"), "HOME": tmp}
    base.update(env)
    s = PtySession(BINARY, ["--lang", "en", left, right], extra_env=base)
    s.drain(0.4)
    return s


def close(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def toggles_lang(s, key):
    s.send(key, wait=0.2)
    return wait_text(s, UA_HELP)


def test_shipped_layout(tmp):
    s = session(tmp, {})
    try:
        assert toggles_lang(s, alt("д")), f"Alt+д (L key, Ukrainian) did not switch language:\n{s.vt.full_text()}"
        print("[PASS] KL1. Shipped layouts/uk.layout maps Alt+д to Alt+L")
    finally:
        close(s)


def test_user_layout_dir(tmp):
    lay = os.path.join(tmp, "cfg", "duop", "layouts")
    os.makedirs(lay)
    open(os.path.join(lay, "el.layout"), "w").write(GREEK)
    s = session(tmp, {})
    try:
        assert toggles_lang(s, alt("λ")), f"Greek Alt+λ from a user layout file was ignored:\n{s.vt.full_text()}"
        print("[PASS] KL2. A new layout dropped into ~/.config/duop/layouts works without a rebuild")
    finally:
        close(s)


def test_search_path_override(tmp):
    empty, extra = os.path.join(tmp, "none"), os.path.join(tmp, "extra")
    os.makedirs(empty)
    os.makedirs(extra)
    open(os.path.join(extra, "el.layout"), "w").write(GREEK)
    s = session(tmp, {"DUOP_LAYOUTS": empty})
    try:
        s.send(alt("д"), wait=0.3)
        assert not wait_text(s, UA_HELP, 0.6), "Cyrillic mapping still active without any layout file"
        assert toggles_lang(s, b"\x1bl"), "Latin Alt+L must work with no layouts at all"
        print("[PASS] KL3. No layout files -> no hidden built-in mapping; Latin hotkeys unaffected")
    finally:
        close(s)
    s = session(tmp, {"DUOP_LAYOUTS": empty + ":" + extra})
    try:
        assert toggles_lang(s, alt("λ")), "second directory of DUOP_LAYOUTS was not searched"
        print("[PASS] KL4. DUOP_LAYOUTS is a ':'-separated search path")
    finally:
        close(s)


def test_dialog_letter_keys(tmp):
    s = session(tmp, {})
    try:
        s.send(b"\x1bOP", wait=0.3)                       # F1 help
        assert wait_text(s, "Architecture"), f"help did not open:\n{s.vt.full_text()}"
        s.send("й".encode("utf-8"), wait=0.3)             # Q key on the Ukrainian layout
        assert wait_text(s, "Architecture", 1.0, present=False), \
            f"help did not close on 'й' (q):\n{s.vt.full_text()}"
        print("[PASS] KL5. Single-letter dialog hotkeys follow the layout files (й = q)")
    finally:
        close(s)


def test_bad_files(tmp):
    lay = os.path.join(tmp, "bad")
    os.makedirs(lay)
    with open(os.path.join(lay, "a_garbage.layout"), "wb") as f:
        f.write(b"\xff\xfe\x00junk\nkeys\nchars = \xd0\nkeys = abc\nchars = \xe2\x82\n" + b"=" * 70000)
    open(os.path.join(lay, "b_dots.layout"), "w").write("keys = /.\nchars = .ю\n")
    open(os.path.join(lay, "c_ignored.txt"), "w").write("keys = t\nchars = д\n")
    open(os.path.join(lay, "d_el.layout"), "w").write(GREEK)
    s = session(tmp, {"DUOP_LAYOUTS": lay})
    try:
        s.send(alt("д"), wait=0.3)
        assert not wait_text(s, UA_HELP, 0.5), "a non-*.layout file was loaded"
        s.send(b".", wait=0.3)                            # ASCII '.' must keep its own meaning
        s.drain(0.3)
        assert toggles_lang(s, alt("λ")), "valid layout after malformed ones was not loaded"
        print("[PASS] KL6. Malformed / oversized / non-.layout files are skipped safely")
    finally:
        close(s)


def main():
    for case in (test_shipped_layout, test_user_layout_dir, test_search_path_override,
                 test_dialog_letter_keys, test_bad_files):
        with tempfile.TemporaryDirectory() as tmp:
            case(tmp)
    print("ALL KEYBOARD LAYOUT TESTS PASSED.")


if __name__ == "__main__":
    main()
