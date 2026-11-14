#!/usr/bin/env python3
"""Interface language packs are data, not code: English is the built-in base, every other language
is a `*.lang` file (lang/ next to the binary, ~/.config/duop/lang, or the DUOP_LANGS search path)
of `key = value` lines over LangStrings. Packs are picked by --lang, duoprc `lang =`, LC_ALL /
LC_MESSAGES / LANG, cycled with Alt+L, fall back to English per missing key, and new languages
need no rebuild."""

import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(REPO, "duop")
VERSION = open(os.path.join(REPO, "VERSION")).read().strip()
DE = r'''# German test pack
code = DE
name = Deutsch
hdr_btn_help = " Hilfe "
hdr_btn_lang = " Sprache:DE "
msg_lang_switched = Sprache: Deutsch
dlg_title_help = Duop Hilfe (v{version})
help_lines.1 = "◆ TASTATUR \"Q\" Ende"
f_labels.1 = Hilfe
cli_usage = Aufruf: duop [VERZEICHNIS]\nZweite Zeile\n
unknown_key = ignored
no equals sign on this line
'''


def wait_text(s, needle, timeout=2.0, present=True):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s.drain(0.1)
        if (needle in s.vt.full_text()) == present:
            return True
    return False


def env_for(tmp, extra=None):
    env = {"XDG_CONFIG_HOME": os.path.join(tmp, "cfg"), "HOME": tmp, "LANG": "C.UTF-8"}
    env.update(extra or {})
    return env


def session(tmp, args, extra=None):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    for d in (left, right):
        os.makedirs(d, exist_ok=True)
    s = PtySession(BINARY, args + [left, right], extra_env=env_for(tmp, extra))
    s.drain(0.4)
    return s


def close(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def user_pack(tmp, name="de.lang", text=DE):
    d = os.path.join(tmp, "cfg", "duop", "lang")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, name), "w", encoding="utf-8").write(text)
    return d


def test_shipped_uk(tmp):
    for code in ("ua", "uk"):
        s = session(tmp, ["--lang", code])
        try:
            assert wait_text(s, " Довідка "), f"--lang {code}: Ukrainian pack not loaded:\n{s.vt.full_text()}"
            s.send(b"\x1bOP", wait=0.3)
            title = f"Довідка та архітектура Duop (v{VERSION})"
            assert wait_text(s, title), f"{{version}} not expanded in the help title:\n{s.vt.full_text()}"
        finally:
            close(s)
    print("[PASS] LP1. Shipped lang/uk.lang serves --lang ua / uk, {version} expands")


def test_user_pack_fallback(tmp):
    user_pack(tmp)
    s = session(tmp, ["--lang", "de"])
    try:
        assert wait_text(s, " Hilfe "), f"user pack de.lang not used:\n{s.vt.full_text()}"
        txt = s.vt.full_text()
        assert " Quit " in txt, "missing keys must fall back to English"
        assert "1Hilfe" in txt.replace(" ", "") or "Hilfe" in s.vt.row_text(s.rows - 1)
        s.send(b"\x1bOP", wait=0.3)
        assert wait_text(s, f"Duop Hilfe (v{VERSION})"), s.vt.full_text()
        assert '◆ TASTATUR "Q" Ende' in s.vt.full_text(), "\\\" escape not decoded"
        print("[PASS] LP2. New language from ~/.config/duop/lang/de.lang, English per missing key")
    finally:
        close(s)


def test_cycle(tmp):
    user_pack(tmp)
    s = session(tmp, ["--lang", "en"])
    try:
        assert wait_text(s, " Help ")
        for needle in (" Hilfe ", " Довідка ", " Help "):     # en -> de -> uk -> en
            s.send(b"\x1bl", wait=0.3)
            assert wait_text(s, needle), f"Alt+L did not reach {needle!r}:\n{s.vt.full_text()}"
        print("[PASS] LP3. Alt+L cycles every installed language (en -> de -> uk -> en)")
    finally:
        close(s)


def test_detection(tmp):
    user_pack(tmp)
    s = session(tmp, [], {"LANG": "de_DE.UTF-8"})
    try:
        assert wait_text(s, " Hilfe "), "LANG=de_DE.UTF-8 did not select the de pack"
    finally:
        close(s)
    os.makedirs(os.path.join(tmp, "cfg", "duop"), exist_ok=True)
    open(os.path.join(tmp, "cfg", "duop", "duoprc"), "w").write("lang = de\n")
    s = session(tmp, [])
    try:
        assert wait_text(s, " Hilfe "), "duoprc `lang = de` was ignored"
        print("[PASS] LP4. Language picked from LANG=de_DE.UTF-8 and duoprc `lang = de`")
    finally:
        close(s)


def test_no_packs(tmp):
    empty = os.path.join(tmp, "empty")
    os.makedirs(empty)
    s = session(tmp, ["--lang", "ua"], {"DUOP_LANGS": empty})
    try:
        assert wait_text(s, " Help "), "no packs: --lang ua must fall back to English"
        assert " Довідка " not in s.vt.full_text(), "Ukrainian strings are still compiled in"
        s.send(b"\x1bl", wait=0.3)
        assert wait_text(s, " Help "), "Alt+L with a single language must stay usable"
        print("[PASS] LP5. Without packs only built-in English remains (no hidden Ukrainian)")
    finally:
        close(s)


def cli(tmp, args, extra):
    r = subprocess.run([BINARY] + args, env=dict(os.environ, **env_for(tmp, extra)),
                       capture_output=True, timeout=5)
    return r.returncode, r.stdout.decode("utf-8")


def test_cli(tmp):
    code, out = cli(tmp, ["--help"], {"LANG": "uk_UA.UTF-8"})
    assert code == 0 and "Використання: duop" in out, out
    code, out = cli(tmp, ["--version"], {"LANG": "uk_UA.UTF-8"})
    assert f"Duop v{VERSION}" in out and "Ліцензія" in out, out
    user_pack(tmp)
    code, out = cli(tmp, ["--lang", "de", "--help"], {})
    assert out == "Aufruf: duop [VERZEICHNIS]\nZweite Zeile\n", repr(out)
    code, out = cli(tmp, ["--help"], {"LANG": "uk_UA.UTF-8", "DUOP_LANGS": os.path.join(tmp, "none")})
    assert "Usage: duop" in out, out
    print("[PASS] LP6. --help / --version come from the selected pack (\\n escapes), English otherwise")


def test_bad_and_duplicate(tmp):
    bad, dup = os.path.join(tmp, "bad"), os.path.join(tmp, "dup")
    os.makedirs(bad)
    os.makedirs(dup)
    with open(os.path.join(bad, "a_bad.lang"), "wb") as f:
        f.write(b"\xff\xfe\x00 = x\nhdr_btn_help = \"unterminated\n=\n  = \ncode\n" + b"x" * 200000)
    open(os.path.join(bad, "notes.txt"), "w").write("code = XX\nhdr_btn_help = \" WRONG \"\n")
    open(os.path.join(bad, "uk.lang"), "w", encoding="utf-8").write('code = UA\nhdr_btn_help = " Перший "\n')
    open(os.path.join(dup, "uk.lang"), "w", encoding="utf-8").write('code = UA\nhdr_btn_help = " Другий "\n')
    s = session(tmp, ["--lang", "uk"], {"DUOP_LANGS": bad + ":" + dup})
    try:
        assert wait_text(s, " Перший "), f"first uk.lang on the path must win:\n{s.vt.full_text()}"
        txt = s.vt.full_text()
        assert " Другий " not in txt and " WRONG " not in txt
        s.send(b"\x1bl", wait=0.3)
        s.send(b"\x1bl", wait=0.3)
        assert wait_text(s, " Перший ") or wait_text(s, " Help "), "app stopped responding"
        print("[PASS] LP7. Malformed / oversized / non-.lang files are safe; first duplicate id wins")
    finally:
        close(s)


def main():
    for case in (test_shipped_uk, test_user_pack_fallback, test_cycle, test_detection,
                 test_no_packs, test_cli, test_bad_and_duplicate):
        with tempfile.TemporaryDirectory() as tmp:
            case(tmp)
    print("ALL LANGUAGE PACK TESTS PASSED.")


if __name__ == "__main__":
    main()
