#!/usr/bin/env python3
"""TDD regression tests for critical security & data-safety fixes."""

import os
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")


def _make_pkg_tar(path: str, pkg_name: str, tool_body: str = "#!/bin/sh\necho ok\n") -> None:
    import io
    with tarfile.open(path, "w:gz") as tf:
        for name, data in [
            ("manifest.ini", f"name = {pkg_name}\nversion = 1.0\n".encode()),
            ("tool.sh", tool_body.encode()),
        ]:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))


def test_exdev_move_skip_preserves_source() -> None:
    """1. Cross-device move (-EXDEV) with Skip must never delete skipped source files."""
    with tempfile.TemporaryDirectory(prefix="duop_exdev_s_", dir="/tmp") as src_tmp, \
         tempfile.TemporaryDirectory(prefix="duop_exdev_d_", dir="/dev/shm") as dst_tmp, \
         tempfile.TemporaryDirectory(prefix="duop_exdev_h_", dir="/tmp") as home_tmp:
        if os.stat(src_tmp).st_dev == os.stat(dst_tmp).st_dev:
            print("[SKIP] EXDEV test: /tmp and /dev/shm share st_dev")
            return
        src_dir = os.path.join(src_tmp, "bundle")
        dst_dir = os.path.join(dst_tmp, "bundle")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        with open(os.path.join(src_dir, "a.txt"), "w") as f:
            f.write("NEW_A")
        with open(os.path.join(src_dir, "b.txt"), "w") as f:
            f.write("NEW_B")
        with open(os.path.join(dst_dir, "a.txt"), "w") as f:
            f.write("OLD_A")

        sess = PtySession(BINARY, ["--lang", "en", src_tmp, dst_tmp], extra_env={"HOME": home_tmp})
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.1)  # down from '..' to 'bundle'
            sess.send(b"\x1b[17~", wait=0.2)  # F6 move
            sess.send(b"\r", wait=0.35)  # confirm move -> conflict dialog for a.txt
            sess.send(b"s", wait=0.5)
            sess.send(b"q", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
        assert os.path.exists(os.path.join(dst_dir, "b.txt")), (
            f"Move did not run! dst_dir={os.listdir(dst_dir)}, screen={sess.vt.full_text()}"
        )
        assert os.path.exists(os.path.join(src_dir, "a.txt")), "Source a.txt was deleted despite Skip!"
        assert open(os.path.join(src_dir, "a.txt")).read() == "NEW_A"
        assert open(os.path.join(dst_dir, "a.txt")).read() == "OLD_A"
    print("[PASS] SEC1. Cross-device move (-EXDEV) with Skip preserves source")


def test_user_menu_command_injection() -> None:
    """2. Filenames with quotes / $() / ; must never execute commands in User Menu."""
    with tempfile.TemporaryDirectory(prefix="duop_cmdinj_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        injected = os.path.join(left, "INJECTED")
        evil = 'a"$(touch INJECTED)".txt'
        with open(os.path.join(left, evil), "w") as f:
            f.write("hello\n")

        sess = PtySession(BINARY, ["--lang", "en", left, right],
                          extra_env={"HOME": tmp, "DUOP_CONFIG": os.path.join(tmp, "none")})
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.1)  # select evil file
            sess.send(b"\x1bu", wait=0.2)   # Alt+U user menu
            sess.send(b"\x1b[B", wait=0.1)  # File info (item 2)
            sess.send(b"\r", wait=0.3)      # run it
            sess.send(b"\r", wait=0.25)     # press Enter to return
            sess.send(b"q", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
        assert not os.path.exists(injected), "Command injection created INJECTED!"
    print("[PASS] SEC2. User Menu filename expansion is immune to command injection")


def test_sigpipe_on_preview_helper_death() -> None:
    """3. Killing preview helper must not kill Duop with SIGPIPE."""
    with tempfile.TemporaryDirectory(prefix="duop_sigpipe_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        for i in range(3):
            with open(os.path.join(left, f"f{i}.txt"), "w") as f:
                f.write(f"content {i}\n")

        # Launch with SIGPIPE=SIG_DFL just like a real shell
        env = os.environ.copy()
        env["HOME"] = tmp
        env["TERM"] = "xterm-256color"
        import pty
        master, slave = pty.openpty()
        proc = subprocess.Popen(
            [BINARY, "--lang", "en", left, right],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=lambda: (os.setsid(), signal.signal(signal.SIGPIPE, signal.SIG_DFL)),
        )
        os.close(slave)
        try:
            time.sleep(0.35)
            os.write(master, b"\x10")  # Ctrl+P toggle preview
            time.sleep(0.35)
            # Kill any child process of proc
            for pid_s in os.listdir("/proc"):
                if not pid_s.isdigit():
                    continue
                try:
                    stat_s = open(f"/proc/{pid_s}/stat").read()
                    ppid = int(stat_s.rsplit(")", 1)[1].split()[1])
                    if ppid == proc.pid:
                        os.kill(int(pid_s), signal.SIGKILL)
                except OSError:
                    pass
            time.sleep(0.15)
            os.write(master, b"\x1b[B")  # move down -> triggers preview request
            time.sleep(0.25)
            assert proc.poll() is None, f"Duop died after preview helper death (rc={proc.returncode})"
            os.write(master, b"q")
            rc = proc.wait(timeout=2.0)
            assert rc == 0, f"Expected exit 0, got {rc}"
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    print("[PASS] SEC3. SIGPIPE ignored when preview helper dies")


def test_ctrl_c_in_child_does_not_exit_duop() -> None:
    """4. Ctrl-C (SIGINT) while child editor is running must not exit Duop."""
    with tempfile.TemporaryDirectory(prefix="duop_ctrlc_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        with open(os.path.join(left, "a.txt"), "w") as f:
            f.write("hello\n")
        ed = os.path.join(tmp, "ed.sh")
        with open(ed, "w") as f:
            f.write("#!/bin/sh\ntrap '' INT\nsleep 0.4\nexit 0\n")
        os.chmod(ed, 0o755)

        sess = PtySession(BINARY, ["--lang", "en", left, right],
                          extra_env={"HOME": tmp, "EDITOR": ed})
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.1)    # select a.txt
            sess.send(b"\x1b[14~", wait=0.15) # F4 edit
            os.killpg(os.getpgid(sess.pid), signal.SIGINT)
            time.sleep(0.5)
            pid, _ = os.waitpid(sess.pid, os.WNOHANG)
            assert pid == 0, "Duop exited on Ctrl-C during child editor!"
            sess.send(b"q", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                sess.wait_exit(0.5)
            except Exception:
                pass
    print("[PASS] SEC4. Ctrl-C in child editor does not exit Duop")


def test_pkg_dot_rejected_and_verify_detects_tamper() -> None:
    """5. pkg rejects manifest name '.' and pkg verify detects tampered files."""
    with tempfile.TemporaryDirectory(prefix="duop_pkgsec_") as tmp:
        env = os.environ.copy()
        env["HOME"] = tmp
        env["DUOP_PKG_DIR"] = os.path.join(tmp, "pkgs")
        dot_tar = os.path.join(tmp, "dot.tar.gz")
        _make_pkg_tar(dot_tar, ".")
        r1 = subprocess.run([BINARY, "pkg", "install", dot_tar], env=env, capture_output=True)
        assert r1.returncode != 0, "pkg install accepted manifest name '.'!"
        assert not os.path.exists(os.path.join(env["DUOP_PKG_DIR"], "tool.sh")), "dot pkg wrote to root!"

        ok_tar = os.path.join(tmp, "okpkg.tar.gz")
        _make_pkg_tar(ok_tar, "okpkg")
        r2 = subprocess.run([BINARY, "pkg", "install", ok_tar], env=env, capture_output=True)
        assert r2.returncode == 0
        tool = os.path.join(env["DUOP_PKG_DIR"], "okpkg", "tool.sh")
        assert os.path.exists(tool)
        with open(tool, "w") as f:
            f.write("#!/bin/sh\necho tampered\n")
        r3 = subprocess.run([BINARY, "pkg", "verify", "okpkg"], env=env, capture_output=True)
        assert r3.returncode != 0, "pkg verify failed to detect tampered file!"
    print("[PASS] SEC5. pkg rejects '.' name and pkg verify detects tampering")


def test_sigabrt_restores_terminal() -> None:
    """6. SIGABRT restores terminal (alt screen off) before process dies."""
    with tempfile.TemporaryDirectory(prefix="duop_abrt_") as tmp:
        left = os.path.join(tmp, "l")
        right = os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        sess = PtySession(BINARY, ["--lang", "en", left, right], extra_env={"HOME": tmp})
        try:
            sess.drain(0.25)
            os.kill(sess.pid, signal.SIGABRT)
            _, st = os.waitpid(sess.pid, 0)
            assert os.WIFSIGNALED(st) and os.WTERMSIG(st) == signal.SIGABRT, f"Expected SIGABRT, got {st}"
            raw = os.read(sess.master, 4096)
            assert b"\x1b[?1049l" in raw, "Terminal alt screen was not restored on SIGABRT!"
        finally:
            try:
                os.kill(sess.pid, signal.SIGKILL)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] SEC6. SIGABRT restores terminal before dying")


if __name__ == "__main__":
    test_exdev_move_skip_preserves_source()
    test_user_menu_command_injection()
    test_sigpipe_on_preview_helper_death()
    test_ctrl_c_in_child_does_not_exit_duop()
    test_pkg_dot_rejected_and_verify_detects_tamper()
    test_sigabrt_restores_terminal()
    print("ALL SECURITY & RELIABILITY TESTS PASSED")
