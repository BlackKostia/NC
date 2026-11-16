#!/usr/bin/env python3
"""Regression tests for 5 critical data-loss, path-truncation, and OOM bugs."""

import fcntl
import os
import pty
import resource
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession, VirtualTerminal  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_F2 = b"\x1bOQ"
KEY_F5 = b"\x1b[15~"
KEY_F8 = b"\x1b[19~"
KEY_F10 = b"\x1b[21~"
KEY_CTRL_U = b"\x15"


def wait_for_text(sess: PtySession, needle: str, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        if needle in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {needle!r};\n{sess.vt.full_text()}")


def test_c1_f2_rename_no_overwrite() -> None:
    """C1: F2 Rename must not silently overwrite an existing destination file."""
    with tempfile.TemporaryDirectory(prefix="duop_c1_") as tmp:
        alpha = os.path.join(tmp, "alpha.txt")
        beta = os.path.join(tmp, "beta.txt")
        with open(alpha, "w") as f:
            f.write("ALPHA_CONTENT")
        with open(beta, "w") as f:
            f.write("BETA_CONTENT")

        sess = PtySession(BINARY, ["--lang", "en", tmp, tmp])
        try:
            wait_for_text(sess, "alpha.txt")
            sess.send(KEY_DOWN)  # select alpha.txt (past ..)
            time.sleep(0.08)
            sess.send(KEY_F2)
            wait_for_text(sess, "Rename")
            sess.send(KEY_CTRL_U + b"beta.txt\r")
            wait_for_text(sess, "Destination already exists")

            assert os.path.exists(alpha), "alpha.txt should still exist"
            assert open(alpha).read() == "ALPHA_CONTENT", "alpha.txt was modified"
            assert open(beta).read() == "BETA_CONTENT", "beta.txt was overwritten!"
            sess.send(KEY_F10)
            rc = sess.wait_exit(timeout=3.0)
            assert rc == 0, f"expected clean exit 0, got {rc}"
        finally:
            try:
                sess.wait_exit(timeout=0.2)
            except Exception:
                pass
    print("[PASS] C1. F2 Rename refuses to overwrite existing file")


def _make_deep_cwd(base: str, target_len: int = 4090) -> str:
    cur = base
    seg = "d" * 200
    while len(cur) + 1 + len(seg) < target_len - 10:
        cur = os.path.join(cur, seg)
        os.mkdir(cur)
    rem = target_len - len(cur) - 1
    if rem > 0:
        cur = os.path.join(cur, "x" * rem)
        os.mkdir(cur)
    assert len(cur) == target_len, f"got {len(cur)}"
    return cur


def test_c2_path_join_no_silent_truncation_delete() -> None:
    """C2: path_join must fail with ENAMETOOLONG instead of truncating cwd/database -> cwd/data."""
    with tempfile.TemporaryDirectory(prefix="duop_c2_") as tmp:
        deep = _make_deep_cwd(tmp, 4090)
        dfd = os.open(deep, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fd1 = os.open("data", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd)
            os.write(fd1, b"KEEP_DATA")
            os.close(fd1)
            fd2 = os.open("database", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd)
            os.write(fd2, b"KEEP_DATABASE")
            os.close(fd2)

            sess = PtySession(BINARY, ["--lang", "en", deep, tmp])
            try:
                wait_for_text(sess, "database")
                # Entries sorted: .., data, database -> 2x DOWN selects database
                sess.send(KEY_DOWN + KEY_DOWN)
                time.sleep(0.08)
                sess.send(KEY_F8)
                wait_for_text(sess, "Delete")
                sess.send(b"\r")
                wait_for_text(sess, "Filesystem operation failed")

                screen = sess.vt.full_text()
                assert "Deleted successfully" not in screen, "Reported false success!"
                st1 = os.stat("data", dir_fd=dfd)
                assert st1.st_size == 9, "WRONG FILE 'data' WAS DELETED/MODIFIED!"
                os.stat("database", dir_fd=dfd)
                sess.send(KEY_F10)
                rc = sess.wait_exit(timeout=3.0)
                assert rc == 0
            finally:
                try:
                    sess.wait_exit(timeout=0.2)
                except Exception:
                    pass
        finally:
            os.close(dfd)
    print("[PASS] C2. path_join rejects PATH_MAX overflow instead of deleting wrong file")


def test_c3_stat_error_does_not_alter_copy_dest() -> None:
    """C3: Failing stat() (!= ENOENT) on destination must abort instead of setting join_dst=0."""
    with tempfile.TemporaryDirectory(prefix="duop_c3_") as tmp:
        src = os.path.join(tmp, "src")
        locked = os.path.join(tmp, "locked")
        os.mkdir(src)
        os.mkdir(locked)
        tree = os.path.join(src, "tree")
        os.mkdir(tree)
        with open(os.path.join(tree, "leaf.txt"), "w") as f:
            f.write("LEAF")
        # Make locked/R un-stat-able with EACCES (not ENOENT)
        os.mkdir(os.path.join(locked, "R"))
        os.chmod(locked, 0o000)

        try:
            sess = PtySession(BINARY, ["--lang", "en", src, tmp])
            try:
                wait_for_text(sess, "tree")
                sess.send(KEY_DOWN)  # select tree
                time.sleep(0.08)
                sess.send(KEY_F5)
                wait_for_text(sess, "Copy")
                sess.send(KEY_CTRL_U + os.path.join(locked, "R").encode() + b"\r")
                wait_for_text(sess, "Permission denied")

                sess.send(KEY_F10)
                rc = sess.wait_exit(timeout=3.0)
                assert rc == 0
            finally:
                try:
                    sess.wait_exit(timeout=0.2)
                except Exception:
                    pass
        finally:
            os.chmod(locked, 0o755)
    print("[PASS] C3. Non-ENOENT stat error aborts copy instead of altering destination")


def test_c4_resize_enomem_no_heap_corruption() -> None:
    """C4: ScreenBuffer_resize must not update width/height when mem_realloc fails (ENOMEM)."""
    with tempfile.TemporaryDirectory(prefix="duop_c4_") as tmp:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"

        def limit_as() -> None:
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024, 64 * 1024 * 1024))

        proc = subprocess.Popen(
            [BINARY, "--lang", "en", tmp, tmp],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            preexec_fn=limit_as,
            close_fds=True,
        )
        os.close(slave)
        try:
            time.sleep(0.3)
            # Request 10000x10000 -> ~1.6 GB -> guaranteed ENOMEM under 64 MiB RLIMIT_AS
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 10000, 10000, 0, 0))
            os.kill(proc.pid, signal.SIGWINCH)
            time.sleep(0.3)
            assert proc.poll() is None, f"duop crashed on ENOMEM resize (rc={proc.returncode})"

            # Restore sane size and exit cleanly
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            os.kill(proc.pid, signal.SIGWINCH)
            time.sleep(0.15)
            os.write(master, KEY_F10)
            rc = proc.wait(timeout=3.0)
            assert rc == 0, f"expected clean exit 0 after ENOMEM resize, got {rc}"
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    print("[PASS] C4. ScreenBuffer_resize survives ENOMEM without heap corruption")


def test_c5_copy_calls_fsync_on_dest() -> None:
    """C5: File copy must fsync() the destination fd before closing."""
    if not shutil.which("strace"):
        print("[SKIP] C5. strace not installed")
        return
    with tempfile.TemporaryDirectory(prefix="duop_c5_") as tmp:
        src_dir = os.path.join(tmp, "src")
        dst_dir = os.path.join(tmp, "dst")
        os.mkdir(src_dir)
        os.mkdir(dst_dir)
        with open(os.path.join(src_dir, "payload.bin"), "wb") as f:
            f.write(b"DURABLE_DATA" * 100)

        trace_log = os.path.join(tmp, "strace.log")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        proc = subprocess.Popen(
            ["strace", "-f", "-e", "trace=fsync", "-o", trace_log,
             BINARY, "--lang", "en", src_dir, dst_dir],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            close_fds=True,
        )
        os.close(slave)
        try:
            vt = VirtualTerminal(80, 24)
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                time.sleep(0.05)
                try:
                    os.set_blocking(master, False)
                    data = os.read(master, 65536)
                    if data:
                        vt.feed(data)
                except BlockingIOError:
                    pass
                if "payload.bin" in vt.full_text():
                    break

            os.write(master, KEY_DOWN)
            time.sleep(0.08)
            os.write(master, KEY_F5)
            time.sleep(0.2)
            os.write(master, b"\r")
            time.sleep(0.4)
            os.write(master, KEY_F10)
            rc = proc.wait(timeout=3.0)
            assert rc == 0, f"expected clean exit 0, got {rc}"
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        dst_file = os.path.join(dst_dir, "payload.bin")
        assert os.path.exists(dst_file), "payload.bin was not copied"
        trace = open(trace_log).read()
        assert "fsync(" in trace, f"Expected fsync() syscall during copy, got:\n{trace}"
    print("[PASS] C5. File copy issues fsync() on destination")


if __name__ == "__main__":
    test_c1_f2_rename_no_overwrite()
    test_c2_path_join_no_silent_truncation_delete()
    test_c3_stat_error_does_not_alter_copy_dest()
    test_c4_resize_enomem_no_heap_corruption()
    test_c5_copy_calls_fsync_on_dest()
    print("ALL CRITICAL FIXES TESTS PASSED.")
