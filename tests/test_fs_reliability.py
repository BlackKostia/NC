#!/usr/bin/env python3
"""Extensive reliability, data-integrity, and fault-injection PTY tests for Duop FS ops."""

import hashlib
import os
import shutil
import stat
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")

KEY_DOWN = b"\x1b[B"
KEY_TAB = b"\t"
KEY_ESC = b"\x1b"
KEY_F2 = b"\x1bOQ"
KEY_F5 = b"\x1b[15~"
KEY_F6 = b"\x1b[17~"
KEY_F7 = b"\x1b[18~"
KEY_F8 = b"\x1b[19~"
KEY_CTRL_N = b"\x0e"
KEY_CTRL_R = b"\x12"
KEY_CTRL_U = b"\x15"
KEY_ALT_L = b"\x1bl"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def wait_for_text(sess: PtySession, needle: str, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        if needle in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {needle!r}; screen:\n{sess.vt.full_text()}")


def wait_for_any(sess: PtySession, needles: list[str], timeout: float = 3.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(wait=0.04)
        screen = sess.vt.full_text()
        for needle in needles:
            if needle in screen:
                return needle
    raise AssertionError(f"Timed out waiting for any of {needles!r}; screen:\n{sess.vt.full_text()}")


def wait_for_file(path: str, exists: bool = True, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.lexists(path) == exists:
            return
        time.sleep(0.03)
    raise AssertionError(f"Timed out expecting lexists({path}) == {exists}")


def focus_by_filter(sess: PtySession, name_substr: str, mark: bool = False) -> None:
    sess.send(b"/", wait=0.05)
    sess.send(name_substr.encode("utf-8") + b"\r", wait=0.06)
    sess.send(KEY_DOWN, wait=0.05)
    if mark:
        sess.send(b" ", wait=0.05)


def clear_filter(sess: PtySession) -> None:
    sess.send(KEY_ESC, wait=0.06)


def reset_status(sess: PtySession) -> None:
    sess.send(KEY_CTRL_R, wait=0.05)
    wait_for_any(sess, ["Refreshed", "Оновлено"])


def copy_focused(sess: PtySession, custom_dst: str | None = None, confirm: bool = True, expect_text: str | None = None) -> None:
    sess.send(KEY_F5, wait=0.06)
    wait_for_any(sess, ["Copy", "Копіювати"])
    if not confirm:
        sess.send(KEY_ESC, wait=0.06)
        return
    if custom_dst is not None:
        sess.send(KEY_CTRL_U + custom_dst.encode("utf-8"), wait=0.05)
    sess.send(b"\r", wait=0.08)
    if expect_text:
        wait_for_text(sess, expect_text)


def move_focused(sess: PtySession, custom_dst: str | None = None, confirm: bool = True, expect_text: str | None = None) -> None:
    sess.send(KEY_F6, wait=0.06)
    wait_for_any(sess, ["Move", "Перемістити"])
    if not confirm:
        sess.send(KEY_ESC, wait=0.06)
        return
    if custom_dst is not None:
        sess.send(KEY_CTRL_U + custom_dst.encode("utf-8"), wait=0.05)
    sess.send(b"\r", wait=0.08)
    if expect_text:
        wait_for_text(sess, expect_text)


def delete_focused(sess: PtySession, confirm: bool = True, expect_text: str | None = None) -> None:
    sess.send(KEY_F8, wait=0.06)
    wait_for_any(sess, ["Confirm Delete", "Підтвердження видалення"])
    if not confirm:
        sess.send(KEY_ESC, wait=0.06)
        return
    sess.send(b"\r", wait=0.08)
    if expect_text:
        wait_for_text(sess, expect_text)


def find_exdev_base(base_dev: int) -> str | None:
    uid = os.getuid()
    for cand in ("/dev/shm", f"/run/user/{uid}", "/var/tmp", "/tmp"):
        if os.path.isdir(cand) and os.access(cand, os.W_OK | os.X_OK):
            try:
                if os.stat(cand).st_dev != base_dev:
                    return cand
            except OSError:
                continue
    return None


def make_writable_recursive(path: str) -> None:
    if not os.path.lexists(path):
        return
    for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
        try:
            os.chmod(root, 0o755)
        except OSError:
            pass
        for d in dirs:
            p = os.path.join(root, d)
            if not os.path.islink(p):
                try:
                    os.chmod(p, 0o755)
                except OSError:
                    pass
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                try:
                    os.chmod(p, 0o644)
                except OSError:
                    pass
    if not os.path.islink(path):
        try:
            os.chmod(path, 0o755 if os.path.isdir(path) else 0o644)
        except OSError:
            pass


def run_happy_scale_and_edge_tests() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_rel_a_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        outside = os.path.join(tmp, "outside_protected")
        os.makedirs(left)
        os.makedirs(right)
        os.makedirs(outside)

        # 1. Large multi-chunk binary (160 KiB + odd tail bytes, executable 0755)
        big_src = os.path.join(left, "01_large_bin.dat")
        big_data = bytes((i * 131 + (i >> 8)) & 0xFF for i in range(160 * 1024 + 137))
        with open(big_src, "wb") as f:
            f.write(big_data)
        os.chmod(big_src, 0o755)
        big_hash = sha256_file(big_src)

        # 2. Zero-byte empty file
        empty_src = os.path.join(left, "02_empty.bin")
        with open(empty_src, "wb"):
            pass

        # 3. Read-only (0444) source file
        ro_src = os.path.join(left, "03_readonly.txt")
        ro_payload = b"immutable read-only payload\n" * 40
        with open(ro_src, "wb") as f:
            f.write(ro_payload)
        os.chmod(ro_src, 0o444)
        ro_hash = sha256_file(ro_src)

        # 4. Wide directory (>320 entries, long names -> forces multiple 8 KiB getdents64 batches)
        wide_dir = os.path.join(left, "04_wide_dir")
        os.makedirs(wide_dir)
        for i in range(340):
            fname = f"entry_{i:04d}_verylong_reliability_padding_segment.dat"
            with open(os.path.join(wide_dir, fname), "w", encoding="utf-8") as f:
                f.write(f"payload-{i}\n")

        # 5. Deep 10-level directory + dotfiles + empty dirs
        cur = os.path.join(left, "05_deep_tree")
        os.makedirs(cur)
        with open(os.path.join(cur, ".hidden_top"), "w", encoding="utf-8") as f:
            f.write("top-secret")
        for lvl in range(10):
            cur = os.path.join(cur, f"lvl_{lvl}")
            os.makedirs(cur)
            with open(os.path.join(cur, f".dot_{lvl}"), "w", encoding="utf-8") as f:
                f.write(f"secret-{lvl}")
        os.makedirs(os.path.join(cur, "empty_leaf_dir"))
        deep_leaf_file = os.path.join(cur, "leaf.txt")
        with open(deep_leaf_file, "w", encoding="utf-8") as f:
            f.write("deep-leaf-ok")

        # 6. Special filenames (spaces, quotes, leading dash, Cyrillic UTF-8)
        weird_name = "-weird 'single' \"double\" привіт файл.txt"
        weird_src = os.path.join(left, weird_name)
        weird_bytes = "Надійність файлових операцій №1!\n".encode("utf-8")
        with open(weird_src, "wb") as f:
            f.write(weird_bytes)
        weird_hash = sha256_file(weird_src)

        # 7. Symlinks: valid file symlink, dangling symlink, dir w/ symlink pointing OUTSIDE
        ln_file = os.path.join(left, "07_sym_valid")
        os.symlink("03_readonly.txt", ln_file)
        ln_dangling = os.path.join(left, "07_sym_dangling")
        os.symlink("/nonexistent/duop/dangling_target_999", ln_dangling)

        outside_guard = os.path.join(outside, "must_survive.txt")
        with open(outside_guard, "w", encoding="utf-8") as f:
            f.write("DO_NOT_DELETE_ME")
        sym_dir_holder = os.path.join(left, "08_sym_holder")
        os.makedirs(sym_dir_holder)
        with open(os.path.join(sym_dir_holder, "inside.txt"), "w", encoding="utf-8") as f:
            f.write("bye")
        os.symlink(outside, os.path.join(sym_dir_holder, "link_to_outside"))

        # 8. Batch transfer items (marked with Space)
        batch_a = os.path.join(left, "09_batch_a.txt")
        batch_b = os.path.join(left, "09_batch_b.txt")
        with open(batch_a, "wb") as f:
            f.write(b"batch-alpha")
        with open(batch_b, "wb") as f:
            f.write(b"batch-beta")

        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            sess.drain(0.25)

            # A1: Multi-chunk binary F5 Copy
            focus_by_filter(sess, "01_large_bin")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            big_dst = os.path.join(right, "01_large_bin.dat")
            assert os.path.isfile(big_dst) and sha256_file(big_dst) == big_hash, "Multi-chunk copy corrupted data"
            assert (os.stat(big_dst).st_mode & 0o100) != 0, "Multi-chunk copy lost executable bit"
            print("[PASS] R1. Multi-chunk 160 KiB copy byte/SHA-256 & mode preservation")

            # A2: Zero-byte file F5 Copy & F6 Move
            focus_by_filter(sess, "02_empty")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            empty_dst = os.path.join(right, "02_empty.bin")
            assert os.path.isfile(empty_dst) and os.path.getsize(empty_dst) == 0, "Empty file copy failed"
            print("[PASS] R2. Zero-byte empty file copy")

            # A3: Read-only (0444) source file copy
            focus_by_filter(sess, "03_readonly")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            ro_dst = os.path.join(right, "03_readonly.txt")
            assert os.path.isfile(ro_dst) and sha256_file(ro_dst) == ro_hash, "0444 read-only file copy failed"
            assert sha256_file(ro_src) == ro_hash, "0444 source modified during copy"
            print("[PASS] R3. Read-only (0444) source file copy preserves source & copies contents")

            # A4: Wide directory (>340 files across getdents64 batches) Copy & Delete
            focus_by_filter(sess, "04_wide_dir")
            copy_focused(sess, expect_text="Copied successfully")
            wide_dst = os.path.join(right, "04_wide_dir")
            assert len(os.listdir(wide_dst)) == 340, f"Expected 340 copied files, got {len(os.listdir(wide_dst))}"
            assert open(os.path.join(wide_dst, "entry_0339_verylong_reliability_padding_segment.dat")).read() == "payload-339\n"
            delete_focused(sess, expect_text="Deleted successfully")
            clear_filter(sess)
            assert not os.path.exists(wide_dir), "Wide dir delete left directory behind"
            print("[PASS] R4. Multi-batch getdents64 (340 files) recursive Copy & Delete")

            # A5: Deep tree + hidden dotfiles + empty subdir Copy & Delete
            focus_by_filter(sess, "05_deep_tree")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            copied_leaf = os.path.join(
                right, "05_deep_tree", *(f"lvl_{i}" for i in range(10)), "leaf.txt"
            )
            copied_empty = os.path.join(
                right, "05_deep_tree", *(f"lvl_{i}" for i in range(10)), "empty_leaf_dir"
            )
            copied_dot = os.path.join(right, "05_deep_tree", ".hidden_top")
            assert os.path.isfile(copied_leaf) and open(copied_leaf).read() == "deep-leaf-ok"
            assert os.path.isdir(copied_empty), "Empty leaf subdir lost during recursive copy"
            assert os.path.isfile(copied_dot), "Hidden dotfile lost during recursive copy"
            print("[PASS] R5. 10-level deep tree + dotfiles + empty leaf recursive copy")

            # A6: Special filenames (spaces, quotes, leading dash, Cyrillic) Copy & Move
            focus_by_filter(sess, "привіт файл")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            weird_dst = os.path.join(right, weird_name)
            assert os.path.isfile(weird_dst) and sha256_file(weird_dst) == weird_hash, "Special filename copy mismatch"
            print("[PASS] R6. Special chars / quotes / leading dash / Cyrillic filename copy")

            # A7: Symlink preservation (valid & dangling) + NO-FOLLOW delete safety
            focus_by_filter(sess, "07_sym_valid")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            sym_v_dst = os.path.join(right, "07_sym_valid")
            assert os.path.islink(sym_v_dst) and os.readlink(sym_v_dst) == "03_readonly.txt", "Valid symlink dereferenced or broken"

            focus_by_filter(sess, "07_sym_dangling")
            copy_focused(sess, expect_text="Copied successfully")
            clear_filter(sess)
            sym_d_dst = os.path.join(right, "07_sym_dangling")
            assert os.path.islink(sym_d_dst) and os.readlink(sym_d_dst) == "/nonexistent/duop/dangling_target_999"

            focus_by_filter(sess, "08_sym_holder")
            delete_focused(sess, expect_text="Deleted successfully")
            clear_filter(sess)
            assert not os.path.lexists(sym_dir_holder), "Holder dir was not deleted"
            assert os.path.isfile(outside_guard) and open(outside_guard).read() == "DO_NOT_DELETE_ME", \
                "CRITICAL: Recursive delete followed symlink outside target tree!"
            print("[PASS] R7. Symlink preservation (valid & dangling) & AT_SYMLINK_NOFOLLOW delete safety")

            # A8: Heterogeneous batch mark Copy -> Move -> Delete
            focus_by_filter(sess, "09_batch_")
            sess.send(b" ", wait=0.05)  # mark first batch entry
            sess.send(KEY_DOWN + b" ", wait=0.05)  # mark second batch entry
            wait_for_text(sess, "2 selected")
            copy_focused(sess, expect_text="Copied successfully")
            assert os.path.isfile(os.path.join(right, "09_batch_a.txt"))
            assert os.path.isfile(os.path.join(right, "09_batch_b.txt"))
            assert os.path.isfile(batch_a) and os.path.isfile(batch_b), "Copy batch removed sources"

            # Still filtered to 09_batch_, mark both and Move into custom subfolder
            batch_sub = os.path.join(right, "batch_moved_dst")
            os.makedirs(batch_sub)
            sess.send(b"*", wait=0.05)
            wait_for_text(sess, "2 selected")
            move_focused(sess, custom_dst=batch_sub, expect_text="Moved successfully")
            clear_filter(sess)
            assert not os.path.exists(batch_a) and not os.path.exists(batch_b), "Move batch left sources"
            assert open(os.path.join(batch_sub, "09_batch_a.txt"), "rb").read() == b"batch-alpha"
            assert open(os.path.join(batch_sub, "09_batch_b.txt"), "rb").read() == b"batch-beta"
            print("[PASS] R8. Batch Copy & Batch Move preserve payload and source semantics")

            sess.send(b"q", wait=0.05)
            rc = sess.wait_exit(timeout=2.0)
            assert rc == 0, f"Unexpected exit code {rc}"
        finally:
            make_writable_recursive(tmp)


def run_adversarial_failure_tests() -> None:
    if os.geteuid() == 0:
        print("[SKIP] Running as root bypasses POSIX 0555 EACCES tests")
        return

    with tempfile.TemporaryDirectory(prefix="duop_rel_f_") as tmp:
        left = os.path.join(tmp, "left")
        right = os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)

        # Fixture files
        precious = os.path.join(left, "01_precious.txt")
        precious_bytes = b"IMPORTANT_UNCORRUPTED_USER_DATA_" * 200
        with open(precious, "wb") as f:
            f.write(precious_bytes)
        precious_hash = sha256_file(precious)

        # Loop self-copy directory fixture
        loop_dir = os.path.join(left, "02_loop_dir")
        os.makedirs(os.path.join(loop_dir, "inner_child"))
        with open(os.path.join(loop_dir, "anchor.txt"), "wb") as f:
            f.write(b"anchor-keep")

        # Read-only locked dest directory
        locked_dst = os.path.join(tmp, "locked_dst")
        os.makedirs(locked_dst)
        os.chmod(locked_dst, 0o555)

        # Locked parent subdir inside left containing undeletable file
        locked_sub = os.path.join(left, "03_locked_sub")
        os.makedirs(locked_sub)
        locked_inner = os.path.join(locked_sub, "protected.txt")
        with open(locked_inner, "wb") as f:
            f.write(b"locked-secret")
        os.chmod(locked_sub, 0o555)

        # Partial batch delete fixture: deleteme runs BEFORE 03_locked_sub (alphabetical)
        # Wait: files sort before dirs or dirs sort before files! "01_precious.txt" vs dirs:
        # Prepare two dirs so they stay in same section: "02a_deleteme_dir" and "03_locked_sub"
        del_dir = os.path.join(left, "02a_deleteme_dir")
        os.makedirs(del_dir)
        with open(os.path.join(del_dir, "temp.txt"), "w", encoding="utf-8") as f:
            f.write("temp")

        # Existing regular file target for ENOTDIR
        reg_target = os.path.join(right, "regular_not_a_dir.txt")
        with open(reg_target, "wb") as f:
            f.write(b"existing-right-data")
        reg_hash = sha256_file(reg_target)

        # Existing directory for EEXIST / EISDIR tests
        existing_dir = os.path.join(left, "04_existing_dir")
        os.makedirs(existing_dir)
        with open(os.path.join(existing_dir, "child.txt"), "w", encoding="utf-8") as f:
            f.write("inside-dir")

        # Race/TOCTOU vanish file
        vanish_file = os.path.join(left, "05_vanish.txt")
        with open(vanish_file, "wb") as f:
            f.write(b"soon-gone")

        # Rename fixture
        ren_src = os.path.join(left, "06_ren_src.txt")
        with open(ren_src, "wb") as f:
            f.write(b"rename-intact")

        sess = PtySession(BINARY, ["--lang", "en", left, right])
        try:
            sess.drain(0.25)

            # F1: Dialog Cancellation Safety (F5, F6, F8, F2, F7 Esc -> 0 changes)
            focus_by_filter(sess, "01_precious")
            copy_focused(sess, confirm=False)
            move_focused(sess, confirm=False)
            delete_focused(sess, confirm=False)
            sess.send(KEY_F2, wait=0.05)
            wait_for_text(sess, "Rename")
            sess.send(KEY_ESC, wait=0.05)
            sess.send(KEY_F7, wait=0.05)
            wait_for_text(sess, "Create Directory")
            sess.send(b"should_not_exist" + KEY_ESC, wait=0.05)
            clear_filter(sess)
            assert os.path.isfile(precious) and sha256_file(precious) == precious_hash
            assert not os.path.exists(os.path.join(right, "01_precious.txt"))
            assert not os.path.exists(os.path.join(left, "should_not_exist"))
            print("[PASS] F1. Cancel (Esc) on Copy/Move/Delete/Rename/Mkdir leaves disk untouched")

            # F2: Reject operations on '..' (FE_IS_PARENT)
            sess.send(b"\x1b[H", wait=0.05)  # Home -> cursor on '..'
            sess.send(KEY_F5, wait=0.06)
            wait_for_text(sess, "Cannot operate on '..'")
            sess.send(KEY_F6, wait=0.06)
            wait_for_text(sess, "Cannot operate on '..'")
            sess.send(KEY_F2, wait=0.06)
            wait_for_text(sess, "Cannot operate on '..'")
            sess.send(KEY_F8, wait=0.06)
            assert "Confirm Delete" not in sess.vt.full_text(), "F8 opened Confirm Delete on '..'"
            print("[PASS] F2. Safe rejection of F2/F5/F6/F8 on '..' parent entry")

            # F3: Copy onto self -> err_same & ZERO truncation of existing content!
            focus_by_filter(sess, "01_precious")
            copy_focused(sess, custom_dst=precious, expect_text="Source and destination are the same")
            clear_filter(sess)
            assert os.path.isfile(precious) and sha256_file(precious) == precious_hash, \
                "CRITICAL: Self-copy truncated/corrupted source file!"
            print("[PASS] F3. Copy onto same file/inode rejected without O_TRUNC data loss")

            # F4: Copy directory into its own descendant (loop_dir -> loop_dir/inner_child & loop_dir/new_sub)
            reset_status(sess)
            focus_by_filter(sess, "02_loop_dir")
            copy_focused(
                sess,
                custom_dst=os.path.join(loop_dir, "new_sub"),
                expect_text="Source and destination are the same",
            )
            assert not os.path.exists(os.path.join(loop_dir, "new_sub")), \
                "CRITICAL: Self-descendant copy created recursive directory tree on disk!"
            # Also test existing subdirectory target where exec_batch_transfer joins loop_dir basename!
            reset_status(sess)
            copy_focused(
                sess,
                custom_dst=os.path.join(loop_dir, "inner_child"),
                expect_text="Source and destination are the same",
            )
            clear_filter(sess)
            assert not os.path.exists(os.path.join(loop_dir, "inner_child", "02_loop_dir")), \
                "CRITICAL: Copy into existing child subdir triggered self-copy tree!"
            assert open(os.path.join(loop_dir, "anchor.txt"), "rb").read() == b"anchor-keep"
            print("[PASS] F4. Copy directory into own descendant safely blocked (no infinite recursion)")

            # F5: Copy & Move to read-only (0555) directory -> Permission denied + source untouched!
            reset_status(sess)
            focus_by_filter(sess, "01_precious")
            copy_focused(sess, custom_dst=os.path.join(locked_dst, "c.txt"), expect_text="Permission denied")
            assert not os.path.exists(os.path.join(locked_dst, "c.txt"))
            assert sha256_file(precious) == precious_hash

            reset_status(sess)
            move_focused(sess, custom_dst=os.path.join(locked_dst, "m.txt"), expect_text="Permission denied")
            clear_filter(sess)
            assert os.path.isfile(precious) and sha256_file(precious) == precious_hash, \
                "CRITICAL: Failed Move deleted or corrupted source file!"
            assert not os.path.exists(os.path.join(locked_dst, "m.txt"))
            print("[PASS] F5. EACCES on Copy/Move preserves source file 100% intact")

            # F6: Copy & Move to nonexistent parent (ENOENT) and multi-move into regular file (ENOTDIR)
            reset_status(sess)
            focus_by_filter(sess, "01_precious")
            copy_focused(
                sess,
                custom_dst=os.path.join(right, "missing_parent", "sub", "x.txt"),
                expect_text="File or directory not found",
            )
            reset_status(sess)
            move_focused(
                sess,
                custom_dst=os.path.join(right, "missing_parent", "sub", "x.txt"),
                expect_text="File or directory not found",
            )
            assert os.path.isfile(precious) and sha256_file(precious) == precious_hash

            # Batch move onto an existing regular file -> ENOTDIR, source & existing file untouched!
            sess.send(b" ", wait=0.05)
            move_focused(sess, custom_dst=reg_target, expect_text="Not a directory")
            sess.send(b" ", wait=0.05)  # unmark
            clear_filter(sess)
            assert os.path.isfile(precious) and sha256_file(precious) == precious_hash
            assert sha256_file(reg_target) == reg_hash
            print("[PASS] F6. ENOENT & ENOTDIR on Copy/Move leave both source and regular target intact")

            # F7: Partial Batch Delete failure reloads pane honestly & protects locked item
            reset_status(sess)
            dx1, dy1 = sess.vt.find_text("02a_deleteme_dir")
            sess.send_mouse(0, dx1, dy1, "M", wait=0.05); sess.send_mouse(0, dx1, dy1, "m", wait=0.05)
            sess.send(b" ", wait=0.05)
            dx2, dy2 = sess.vt.find_text("03_locked_sub")
            sess.send_mouse(0, dx2, dy2, "M", wait=0.05); sess.send_mouse(0, dx2, dy2, "m", wait=0.05)
            sess.send(b" ", wait=0.05)
            wait_for_text(sess, "2 selected")
            delete_focused(sess, expect_text="Permission denied")
            assert not os.path.exists(del_dir), "Valid item before failing item was expected deleted"
            assert os.path.exists(locked_inner), "Locked protected file should still exist"
            assert "02a_deleteme_dir" not in sess.vt.full_text(), \
                "Stale phantom entry '02a_deleteme_dir' stayed visible in panel after partial delete failure!"
            assert "selected" not in sess.vt.full_text(), \
                "Stale selection counter remained after partial delete reload!"
            print("[PASS] F7. Partial batch Delete shows error, protects EACCES subtree & refreshes pane")

            # F8: TOCTOU race — file disappears between opening dialog and pressing Enter
            focus_by_filter(sess, "05_vanish")
            sess.send(KEY_F5, wait=0.06)
            wait_for_text(sess, "Copy")
            os.unlink(vanish_file)
            sess.send(b"\r", wait=0.08)
            wait_for_text(sess, "File or directory not found")
            clear_filter(sess)
            assert not os.path.exists(os.path.join(right, "05_vanish.txt"))
            sess.send(KEY_CTRL_R, wait=0.06)
            print("[PASS] F8. Vanished source during open dialog handled cleanly without crash")

            # F9: Mkdir EEXIST, NewFile EEXIST (must NOT clobber existing file or dir!), Rename EACCES
            reset_status(sess)
            sess.send(KEY_F7, wait=0.05)
            wait_for_text(sess, "Create Directory")
            sess.send(b"04_existing_dir\r", wait=0.08)
            wait_for_text(sess, "Destination already exists")

            reset_status(sess)
            sess.send(KEY_CTRL_N, wait=0.05)
            wait_for_text(sess, "Create New File")
            sess.send(b"04_existing_dir\r", wait=0.08)
            wait_for_text(sess, "Destination already exists")
            assert os.path.isdir(existing_dir) and os.path.isfile(os.path.join(existing_dir, "child.txt"))

            reset_status(sess)
            sess.send(KEY_CTRL_N, wait=0.05)
            wait_for_text(sess, "Create New File")
            sess.send(b"01_precious.txt\r", wait=0.08)
            wait_for_text(sess, "Destination already exists")
            assert sha256_file(precious) == precious_hash, \
                "CRITICAL: Ctrl+N New File truncated existing file!"

            reset_status(sess)
            focus_by_filter(sess, "06_ren_src")
            sess.send(KEY_F2, wait=0.05)
            wait_for_text(sess, "Rename")
            sess.send(KEY_CTRL_U + os.path.join(locked_dst, "nope.txt").encode("utf-8") + b"\r", wait=0.08)
            wait_for_text(sess, "Permission denied")
            clear_filter(sess)
            assert os.path.isfile(ren_src) and open(ren_src, "rb").read() == b"rename-intact"
            print("[PASS] F9. Mkdir/NewFile EEXIST non-clobber & Rename EACCES safe rejections")

            # F10: Switch live to Ukrainian (Alt+L) and check localized error parity
            sess.send(KEY_ALT_L, wait=0.06)
            sess.send(b"\x1b[H", wait=0.05)  # Home -> '..'
            sess.send(KEY_F5, wait=0.06)
            wait_for_text(sess, "Неможливо виконати над '..'")
            focus_by_filter(sess, "01_precious")
            copy_focused(sess, custom_dst=precious, expect_text="Джерело і призначення збігаються")
            copy_focused(sess, custom_dst=os.path.join(locked_dst, "ua.txt"), expect_text="Доступ заборонено")
            clear_filter(sess)
            print("[PASS] F10. Ukrainian error banners parity (.., ErrSame, Permission denied)")

            sess.send(b"q", wait=0.05)
            rc = sess.wait_exit(timeout=2.0)
            assert rc == 0, f"Unexpected exit code {rc}"
        finally:
            make_writable_recursive(tmp)


def run_cross_device_exdev_tests() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_exdev_src_") as src_tmp:
        exdev_parent = find_exdev_base(os.stat(src_tmp).st_dev)
        if not exdev_parent:
            print("[SKIP] No distinct writable mount found for live -EXDEV cross-filesystem test")
            return

        with tempfile.TemporaryDirectory(prefix="duop_exdev_dst_", dir=exdev_parent) as dst_tmp:
            assert os.stat(src_tmp).st_dev != os.stat(dst_tmp).st_dev
            left = os.path.join(src_tmp, "left")
            right = os.path.join(dst_tmp, "right")
            locked_mount_dst = os.path.join(dst_tmp, "locked_right")
            os.makedirs(left)
            os.makedirs(right)
            os.makedirs(locked_mount_dst)

            # Payload on source FS
            tree_src = os.path.join(left, "01_xdev_tree")
            os.makedirs(os.path.join(tree_src, "nested"))
            big_xdev = os.path.join(tree_src, "nested", "128k.bin")
            with open(big_xdev, "wb") as f:
                f.write(bytes((i * 73) & 0xFF for i in range(128 * 1024 + 19)))
            xdev_hash = sha256_file(big_xdev)

            ro_xdev = os.path.join(tree_src, "ro.txt")
            with open(ro_xdev, "wb") as f:
                f.write(b"xdev-ro")
            os.chmod(ro_xdev, 0o444)

            sym_xdev = os.path.join(tree_src, "sym_in_tree")
            os.symlink("ro.txt", sym_xdev)

            # File to test -EXDEV fallback FAILURE preservation
            keep_src = os.path.join(left, "02_must_survive_exdev_err.txt")
            keep_payload = b"SURVIVES_CROSS_FS_COPY_FAILURE_" * 100
            with open(keep_src, "wb") as f:
                f.write(keep_payload)
            keep_hash = sha256_file(keep_src)

            if os.geteuid() != 0:
                os.chmod(locked_mount_dst, 0o555)

            sess = PtySession(BINARY, ["--lang", "en", left, right])
            try:
                sess.drain(0.25)

                # X1: Successful cross-FS Move (triggers EXDEV -> copy + delete fallback)
                focus_by_filter(sess, "01_xdev_tree")
                move_focused(sess, expect_text="Moved successfully")
                clear_filter(sess)
                assert not os.path.exists(tree_src), "Cross-FS Move left source behind"
                dst_tree = os.path.join(right, "01_xdev_tree")
                assert sha256_file(os.path.join(dst_tree, "nested", "128k.bin")) == xdev_hash
                assert open(os.path.join(dst_tree, "ro.txt"), "rb").read() == b"xdev-ro"
                assert os.path.islink(os.path.join(dst_tree, "sym_in_tree"))
                assert os.readlink(os.path.join(dst_tree, "sym_in_tree")) == "ro.txt"
                print("[PASS] X1. Live -EXDEV cross-FS recursive Move (128 KiB + 0444 + symlink)")

                # X2: Cross-FS Move failure to read-only target mount -> source stays 100% intact!
                if os.geteuid() != 0:
                    focus_by_filter(sess, "02_must_survive_exdev_err")
                    move_focused(
                        sess,
                        custom_dst=os.path.join(locked_mount_dst, "fail.txt"),
                        expect_text="Permission denied",
                    )
                    clear_filter(sess)
                    assert os.path.isfile(keep_src) and sha256_file(keep_src) == keep_hash, \
                        "CRITICAL: Source deleted after cross-FS fallback copy failure!"
                    assert not os.path.exists(os.path.join(locked_mount_dst, "fail.txt"))
                    print("[PASS] X2. Live -EXDEV cross-FS Move EACCES failure preserves source 100%")

                sess.send(b"q", wait=0.05)
                rc = sess.wait_exit(timeout=2.0)
                assert rc == 0, f"Unexpected exit code {rc}"
            finally:
                make_writable_recursive(src_tmp)
                make_writable_recursive(dst_tmp)


def main() -> None:
    if not os.path.isfile(BINARY):
        raise SystemExit(f"Binary not found: {BINARY}")
    t0 = time.monotonic()
    run_happy_scale_and_edge_tests()
    run_adversarial_failure_tests()
    run_cross_device_exdev_tests()
    dt = time.monotonic() - t0
    print(f"ALL FS RELIABILITY TESTS PASSED ({dt:.2f}s).")


if __name__ == "__main__":
    main()
