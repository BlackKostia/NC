#!/usr/bin/env python3
"""End-to-end CLI & PTY tests for Duop Package Manager (duop pkg / Alt+K)."""
import hashlib
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))


def make_pkg_tar_gz(path, name="testpack", version="1.0.0", kind="lang"):
    manifest = (
        f"name = {name}\n"
        f"version = {version}\n"
        f"kind = {kind}\n"
        f"description = Test {name} package\n"
    ).encode("utf-8")
    lang_data = b"lang_id = zz\nlang_name = TestZZ\n"
    with tarfile.open(path, "w:gz") as tf:
        for fname, data in (("manifest.ini", manifest), ("zz.lang", lang_data)):
            ti = tarfile.TarInfo(fname)
            ti.size = len(data)
            ti.mode = 0o644
            tf.addfile(ti, io.BytesIO(data))
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def wait_for(sess, text, timeout=2.5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.05)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def test_pkg_cli_lifecycle():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        arc = os.path.join(tmp, "testpack.tar.gz")
        sha = make_pkg_tar_gz(arc)
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)

        res = subprocess.run([BINARY, "pkg", "install", arc, "--sha256", sha], env=env, capture_output=True, text=True)
        assert res.returncode == 0, f"install failed: {res.stdout} {res.stderr}"

        res = subprocess.run([BINARY, "pkg", "list"], env=env, capture_output=True, text=True)
        assert res.returncode == 0 and "testpack" in res.stdout and "1.0.0" in res.stdout, res.stdout

        res = subprocess.run([BINARY, "pkg", "verify", "testpack"], env=env, capture_output=True, text=True)
        assert res.returncode == 0 and "OK" in res.stdout, res.stdout

        res = subprocess.run([BINARY, "pkg", "remove", "testpack"], env=env, capture_output=True, text=True)
        assert res.returncode == 0, res.stderr

        res = subprocess.run([BINARY, "pkg", "list"], env=env, capture_output=True, text=True)
        assert "testpack" not in res.stdout, f"still listed after remove: {res.stdout}"
        print("[PASS] PK1. CLI pkg install/list/verify/remove lifecycle")


def test_pkg_bad_sha256_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        arc = os.path.join(tmp, "bad.tar.gz")
        make_pkg_tar_gz(arc, name="badpack")
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        bad_sha = "0" * 64
        res = subprocess.run([BINARY, "pkg", "install", arc, "--sha256", bad_sha], env=env, capture_output=True, text=True)
        assert res.returncode != 0, "Expected bad sha256 to be rejected"
        assert not os.path.exists(os.path.join(pkg_dir, "badpack")), "badpack should not exist on disk"
        print("[PASS] PK2. Bad SHA-256 rejected cleanly without partial install")


def test_pkg_tui_dialog_en_ua():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        l = os.path.join(tmp, "l")
        r = os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        arc = os.path.join(tmp, "testpack.tar.gz")
        make_pkg_tar_gz(arc)
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run([BINARY, "pkg", "install", arc], env=env, check=True, capture_output=True)

        old_env = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", l, r], cols=120, rows=35)
            try:
                sess.drain(0.25)
                sess.send(b"\x1bk", wait=0.2)
                wait_for(sess, "Package Manager")
                wait_for(sess, "testpack")
                sess.send(b"v", wait=0.2)
                wait_for(sess, "SHA-256 OK")
                sess.send(b"\x1b", wait=0.2)
                assert "Package Manager" not in sess.vt.full_text()
            finally:
                try:
                    os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
                except OSError:
                    pass

            sess_ua = PtySession(BINARY, ["--lang", "ua", l, r], cols=120, rows=35)
            try:
                sess_ua.drain(0.25)
                sess_ua.send(b"\x1bk", wait=0.2)
                wait_for(sess_ua, "Менеджер пакетів")
                wait_for(sess_ua, "testpack")
                print("[PASS] PK3. TUI Package Manager dialog (Alt+K) in EN & UA")
            finally:
                try:
                    os.kill(sess_ua.pid, 9); os.waitpid(sess_ua.pid, 0)
                except OSError:
                    pass
        finally:
            if old_env is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old_env


def test_pkg_sysmon_package():
    pkg_arc = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "dist", "duop-sysmon-1.0.0.tar.gz"))
    if not os.path.exists(pkg_arc):
        subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "..", "scripts", "build_sysmon_pkg.py")], check=True)
    with open(pkg_arc, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        res = subprocess.run([BINARY, "pkg", "install", pkg_arc, "--sha256", sha], env=env, capture_output=True, text=True)
        assert res.returncode == 0, f"sysmon install failed: {res.stdout} {res.stderr}"
        res = subprocess.run([BINARY, "pkg", "list"], env=env, capture_output=True, text=True)
        assert "duop-sysmon" in res.stdout and "tool" in res.stdout, res.stdout
        entry = os.path.join(pkg_dir, "duop-sysmon", "duop-sysmon")
        assert os.path.exists(entry), f"Missing extracted entry: {entry}"
        run = subprocess.run([sys.executable, entry, "--once"], capture_output=True, text=True)
        assert run.returncode == 0, run.stderr
        assert "\x1b[38;2;" in run.stdout and "╭" in run.stdout, "Missing TrueColor / rounded borders"
        for section in ("CPU", "RAM", "DISK"):
            assert section in run.stdout, f"Missing {section} section in sysmon output"
        print("[PASS] PK4. duop-sysmon package install, SHA-256 verify & TrueColor monitor render")


if __name__ == "__main__":
    test_pkg_cli_lifecycle()
    test_pkg_bad_sha256_rejected()
    test_pkg_tui_dialog_en_ua()
    test_pkg_sysmon_package()
    print("ALL PACKAGE MANAGER TESTS PASSED.")
