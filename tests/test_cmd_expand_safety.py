#!/usr/bin/env python3
"""User-menu / open-rule command expansion safety (audit 2026-11-16).

CE1 hostile file names are shell-safe in every quoting context (unquoted, '..', "..") for %f and %F
CE2 an expansion that does not fit is refused (EN/UA message) and never executed
CE3 large (but fitting) expansions are complete: no silent truncation at 2 KiB
"""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402
from par import run_parallel  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_ALT_U = b"\x1bu"
KEY_CTRL_A = b"\x01"

HOSTILE = [
    "q'uote.txt",
    'd"quote.txt',
    "$(touch${IFS}PWN1).txt",
    "`touch${IFS}PWN2`.txt",
    "semi;touch${IFS}PWN3.txt",
    "back\\slash.txt",
    "-dash.txt",
    "ünï файл.txt".replace(" ", "_"),
]
MARKERS = ("PWN1", "PWN2", "PWN3", "PWN4")


def kill(sess: PtySession) -> None:
    try:
        os.kill(sess.pid, 9)
        os.waitpid(sess.pid, 0)
    except OSError:
        pass
    try:
        os.close(sess.master)
    except OSError:
        pass


def wait_for(path: str, timeout: float = 4.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            time.sleep(0.15)
            return True
        time.sleep(0.05)
    return False


def run_menu(tmp: str, left: str, cmd: str, keys: bytes, lang: str = "en", settle: float = 0.8) -> PtySession:
    right = os.path.join(tmp, "r")
    os.makedirs(right, exist_ok=True)
    cfg = os.path.join(tmp, "duoprc")
    with open(cfg, "w", encoding="utf-8") as f:
        f.write(f"menu T {cmd}\n")
    sess = PtySession(BINARY, ["--lang", lang, left, right], extra_env={"DUOP_CONFIG": cfg, "HOME": tmp})
    sess.drain(0.5)
    sess.send(keys, wait=0.4)
    sess.send(KEY_ALT_U, wait=0.3)
    sess.send(b"\r", wait=settle)
    return sess


def make_files(left: str, names: list[str]) -> None:
    os.makedirs(left, exist_ok=True)
    for n in names:
        with open(os.path.join(left, n), "w", encoding="utf-8") as f:
            f.write("x")


def no_markers(left: str, where: str) -> None:
    for m in MARKERS:
        assert not os.path.exists(os.path.join(left, m)), f"{where}: command injection executed ({m} exists)"


def test_selection_list_is_quote_aware() -> None:
    cases = {
        "unquoted": "printf '%%s|' %F > '{out}'",
        "single": "printf '%%s|' '%F' > '{out}'",
        "double": "printf '%%s|' \"%F\" > '{out}'",
        "double-mixed": "printf '%%s|' \"pre %F post\" > '{out}'",
    }
    for kind, tpl in cases.items():
        with tempfile.TemporaryDirectory(prefix="ce1_") as tmp:
            left = os.path.join(tmp, "l")
            make_files(left, HOSTILE)
            out = os.path.join(tmp, "out.txt")
            sess = run_menu(tmp, left, tpl.format(out=out), KEY_CTRL_A)
            try:
                assert wait_for(out), f"{kind}: command did not run"
                got = open(out, encoding="utf-8").read()
                no_markers(left, kind)
                if kind == "unquoted":
                    assert sorted(got.split("|")[:-1]) == sorted(HOSTILE), f"unquoted: wrong argv {got!r}"
                else:
                    pre, post = ("pre ", " post") if kind == "double-mixed" else ("", "")
                    assert got.endswith(post + "|") and got.startswith(pre), f"{kind}: bad framing {got!r}"
                    body = got[len(pre): len(got) - len(post) - 1]
                    assert sorted(body.split(" ")) == sorted(HOSTILE), f"{kind}: names lost or altered: {got!r}"
            finally:
                kill(sess)
    print("[PASS] CE1a. %F is shell-safe unquoted, in '...' and in \"...\" (no injection, names exact)")


def test_current_name_is_quote_aware() -> None:
    names = ["q'uote.txt", 'd"quote.txt', "$(touch${IFS}PWN1).txt", "a b;touch${IFS}PWN4.txt", "back\\slash.txt"]
    cases = {
        "unquoted": "printf '%%s|' %f > '{out}'",
        "single": "printf '%%s|' '%f' > '{out}'",
        "double": "printf '%%s|' \"%f\" > '{out}'",
    }
    def one(name: str, kind: str, tpl: str) -> None:                  # every (name, quoting) pair is its own session
        with tempfile.TemporaryDirectory(prefix="ce1b_") as tmp:
            left = os.path.join(tmp, "l")
            make_files(left, [name])
            out = os.path.join(tmp, "out.txt")
            sess = run_menu(tmp, left, tpl.format(out=out), KEY_DOWN)
            try:
                assert wait_for(out), f"{kind}/{name!r}: command did not run"
                assert open(out, encoding="utf-8").read() == name + "|", f"{kind}: {name!r} altered"
                no_markers(left, f"{kind}/{name!r}")
            finally:
                kill(sess)

    run_parallel([lambda n=n, k=k, t=t: one(n, k, t) for n in names for k, t in cases.items()])
    print("[PASS] CE1b. %f is shell-safe in every quoting context for hostile names")


def test_oversized_expansion_is_refused() -> None:
    for lang, needle in (("en", "Command too long"), ("ua", "Команда задовга")):
        with tempfile.TemporaryDirectory(prefix="ce2_") as tmp:
            left = os.path.join(tmp, "l")
            make_files(left, [f"f{i:04d}_" + "x" * 190 + ".dat" for i in range(1200)])
            out = os.path.join(tmp, "out.txt")
            ran = os.path.join(left, "EXECUTED")
            cmd = f"touch EXECUTED; printf '%%s' %F > '{out}'"
            sess = run_menu(tmp, left, cmd, KEY_CTRL_A, lang=lang, settle=1.2)
            try:
                sess.drain(1.0)
                assert not wait_for(ran, 1.5), f"{lang}: oversized command was executed (truncated!)"
                assert not os.path.exists(out), f"{lang}: output file created by a refused command"
                assert needle in sess.vt.full_text(), f"{lang}: missing refusal message {needle!r}"
                assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0, f"{lang}: process died"
            finally:
                kill(sess)
    print("[PASS] CE2. Oversized %F expansion is refused with an EN/UA message and never executed")


def test_large_expansions_are_complete() -> None:
    with tempfile.TemporaryDirectory(prefix="ce3a_") as tmp:
        left = os.path.join(tmp, "l")
        names = [f"report_{i:04d}_" + "y" * 90 + ".csv" for i in range(300)]       # ~30 KB of names
        make_files(left, names)
        out = os.path.join(tmp, "out.txt")
        sess = run_menu(tmp, left, f"printf '%%s|' %F > '{out}'", KEY_CTRL_A, settle=1.5)
        try:
            assert wait_for(out, 6.0), "300-name selection: command did not run"
            got = open(out, encoding="utf-8").read().split("|")[:-1]
            assert sorted(got) == sorted(names), f"300-name selection truncated: {len(got)}/{len(names)} args"
        finally:
            kill(sess)
    with tempfile.TemporaryDirectory(prefix="ce3b_") as tmp:
        left = os.path.join(tmp, "l")
        os.makedirs(left)
        cwd = os.getcwd()
        parts = []
        os.chdir(left)
        try:
            for i in range(11):
                part = f"{i:02d}" + "d" * 198
                os.mkdir(part)
                os.chdir(part)
                parts.append(part)
            with open("target.txt", "w") as f:
                f.write("x")
        finally:
            os.chdir(cwd)
        deep = os.path.join(left, *parts)
        out = os.path.join(tmp, "out.txt")
        sess = run_menu(tmp, deep, f"exec >'{out}'; printf '%%s' \"%p\"; echo; echo TAIL_EXECUTED", KEY_DOWN)
        try:
            assert wait_for(out), "deep path: command did not run"
            got = open(out, encoding="utf-8").read()
            want = os.path.join(deep, "target.txt")
            assert got == want + "\nTAIL_EXECUTED\n", f"deep path expansion truncated ({len(got)} of {len(want)} bytes)"
        finally:
            kill(sess)
    print("[PASS] CE3. Fitting expansions (300 names / 2240-byte path) are complete, tail of the command intact")


def main() -> None:
    run_parallel([test_selection_list_is_quote_aware, test_current_name_is_quote_aware, test_oversized_expansion_is_refused,
                  test_large_expansions_are_complete])
    print("ALL COMMAND EXPANSION SAFETY TESTS PASSED.")


if __name__ == "__main__":
    main()
