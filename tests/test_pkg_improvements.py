#!/usr/bin/env python3
"""TDD tests for Package Extension Improvements (P1-P5 + Menu/UX)."""
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


def wait_for(sess, substr, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        sess.drain(0.05)
        if substr in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {substr!r}.\n{sess.vt.full_text()}")


def make_tar(arc_path, entries):
    with tarfile.open(arc_path, "w:gz") as tf:
        for fname, data, mode in entries:
            raw = data.encode("utf-8") if isinstance(data, str) else data
            ti = tarfile.TarInfo(fname)
            ti.size = len(raw)
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(raw))
    with open(arc_path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def test_p2_semver_upgrade():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        a_12 = os.path.join(tmp, "sv-1.2.0.tar.gz")
        a_110 = os.path.join(tmp, "sv-1.10.0.tar.gz")
        a_10 = os.path.join(tmp, "sv-1.0.0.tar.gz")
        sha_12 = make_tar(a_12, [("manifest.ini", "name = svpkg\nversion = 1.2.0\nkind = tool\n", 0o644)])
        sha_110 = make_tar(a_110, [("manifest.ini", "name = svpkg\nversion = 1.10.0\nkind = tool\n", 0o644)])
        sha_10 = make_tar(a_10, [("manifest.ini", "name = svpkg\nversion = 1.0.0\nkind = tool\n", 0o644)])
        subprocess.run([BINARY, "pkg", "install", a_12], env=env, check=True)

        reg = os.path.join(tmp, "reg.tsv")
        # Registry has OLDER 1.0.0 -> must NOT downgrade
        with open(reg, "w", encoding="utf-8") as f:
            f.write(f"svpkg\t1.0.0\ttool\t{sha_10}\t{a_10}\tOlder\n")
        env["DUOP_PKG_REGISTRY"] = reg
        subprocess.run([BINARY, "pkg", "update"], env=env, check=True)
        subprocess.run([BINARY, "pkg", "upgrade"], env=env, check=True)
        out = subprocess.run([BINARY, "pkg", "list"], env=env, check=True, capture_output=True, text=True).stdout
        assert "1.2.0" in out, f"Unexpected downgrade: {out}"

        # Registry has NEWER 1.10.0 (> 1.2.0) -> MUST upgrade
        with open(reg, "w", encoding="utf-8") as f:
            f.write(f"svpkg\t1.10.0\ttool\t{sha_110}\t{a_110}\tNewer\n")
        subprocess.run([BINARY, "pkg", "update"], env=env, check=True)
        subprocess.run([BINARY, "pkg", "upgrade"], env=env, check=True)
        out = subprocess.run([BINARY, "pkg", "list"], env=env, check=True, capture_output=True, text=True).stdout
        assert "1.10.0" in out, f"Expected SemVer upgrade to 1.10.0, got: {out}"
    print("[PASS] P2. SemVer upgrade skips downgrades and upgrades 1.2.0 -> 1.10.0")


def test_p3_relative_subdirs_and_traversal_reject():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        arc = os.path.join(tmp, "subpkg.tar.gz")
        make_tar(arc, [
            ("manifest.ini", "name = subpkg\nversion = 1.0.0\nkind = tool\nexec = bin/run.sh\n", 0o644),
            ("bin/run.sh", "#!/bin/sh\necho ok\n", 0o755),
            ("lib/helper.py", "VAL = 42\n", 0o644),
        ])
        subprocess.run([BINARY, "pkg", "install", arc], env=env, check=True)
        assert os.path.isfile(os.path.join(pkg_dir, "subpkg", "bin", "run.sh"))
        assert os.path.isfile(os.path.join(pkg_dir, "subpkg", "lib", "helper.py"))

        evil_arc = os.path.join(tmp, "evil.tar.gz")
        make_tar(evil_arc, [
            ("manifest.ini", "name = evil\nversion = 1.0.0\nkind = tool\n", 0o644),
            ("../escape.txt", "bad", 0o644),
        ])
        subprocess.run([BINARY, "pkg", "install", evil_arc], env=env, check=False)
        assert not os.path.exists(os.path.join(pkg_dir, "escape.txt"))
        assert not os.path.exists(os.path.join(tmp, "escape.txt"))
    print("[PASS] P3. Relative subdirectories preserved and traversal rejected")


def test_palette_pkgdialog_bg_and_ansi_preview():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left); os.makedirs(right)
        sample = os.path.join(left, "demo.ansi")
        with open(sample, "w", encoding="utf-8") as f:
            f.write("raw")

        bg_log = os.path.join(tmp, "bg.log")
        arc_bg = os.path.join(tmp, "bgtool.tar.gz")
        make_tar(arc_bg, [
            ("manifest.ini", "name = bgtool\nversion = 1.0.0\nkind = tool\nexec = bg.sh\nmenu = Palette BG Tool\nargs = {file}\nmode = bg\n", 0o644),
            ("bg.sh", f"#!/bin/sh\necho \"BG:$1\" >> '{bg_log}'\n", 0o755),
        ])
        arc_pv = os.path.join(tmp, "ansipv.tar.gz")
        make_tar(arc_pv, [
            ("manifest.ini", "name = ansipv\nversion = 1.0.0\nkind = previewer\npreview_ext = .ansi\npreview_exec = pv.sh\n", 0o644),
            ("pv.sh", "#!/bin/sh\nprintf '\\033[32mGREEN_OK\\033[0m\\n'\n", 0o755),
        ])
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run([BINARY, "pkg", "install", arc_bg], env=env, check=True)
        subprocess.run([BINARY, "pkg", "install", arc_pv], env=env, check=True)

        old_env = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
            try:
                sess.drain(0.25)
                wait_for(sess, "demo.ansi")
                sess.send(b"\x1b[20~", wait=0.15)  # F9 enable preview
                sess.send(b"\x1b[B", wait=0.25)  # select demo.ansi
                # P5: Check ANSI SGR preview strips escape codes and shows GREEN_OK
                wait_for(sess, "GREEN_OK")
                assert "[32m" not in sess.vt.full_text(), f"Raw ANSI code leaked:\n{sess.vt.full_text()}"

                # Launch from Ctrl+K Command Palette + P4 mode=bg
                sess.send(b"\x0b", wait=0.2)  # Ctrl+K
                wait_for(sess, "Command Palette")
                sess.send(b"Palette BG", wait=0.15)
                wait_for(sess, "Palette BG Tool")
                sess.send(b"\r", wait=0.35)
                with open(bg_log, "r", encoding="utf-8") as f:
                    assert "BG:demo.ansi" in f.read()

                # Alt+K PkgDialog: tab header + Enter runs installed tool
                sess.send(b"\x1bk", wait=0.2)
                wait_for(sess, "Installed")
                wait_for(sess, "Available")
                sess.send(b"q", wait=0.1)
            finally:
                try:
                    os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
                except OSError:
                    pass
        finally:
            if old_env is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old_env
    print("[PASS] P4+P5+Menu. Command Palette launch, mode=bg, PkgDialog tabs & ANSI SGR preview")


def test_p1_interactive_vfs_in_filepane():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left); os.makedirs(right)
        vfs_script = (
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "cmd, uri = sys.argv[1], sys.argv[2]\n"
            "if cmd == 'LIST':\n"
            "    if uri.rstrip('/') == 'mockvfs:':\n"
            "        print('subdir\\t0\\t0\\td')\n"
            "        print('hello.txt\\t11\\t0\\tf')\n"
            "    else:\n"
            "        print('nested.txt\\t6\\t0\\tf')\n"
            "elif cmd == 'READ':\n"
            "    with open(sys.argv[3], 'w') as f:\n"
            "        f.write('hello world\\n')\n"
        )
        arc = os.path.join(tmp, "mockvfs.tar.gz")
        make_tar(arc, [
            ("manifest.ini", "name = mockvfs\nversion = 1.0.0\nkind = vfs\nvfs_scheme = mockvfs\nexec = vfs.py\n", 0o644),
            ("vfs.py", vfs_script, 0o755),
        ])
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run([BINARY, "pkg", "install", arc], env=env, check=True)

        old_env = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
            try:
                sess.drain(0.25)
                wait_for(sess, "..")
                sess.send(b"\x07", wait=0.2)  # Ctrl+G -> Goto
                wait_for(sess, "Go")
                sess.send(b"\x15mockvfs://", wait=0.15)  # Ctrl+U clears pre-filled path
                wait_for(sess, "mockvfs://")
                sess.send(b"\r", wait=0.4)
                wait_for(sess, "hello.txt")
                wait_for(sess, "subdir")
                # Enter subdir (first after ..)
                sess.send(b"\x1b[B", wait=0.1)
                sess.send(b"\r", wait=0.3)
                wait_for(sess, "nested.txt")
                # '..' returns to root, then '..' exits VFS
                sess.send(b"\r", wait=0.3)
                wait_for(sess, "hello.txt")
                # Move down to hello.txt and press F3 to view via READ
                sess.send(b"\x1b[B\x1b[B", wait=0.1)
                sess.send(b"\x1bOR", wait=0.3)  # F3
                wait_for(sess, "hello world")
                sess.send(b"q", wait=0.1)
            finally:
                try:
                    os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
                except OSError:
                    pass
        finally:
            if old_env is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old_env
    print("[PASS] P1. Interactive VFS navigation and F3 READ in FilePane")


if __name__ == "__main__":
    test_p2_semver_upgrade()
    test_p3_relative_subdirs_and_traversal_reject()
    test_palette_pkgdialog_bg_and_ansi_preview()
    test_p1_interactive_vfs_in_filepane()
    print("ALL PACKAGE IMPROVEMENT TESTS PASSED.")
