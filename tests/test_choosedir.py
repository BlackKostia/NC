#!/usr/bin/env python3
"""TDD tests for --choosedir=FILE (cd-on-exit) and shell wrapper."""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")


def test_choosedir_eq_and_subdir() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cd_") as tmp:
        left = os.path.join(tmp, "left")
        sub = os.path.join(left, "alpha_sub")
        right = os.path.join(tmp, "right")
        out_file = os.path.join(tmp, "chosen.dir")
        os.makedirs(sub)
        os.makedirs(right)

        sess = PtySession(BINARY, ["--lang", "en", f"--choosedir={out_file}", left, right])
        try:
            sess.drain(0.2)
            assert "alpha_sub" in sess.vt.full_text()
            sess.send(b"\x1b[B\r", wait=0.18)
            assert "alpha_sub" in sess.vt.full_text()
            sess.send(b"q", wait=0.15)
            rc = sess.wait_exit(timeout=2.0)
            assert rc == 0, f"expected exit 0, got {rc}"
        finally:
            try:
                sess.wait_exit(timeout=0.5)
            except Exception:
                pass

        assert os.path.exists(out_file), "--choosedir output file was not created"
        chosen = open(out_file, "r", encoding="utf-8").read().strip()
        assert chosen == os.path.realpath(sub), f"expected {os.path.realpath(sub)!r}, got {chosen!r}"
    print("[PASS] C1. --choosedir=FILE writes active pane subdir on exit")


def test_choosedir_space_and_right_pane() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cd2_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right_target")
        out_file = os.path.join(tmp, "chosen_right")
        os.makedirs(left)
        os.makedirs(right)

        sess = PtySession(BINARY, ["--lang", "ua", "--choosedir", out_file, left, right])
        try:
            sess.drain(0.2)
            assert "right_target" in sess.vt.full_text()
            sess.send(b"\t", wait=0.1)
            sess.send(b"q", wait=0.15)
            rc = sess.wait_exit(timeout=2.0)
            assert rc == 0, f"expected exit 0, got {rc}"
        finally:
            try:
                sess.wait_exit(timeout=0.5)
            except Exception:
                pass

        assert os.path.exists(out_file), "--choosedir output file was not created"
        chosen = open(out_file, "r", encoding="utf-8").read().strip()
        assert chosen == os.path.realpath(right), f"expected {os.path.realpath(right)!r}, got {chosen!r}"
    print("[PASS] C2. --choosedir FILE writes inactive-turned-active right pane on exit")


def test_choosedir_bad_output_path_no_crash() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_cd3_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        bad = os.path.join(tmp, "missing_parent", "chosen")
        sess = PtySession(BINARY, ["--lang", "en", f"--choosedir={bad}", left, right])
        try:
            sess.drain(0.2)
            sess.send(b"q", wait=0.15)
            rc = sess.wait_exit(timeout=2.0)
            assert rc == 0, f"expected clean exit 0 even when choosedir write fails, got {rc}"
        finally:
            try:
                sess.wait_exit(timeout=0.5)
            except Exception:
                pass
    print("[PASS] C3. Invalid --choosedir path does not crash on exit")


def test_help_and_wrapper() -> None:
    for args in (["--lang", "en", "--help"], ["--lang", "ua", "--help"]):
        res = subprocess.run([BINARY, *args], capture_output=True, text=True, check=True)
        assert "--choosedir" in res.stdout, f"--choosedir missing in {args}: {res.stdout}"
    wrapper = os.path.join(REPO_ROOT, "scripts", "duop-cd.sh")
    assert os.path.isfile(wrapper), f"missing shell wrapper: {wrapper}"
    subprocess.run(["bash", "-n", wrapper], check=True)
    print("[PASS] C4. --help EN/UA documents --choosedir and scripts/duop-cd.sh passes bash -n")


def main() -> None:
    test_choosedir_eq_and_subdir()
    test_choosedir_space_and_right_pane()
    test_choosedir_bad_output_path_no_crash()
    test_help_and_wrapper()
    print("ALL CHOOSEDIR TESTS PASSED.")


if __name__ == "__main__":
    main()
