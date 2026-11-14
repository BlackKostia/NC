#!/usr/bin/env python3
"""End-to-end PTY tests for Duop Package Extensions (Phase 1: exec, menu, args)."""
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


def wait_for(sess, substr, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        sess.drain(0.05)
        if substr in sess.vt.full_text():
            return
    raise AssertionError(
        f"Timed out waiting for {substr!r}. Screen:\n{sess.vt.full_text()}"
    )


def make_tool_pkg(arc_path, out_log, name="extprobe", menu_label="Ext Probe Tool"):
    manifest = (
        f"name = {name}\n"
        f"version = 1.0.0\n"
        f"kind = tool\n"
        f"description = Extension probe tool\n"
        f"exec = probe.sh\n"
        f"menu = {menu_label}\n"
        f"args = {{dir}} {{other_dir}} {{file}} {{path}}\n"
        f"mode = tui\n"
    ).encode("utf-8")
    script = (
        "#!/bin/sh\n"
        f"printf '%s|%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" \"$4\" >> '{out_log}'\n"
    ).encode("utf-8")
    with tarfile.open(arc_path, "w:gz") as tf:
        for fname, data, mode in (
            ("manifest.ini", manifest, 0o644),
            ("probe.sh", script, 0o755),
        ):
            ti = tarfile.TarInfo(fname)
            ti.size = len(data)
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(data))


def wait_file_lines(path, expected_count, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                lines = [ln.rstrip("\n") for ln in f.readlines() if ln.strip()]
            if len(lines) >= expected_count:
                return lines
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {expected_count} lines in {path}")


def test_pkg_run_from_alt_k_and_user_menu():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        sample_name = "hello world;id.txt"
        sample_path = os.path.join(left, sample_name)
        with open(sample_path, "w", encoding="utf-8") as f:
            f.write("data")

        log_path = os.path.join(tmp, "probe.log")
        arc_path = os.path.join(tmp, "extprobe.tar.gz")
        make_tool_pkg(arc_path, log_path)

        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run(
            [BINARY, "pkg", "install", arc_path],
            env=env,
            check=True,
            capture_output=True,
        )

        old_env = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
            try:
                sess.drain(0.25)
                wait_for(sess, sample_name)
                # Move cursor off '..' onto sample_name
                sess.send(b"\x1b[B", wait=0.1)

                # 1) Launch from Alt+K Package Manager using 'r'
                sess.send(b"\x1bk", wait=0.2)
                wait_for(sess, "Package Manager")
                wait_for(sess, "extprobe")
                sess.send(b"r", wait=0.25)

                lines = wait_file_lines(log_path, 1)
                parts = lines[0].split("|")
                assert parts == [left, right, sample_name, sample_path], (
                    f"Unexpected Alt+K run args: {parts}"
                )
                wait_for(sess, sample_name)

                # 2) Launch from Alt+U User Menu
                sess.send(b"\x1bu", wait=0.2)
                wait_for(sess, "Ext Probe Tool")
                # Move down past built-in duoprc items to 'Ext Probe Tool'
                for _ in range(10):
                    sess.send(b"\x1b[B", wait=0.04)
                sess.send(b"\r", wait=0.25)

                lines = wait_file_lines(log_path, 2)
                parts2 = lines[1].split("|")
                assert parts2 == [left, right, sample_name, sample_path], (
                    f"Unexpected UserMenu run args: {parts2}"
                )
            finally:
                try:
                    os.kill(sess.pid, 9)
                    os.waitpid(sess.pid, 0)
                except OSError:
                    pass
        finally:
            if old_env is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old_env

    print("[PASS] PE1. Tool package runs from Alt+K (r) & UserMenu (Alt+U) with safe argv expansion")


def main():
    test_pkg_run_from_alt_k_and_user_menu()
    print("ALL PACKAGE EXTENSION TESTS PASSED.")


if __name__ == "__main__":
    main()
