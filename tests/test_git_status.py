#!/usr/bin/env python3
"""TDD test for 2.5 Git Integration: branch badge & file status (M/A/?)."""
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "duop")


def wait_for(sess, text, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def test_git_status():
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "repo")
        r = os.path.join(tmp, "plain")
        os.makedirs(l)
        os.makedirs(r)

        git(l, "init")
        git(l, "config", "user.email", "duop@example.com")
        git(l, "config", "user.name", "Duop")
        git(l, "checkout", "-b", "feat-x")

        with open(os.path.join(l, "tracked.txt"), "w") as f:
            f.write("v1\n")
        git(l, "add", "tracked.txt")
        git(l, "commit", "-m", "init")

        # Modified, Staged, Untracked
        with open(os.path.join(l, "tracked.txt"), "w") as f:
            f.write("v2\n")
        with open(os.path.join(l, "staged.txt"), "w") as f:
            f.write("new\n")
        git(l, "add", "staged.txt")
        with open(os.path.join(l, "untracked.txt"), "w") as f:
            f.write("untracked\n")

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
        try:
            wait_for(sess, "feat-x")
            screen = sess.vt.full_text()
            lines = screen.splitlines()

            def find_row(name):
                for ln in lines:
                    if name in ln:
                        return ln
                raise AssertionError(f"Missing row {name!r} in:\n{screen}")

            assert "M" in find_row("tracked.txt"), f"Expected M for tracked.txt:\n{find_row('tracked.txt')}"
            assert "A" in find_row("staged.txt"), f"Expected A for staged.txt:\n{find_row('staged.txt')}"
            assert "?" in find_row("untracked.txt"), f"Expected ? for untracked.txt:\n{find_row('untracked.txt')}"
            print("[PASS] GIT1. Branch badge & M/A/? file statuses")

            # Switch to plain dir (Tab) -> branch badge should not show feat-x as active
            sess.send(b"\t", wait=0.25)
            screen2 = sess.vt.full_text()
            assert "feat-x" not in screen2.splitlines()[0], f"Header should not show feat-x on plain dir:\n{screen2.splitlines()[0]}"
            print("[PASS] GIT2. Non-git pane clears branch badge")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


if __name__ == "__main__":
    test_git_status()
    print("ALL GIT STATUS TESTS PASSED.")
