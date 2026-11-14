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


def make_pkg_archive(arc_path, manifest_text, files):
    with tarfile.open(arc_path, "w:gz") as tf:
        m_bytes = manifest_text.encode("utf-8")
        ti = tarfile.TarInfo("manifest.ini")
        ti.size = len(m_bytes)
        ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(m_bytes))
        for fname, content, mode in files:
            data = content.encode("utf-8") if isinstance(content, str) else content
            ti = tarfile.TarInfo(fname)
            ti.size = len(data)
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(data))
    import hashlib
    with open(arc_path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def test_popup_menu_scope_ext_and_marked_file():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(os.path.join(left, "adir"))
        os.makedirs(right)
        f1 = os.path.join(left, "alpha.txt")
        f2 = os.path.join(left, "beta.txt")
        open(f1, "w").write("1")
        open(f2, "w").write("2")

        out_log = os.path.join(tmp, "marked.log")
        arc = os.path.join(tmp, "extmark.tar.gz")
        make_pkg_archive(
            arc,
            (
                "name = extmark\nversion = 1.0.0\nkind = tool\n"
                "description = Marked file probe\nexec = mark.sh\n"
                "menu = Mark Probe\nargs = {marked_file}\n"
                "scope = file\next = .txt\nmode = tui\n"
            ),
            [("mark.sh", f"#!/bin/sh\ncat \"$1\" > '{out_log}'\n", 0o755)],
        )
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run([BINARY, "pkg", "install", arc], env=env, check=True, capture_output=True)

        old = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
            try:
                sess.drain(0.25)
                wait_for(sess, "alpha.txt")
                # Mark alpha.txt (row 4: '..' is row 2, 'adir' is row 3, 'alpha.txt' is row 4)
                sess.send(b"\x1b[B\x1b[B ", wait=0.1)
                sess.send(b" ", wait=0.1)  # mark beta.txt too
                # Right-click on adir (row 6 in 1-based terminal coords): Mark Probe must NOT appear
                sess.send(b"\x1b[<2;9;6M\x1b[<2;9;6m", wait=0.2)
                wait_for(sess, "Copy Path")
                assert "Mark Probe" not in sess.vt.full_text(), "ext=.txt leaked onto directory!"
                sess.send(b"\x1b", wait=0.15)

                # Right-click on alpha.txt (row 7 in 1-based terminal coords)
                sess.send(b"\x1b[<2;9;7M\x1b[<2;9;7m", wait=0.2)
                wait_for(sess, "Mark Probe")
                # Move down 5 items (past View, Copy, Move, Copy Path, Delete) to Mark Probe
                for _ in range(5):
                    sess.send(b"\x1b[B", wait=0.05)
                sess.send(b"\r", wait=0.25)

                lines = wait_file_lines(out_log, 2)
                assert f1 in lines and f2 in lines, f"Expected both marked paths, got {lines}"
            finally:
                try:
                    os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
                except OSError:
                    pass
        finally:
            if old is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old
    print("[PASS] PE2. PopupMenu filters by scope/ext and passes {marked_file}")


def test_external_previewer():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left); os.makedirs(right)
        cfile = os.path.join(left, "demo.custom")
        open(cfile, "w").write("raw_bytes")

        arc = os.path.join(tmp, "extprev.tar.gz")
        make_pkg_archive(
            arc,
            (
                "name = extprev\nversion = 1.0.0\nkind = tool\n"
                "description = Custom previewer\n"
                "preview_ext = .custom\npreview_exec = prev.sh\n"
            ),
            [("prev.sh", "#!/bin/sh\necho \"CUSTOM_PREVIEW_OK:$1\"\n", 0o755)],
        )
        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir)
        subprocess.run([BINARY, "pkg", "install", arc], env=env, check=True, capture_output=True)

        old = os.environ.get("DUOP_PKG_DIR")
        os.environ["DUOP_PKG_DIR"] = pkg_dir
        try:
            sess = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
            try:
                sess.drain(0.25)
                wait_for(sess, "demo.custom")
                sess.send(b"\x1b[B", wait=0.15)  # select demo.custom
                sess.send(b"\x1b[20~", wait=0.45)  # F9 toggle preview
                wait_for(sess, "CUSTOM_PREVIEW_OK:")
            finally:
                try:
                    os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
                except OSError:
                    pass
        finally:
            if old is None:
                os.environ.pop("DUOP_PKG_DIR", None)
            else:
                os.environ["DUOP_PKG_DIR"] = old
    print("[PASS] PE3. External package previewer renders in PreviewPane for matching ext")


def test_registry_and_vfs():
    with tempfile.TemporaryDirectory() as tmp:
        pkg_dir = os.path.join(tmp, "packages")
        arc1 = os.path.join(tmp, "regtool-1.0.0.tar.gz")
        sha1 = make_pkg_archive(
            arc1,
            "name = regtool\nversion = 1.0.0\nkind = tool\ndescription = Reg tool v1\nexec = run.sh\n",
            [("run.sh", "#!/bin/sh\necho v1\n", 0o755)],
        )
        arc2 = os.path.join(tmp, "regtool-1.1.0.tar.gz")
        sha2 = make_pkg_archive(
            arc2,
            "name = regtool\nversion = 1.1.0\nkind = tool\ndescription = Reg tool v2\nexec = run.sh\n",
            [("run.sh", "#!/bin/sh\necho v2\n", 0o755)],
        )
        reg_path = os.path.join(tmp, "registry.tsv")
        with open(reg_path, "w", encoding="utf-8") as f:
            f.write(f"regtool\t1.0.0\ttool\t{sha1}\t{arc1}\tReg tool v1\n")

        env = dict(os.environ, DUOP_PKG_DIR=pkg_dir, DUOP_PKG_REGISTRY=reg_path)
        subprocess.run([BINARY, "pkg", "update"], env=env, check=True, capture_output=True)
        srch = subprocess.run([BINARY, "pkg", "search", "reg"], env=env, check=True, capture_output=True, text=True)
        assert "regtool" in srch.stdout and "1.0.0" in srch.stdout

        subprocess.run([BINARY, "pkg", "install", "regtool"], env=env, check=True, capture_output=True)
        lst1 = subprocess.run([BINARY, "pkg", "list"], env=env, check=True, capture_output=True, text=True)
        assert "regtool" in lst1.stdout and "1.0.0" in lst1.stdout

        with open(reg_path, "w", encoding="utf-8") as f:
            f.write(f"regtool\t1.1.0\ttool\t{sha2}\t{arc2}\tReg tool v2\n")
        subprocess.run([BINARY, "pkg", "update"], env=env, check=True, capture_output=True)
        subprocess.run([BINARY, "pkg", "upgrade"], env=env, check=True, capture_output=True)
        lst2 = subprocess.run([BINARY, "pkg", "list"], env=env, check=True, capture_output=True, text=True)
        assert "1.1.0" in lst2.stdout

        # Test VFS package via `duop pkg vfs-list <uri>` or TUI Available tab
        vfs_arc = os.path.join(tmp, "mockvfs.tar.gz")
        make_pkg_archive(
            vfs_arc,
            "name = mockvfs\nversion = 1.0.0\nkind = vfs\ndescription = Mock VFS\nexec = vfs.sh\nvfs_scheme = mockvfs\n",
            [("vfs.sh", "#!/bin/sh\nprintf 'hello.txt\\t42\\t33188\\t1700000000\\n'\n", 0o755)],
        )
        subprocess.run([BINARY, "pkg", "install", vfs_arc], env=env, check=True, capture_output=True)
        vfs_out = subprocess.run([BINARY, "pkg", "vfs-list", "mockvfs://root"], env=env, check=True, capture_output=True, text=True)
        assert "hello.txt" in vfs_out.stdout
    print("[PASS] PE4. Registry update/search/install-by-name/upgrade & VFS provider")


def main():
    test_pkg_run_from_alt_k_and_user_menu()
    test_popup_menu_scope_ext_and_marked_file()
    test_external_previewer()
    test_registry_and_vfs()
    print("ALL PACKAGE EXTENSION TESTS PASSED.")


if __name__ == "__main__":
    main()
