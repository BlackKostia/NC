#!/usr/bin/env python3
"""Opening a directory must never execute code from an untrusted repository (audit 2026-11-16).

GT1 core.fsmonitor in .git/config is neutralized (marker never created) and the branch still shows
GT2 a local [filter] driver (clean filters run during `git status`) keeps git disabled for that repo
GT3 [include] could pull in filters/hooks from anywhere: git stays disabled
GT4 a hung `git` cannot freeze the UI; the helper is killed and git integration is switched off
GT5 a plain repository keeps its branch badge and file status
"""

import os
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")


def git(cwd: str, *args: str) -> None:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", *args], cwd=cwd, check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_repo(root: str, branch: str = "feat-x") -> str:
    repo = os.path.join(root, "repo")
    os.makedirs(repo)
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "duop@example.com")
    git(repo, "config", "user.name", "Duop")
    git(repo, "checkout", "-q", "-b", branch)
    with open(os.path.join(repo, "tracked.txt"), "w") as f:
        f.write("v1\n")
    git(repo, "add", "tracked.txt")
    git(repo, "commit", "-q", "-m", "init")
    return repo


def append_config(repo: str, text: str) -> None:
    with open(os.path.join(repo, ".git", "config"), "a") as f:
        f.write(text)


def evil_script(root: str, marker: str) -> str:
    path = os.path.join(root, "evil.sh")
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\necho executed > '{marker}'\nprintf '\\0'\ncat\n")
    os.chmod(path, 0o755)
    return path


def open_dir(root: str, repo: str, env: dict | None = None, wait: float = 1.6) -> PtySession:
    other = os.path.join(root, "other")
    os.makedirs(other, exist_ok=True)
    sess = PtySession(BINARY, ["--lang", "en", repo, other], extra_env=dict({"HOME": root}, **(env or {})))
    sess.drain(wait)
    return sess


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


def dirty_tracked(repo: str) -> None:
    time.sleep(1.1)                                    # make the stat info of tracked.txt "racy"
    with open(os.path.join(repo, "tracked.txt"), "w") as f:
        f.write("version two, different size\n")


def test_fsmonitor_is_neutralized() -> None:
    with tempfile.TemporaryDirectory(prefix="gt1_") as tmp:
        repo = make_repo(tmp)
        marker = os.path.join(tmp, "PWNED_FSMONITOR")
        append_config(repo, f"[core]\n\tfsmonitor = {evil_script(tmp, marker)}\n")
        sess = open_dir(tmp, repo)
        try:
            assert not os.path.exists(marker), "core.fsmonitor hook was executed by the git status refresh"
            assert "feat-x" in sess.vt.full_text(), "branch badge disappeared for a repo with fsmonitor configured"
        finally:
            kill(sess)
    print("[PASS] GT1. core.fsmonitor from .git/config is never executed; branch badge still works")


def test_filter_driver_blocks_git() -> None:
    with tempfile.TemporaryDirectory(prefix="gt2_") as tmp:
        repo = make_repo(tmp)
        marker = os.path.join(tmp, "PWNED_FILTER")
        with open(os.path.join(repo, ".gitattributes"), "w") as f:
            f.write("* filter=evil\n")
        git(repo, "add", ".gitattributes")
        git(repo, "commit", "-q", "-m", "attrs")
        append_config(repo, f'[filter "evil"]\n\tclean = {evil_script(tmp, marker)}\n')
        dirty_tracked(repo)
        sess = open_dir(tmp, repo)
        try:
            assert not os.path.exists(marker), "a local clean-filter driver was executed by git status"
            assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0, "process died"
        finally:
            kill(sess)
    print("[PASS] GT2. A repository defining a [filter] driver never gets `git status` run on it")


def test_include_blocks_git() -> None:
    with tempfile.TemporaryDirectory(prefix="gt3_") as tmp:
        repo = make_repo(tmp)
        marker = os.path.join(tmp, "PWNED_INCLUDE")
        extra = os.path.join(tmp, "extra.cfg")
        with open(extra, "w") as f:
            f.write(f'[filter "evil"]\n\tclean = {evil_script(tmp, marker)}\n')
        with open(os.path.join(repo, ".gitattributes"), "w") as f:
            f.write("* filter=evil\n")
        git(repo, "add", ".gitattributes")
        git(repo, "commit", "-q", "-m", "attrs")
        append_config(repo, f"[include]\n\tpath = {extra}\n")
        dirty_tracked(repo)
        sess = open_dir(tmp, repo)
        try:
            assert not os.path.exists(marker), "config pulled in through [include] was executed"
        finally:
            kill(sess)
    print("[PASS] GT3. [include] in a repository config keeps git disabled")


def test_hung_git_cannot_freeze_ui() -> None:
    with tempfile.TemporaryDirectory(prefix="gt4_") as tmp:
        repo = make_repo(tmp)
        fakebin = os.path.join(tmp, "fakebin")
        os.makedirs(fakebin)
        pidfile = os.path.join(tmp, "git.pid")
        with open(os.path.join(fakebin, "git"), "w") as f:
            f.write(f"#!/bin/sh\necho $$ > '{pidfile}'\nexec sleep 60\n")
        os.chmod(os.path.join(fakebin, "git"), 0o755)
        t0 = time.monotonic()
        sess = open_dir(tmp, repo, env={"PATH": fakebin + ":/usr/bin:/bin"}, wait=0.3)
        try:
            sess.resize(100, 30)
            deadline = time.monotonic() + 8.0
            while time.monotonic() < deadline and "Name" not in sess.vt.full_text():
                sess.drain(0.1)
            assert "Name" in sess.vt.full_text(), "UI never became responsive while git hung"
            assert time.monotonic() - t0 < 7.0, "UI blocked for too long behind a hung git"
            assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0, "process died"
            deadline = time.monotonic() + 6.0
            while time.monotonic() < deadline and not os.path.exists(pidfile):
                time.sleep(0.1)
            pid = int(open(pidfile).read().strip())
            deadline = time.monotonic() + 6.0
            alive = True
            while time.monotonic() < deadline and alive:
                try:
                    os.kill(pid, 0)
                    time.sleep(0.2)
                except ProcessLookupError:
                    alive = False
            assert not alive, "the hung git helper was not killed"
        finally:
            kill(sess)
    print("[PASS] GT4. A hung git is killed after a short deadline and the UI stays responsive")


def test_plain_repo_still_works() -> None:
    with tempfile.TemporaryDirectory(prefix="gt5_") as tmp:
        repo = make_repo(tmp)
        with open(os.path.join(repo, "untracked.txt"), "w") as f:
            f.write("u\n")
        sess = open_dir(tmp, repo)
        try:
            screen = sess.vt.full_text()
            assert "feat-x" in screen, "branch badge missing for a plain repository"
            assert any("untracked.txt" in line and "?" in line for line in screen.splitlines()), "no status flag"
        finally:
            kill(sess)
    print("[PASS] GT5. Plain repositories keep the branch badge and per-file status")


def main() -> None:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    test_fsmonitor_is_neutralized()
    test_filter_driver_blocks_git()
    test_include_blocks_git()
    test_hung_git_cannot_freeze_ui()
    test_plain_repo_still_works()
    print("ALL GIT TRUST TESTS PASSED.")


if __name__ == "__main__":
    main()
