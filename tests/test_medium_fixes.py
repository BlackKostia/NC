#!/usr/bin/env python3
"""Regression tests for 8 medium-severity reliability, durability, and liveness bugs."""

import os
import pty
import shutil
import subprocess
import sys
import tempfile
import termios
import time
import fcntl
import struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession, VirtualTerminal  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_F5 = b"\x1b[15~"
KEY_F8 = b"\x1b[19~"
KEY_F10 = b"\x1b[21~"
KEY_ALT_B = b"\x1bb"


def wait_for_text(sess: PtySession, needle: str, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        if needle in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {needle!r};\n{sess.vt.full_text()}")


def test_m1_flush_eagain_and_dirty_recovery() -> None:
    """M1: sys_write_all handles EAGAIN via POLLOUT and ScreenBuffer_flush sets force_full on error."""
    with open(os.path.join(REPO_ROOT, "src/core/syscall.c")) as f:
        sc = f.read()
    with open(os.path.join(REPO_ROOT, "src/tui/screen.c")) as f:
        scr = f.read()
    assert "EAGAIN" in sc, "sys_write_all must handle -EAGAIN"
    assert "force_full" in scr.split("sys_write_all")[1], (
        "ScreenBuffer_flush must set force_full=1 when sys_write_all fails"
    )
    print("[PASS] M1. sys_write_all handles EAGAIN and ScreenBuffer_flush marks force_full on failure")


def test_m2_term_restore_eintr_retry() -> None:
    """M2: os_term_restore retries TCSETSW/ioctl on -EINTR on both x86_64 and aarch64."""
    for arch in ("x86_64", "aarch64"):
        p = os.path.join(REPO_ROOT, f"src/os/linux/{arch}/pal_os.s")
        txt = open(p).read()
        body = txt.split("os_term_restore:")[1].split("\n\n")[0]
        assert "EINTR" in body or "#4" in body, f"{arch} os_term_restore must retry on -EINTR"
    print("[PASS] M2. os_term_restore retries ioctl on -EINTR (x86_64 & aarch64)")


def test_m3_bounded_dir_recursion() -> None:
    """M3: Worker recursion is bounded (MAX_DIR_DEPTH) so deep trees fail cleanly without SIGSEGV."""
    with tempfile.TemporaryDirectory(prefix="duop_m3_") as tmp:
        left = os.path.join(tmp, "L")
        right = os.path.join(tmp, "R")
        os.mkdir(left)
        os.mkdir(right)
        deep = os.path.join(left, "deep")
        os.mkdir(deep)
        dfd = os.open(deep, os.O_RDONLY | os.O_DIRECTORY)
        for _ in range(520):
            os.mkdir("d", dir_fd=dfd)
            ndfd = os.open("d", os.O_RDONLY | os.O_DIRECTORY, dir_fd=dfd)
            os.close(dfd)
            dfd = ndfd
        os.close(dfd)

        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            wait_for_text(sess, "deep")
            sess.send(KEY_DOWN)
            time.sleep(0.08)
            sess.send(KEY_F8)
            wait_for_text(sess, "Delete")
            sess.send(b"\r")
            wait_for_text(sess, "Filesystem operation failed", timeout=30.0)
            sess.send(KEY_F10)
            rc = sess.wait_exit(timeout=3.0)
            assert rc == 0, f"expected clean exit 0, got {rc}"
        finally:
            try:
                sess.wait_exit(timeout=0.2)
            except Exception:
                pass
            subprocess.run(["rm", "-rf", deep], check=False)
    print("[PASS] M3. Bounded worker recursion fails cleanly on 550-level tree without SIGSEGV")


def test_m4_atomic_state_and_trashinfo_writes() -> None:
    """M4: Bookmarks, frecency, and trashinfo are written atomically (temp + fsync + rename), not O_TRUNC."""
    for rel in (
        "src/fs/nav_persist.c",
        "src/fs/trash_info.c",
    ):
        txt = open(os.path.join(REPO_ROOT, rel)).read()
        assert "O_TRUNC" not in txt, f"{rel} still uses O_TRUNC in place!"
        assert "tmp_commit_atomic" in txt, f"{rel} must commit via tmp_commit_atomic!"
    tf = open(os.path.join(REPO_ROOT, "src/core/tmpfile.c")).read()
    assert "os_fsync" in tf and "os_renameat2" in tf, "tmp_commit_atomic missing fsync/rename"

    if shutil.which("strace"):
        with tempfile.TemporaryDirectory(prefix="duop_m4_") as tmp:
            home = os.path.join(tmp, "home")
            os.makedirs(os.path.join(home, ".local/share/duop"), exist_ok=True)
            work = os.path.join(tmp, "work")
            os.mkdir(work)
            os.mkdir(os.path.join(work, "sub"))
            trace_log = os.path.join(tmp, "strace.log")
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            env["HOME"] = home
            env["XDG_DATA_HOME"] = os.path.join(home, ".local/share")
            proc = subprocess.Popen(
                ["strace", "-e", "trace=openat,fsync,renameat,renameat2", "-o", trace_log,
                 BINARY, "--lang", "en", work, work],
                stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
            )
            os.close(slave)
            try:
                time.sleep(0.4)
                os.write(master, KEY_DOWN + b"\r")
                time.sleep(0.25)
                os.write(master, KEY_F10)
                rc = proc.wait(timeout=3.0)
                assert rc == 0
            finally:
                os.close(master)
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            trace = open(trace_log).read()
            assert "frecency.tmp" in trace and "fsync(" in trace and ("renameat2(" in trace or "renameat(" in trace), (
                f"Expected atomic temp+fsync+renameat(2) for frecency:\n{trace}"
            )
    print("[PASS] M4. State files and trashinfo use atomic temp + fsync + rename")


def test_m5_bulk_rename_noreplace() -> None:
    """M5: BulkRenameDialog uses RENAME_NOREPLACE and never silently overwrites colliding files."""
    with tempfile.TemporaryDirectory(prefix="duop_m5_") as tmp:
        with open(os.path.join(tmp, "a_one.txt"), "w") as f:
            f.write("KEEP_A")
        with open(os.path.join(tmp, "b_one.txt"), "w") as f:
            f.write("KEEP_B")

        sess = PtySession(BINARY, ["--lang", "en", tmp, tmp])
        try:
            wait_for_text(sess, "a_one.txt")
            sess.send(KEY_DOWN)
            sess.send(b" ")  # mark a_one.txt
            sess.send(KEY_ALT_B)
            wait_for_text(sess, "Bulk Rename")
            sess.send(b"b_one.txt\r")
            time.sleep(0.25)

            assert open(os.path.join(tmp, "b_one.txt")).read() == "KEEP_B", (
                "b_one.txt was silently overwritten by Bulk Rename!"
            )
            assert os.path.exists(os.path.join(tmp, "a_one.txt")), "a_one.txt disappeared!"
            sess.send(KEY_F10)
            rc = sess.wait_exit(timeout=3.0)
            assert rc == 0
        finally:
            try:
                sess.wait_exit(timeout=0.2)
            except Exception:
                pass
    print("[PASS] M5. Bulk Rename refuses to overwrite existing file on collision")


def test_m6_ppoll_error_exits_cleanly() -> None:
    """M6: Persistent ppoll error (!= EINTR) exits UI cleanly instead of spinning."""
    with open(os.path.join(REPO_ROOT, "src/tui/input.c")) as f:
        inp = f.read()
    with open(os.path.join(REPO_ROOT, "src/tui/input_parse.c")) as f:
        ip = f.read()
    with open(os.path.join(REPO_ROOT, "src/app/app_loop.s")) as f:
        al = f.read()
    assert "return -2" in inp and "r == -2" in ip and ".Larun_fatal_evt" in al, (
        "Fatal ppoll error must propagate to App_run exit"
    )
    print("[PASS] M6. Persistent ppoll error exits UI cleanly")


def test_m7_mem_alloc_big_overflow_guard() -> None:
    """M7: mem_alloc_big rejects size >= -4112 instead of wrapping around."""
    with tempfile.TemporaryDirectory(prefix="duop_m7_") as tmp:
        harness = os.path.join(tmp, "test_mab.s")
        with open(harness, "w") as f:
            f.write(
                ".intel_syntax noprefix\n"
                ".global _start\n"
                ".extern mem_alloc\n"
                "_start:\n"
                "    mov rdi, -16\n"
                "    call mem_alloc\n"
                "    test rax, rax\n"
                "    jnz 1f\n"
                "    xor edi, edi\n"
                "    mov eax, 60\n"
                "    syscall\n"
                "1:\n"
                "    mov edi, 1\n"
                "    mov eax, 60\n"
                "    syscall\n"
            )
        obj = os.path.join(tmp, "test_mab.o")
        exe = os.path.join(tmp, "test_mab")
        subprocess.run(["as", harness, "-o", obj], check=True)
        subprocess.run(
            ["ld", obj,
             os.path.join(REPO_ROOT, "build/core/memory.o"),
             os.path.join(REPO_ROOT, "build/core/memcheck.o"),
             os.path.join(REPO_ROOT, "build/os/linux/x86_64/pal_os.o"),
             os.path.join(REPO_ROOT, "build/os/linux/x86_64/pal_file.o"),
             os.path.join(REPO_ROOT, "build/os/linux/x86_64/pal_sys_mem.o"),
             os.path.join(REPO_ROOT, "build/os/linux/x86_64/pal_simd.o"),
             os.path.join(REPO_ROOT, "build/os/linux/x86_64/pal_fault.o"),
             "-o", exe],
            check=True,
        )
        res = subprocess.run([exe], check=False)
        assert res.returncode == 0, f"mem_alloc(-16) did not return NULL (rc={res.returncode})"
    print("[PASS] M7. mem_alloc_big rejects size overflow cleanly")


def test_m8_preview_fcntl_checked() -> None:
    """M8: preview_io.c checks os_set_nonblock return values on both preview pipes."""
    txt = open(os.path.join(REPO_ROOT, "src/fs/preview_io.c")).read()
    body = txt.split("static intptr_t pv_setup_parent_pipes", 1)[1].split("\n}\n", 1)[0]
    assert body.count("os_set_nonblock(") == 2, "both preview pipes are switched to non-blocking"
    assert "int r = os_set_nonblock(" in body and "if (r >= 0) r = os_set_nonblock(" in body and "if (r < 0) {" in body, \
        "os_set_nonblock results not checked in preview_io.c"
    print("[PASS] M8. preview_io.c checks os_set_nonblock results")


if __name__ == "__main__":
    test_m1_flush_eagain_and_dirty_recovery()
    test_m2_term_restore_eintr_retry()
    test_m3_bounded_dir_recursion()
    test_m4_atomic_state_and_trashinfo_writes()
    test_m5_bulk_rename_noreplace()
    test_m6_ppoll_error_exits_cleanly()
    test_m7_mem_alloc_big_overflow_guard()
    test_m8_preview_fcntl_checked()
    print("ALL MEDIUM FIXES TESTS PASSED.")
