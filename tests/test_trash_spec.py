#!/usr/bin/env python3
"""XDG Trash + Undo correctness and safety (audit 2026-11-16).

TR1 .trashinfo is exactly "[Trash Info]\\nPath=...\\nDeletionDate=...\\n": no NUL byte, real UTC time
TR2 Path= is percent-encoded (spaces, %, UTF-8, newlines can never forge keys) and decodes back
TR3 Ctrl+Z never overwrites a newer file; the entry stays on the undo stack for a retry
TR4 trashing a FIFO / directory holding one across filesystems cannot block the UI
TR5 regular files and trees still trash and undo across filesystems
TR6 an exhausted unique-name range fails instead of overwriting an older trashed file
"""

import datetime
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")
KEY_DOWN = b"\x1b[B"
KEY_DEL = b"\x1b[3~"
KEY_CTRL_Z = b"\x1a"


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


def start(tmp: str, left: str, xdg: str, lang: str = "en") -> PtySession:
    right = os.path.join(tmp, "r")
    os.makedirs(right, exist_ok=True)
    sess = PtySession(BINARY, ["--lang", lang, left, right], extra_env={"XDG_DATA_HOME": xdg, "HOME": tmp})
    sess.drain(0.5)
    return sess


def trash_first_entry(sess: PtySession) -> None:
    sess.send(KEY_DOWN, wait=0.2)
    sess.send(KEY_DEL, wait=0.6)


def read_info(xdg: str) -> dict[str, bytes]:
    info = os.path.join(xdg, "Trash", "info")
    return {n: open(os.path.join(info, n), "rb").read() for n in sorted(os.listdir(info))}


def test_trashinfo_format_and_date() -> None:
    with tempfile.TemporaryDirectory(prefix="tr1_") as tmp:
        left, xdg = os.path.join(tmp, "l"), os.path.join(tmp, "xdg")
        os.makedirs(left)
        os.makedirs(xdg)
        with open(os.path.join(left, "alpha.txt"), "w") as f:
            f.write("data")
        sess = start(tmp, left, xdg)
        try:
            before = time.time()
            trash_first_entry(sess)
            after = time.time()
            infos = read_info(xdg)
            assert list(infos) == ["alpha.txt.trashinfo"], f"unexpected info files {list(infos)}"
            raw = infos["alpha.txt.trashinfo"]
            assert b"\0" not in raw, f"NUL byte in .trashinfo: {raw!r}"
            m = re.fullmatch(rb"\[Trash Info\]\nPath=(.+)\nDeletionDate=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\n", raw)
            assert m, f"malformed .trashinfo: {raw!r}"
            stamp = datetime.datetime.strptime(m.group(2).decode(), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
            assert before - 3 <= stamp.timestamp() <= after + 3, f"DeletionDate {stamp} is not the deletion time (UTC)"
            assert urllib.parse.unquote(m.group(1).decode()) == os.path.join(left, "alpha.txt")
        finally:
            kill(sess)
    print("[PASS] TR1. .trashinfo has the exact spec layout, no NUL byte and the real deletion time")


def test_trashinfo_path_is_percent_encoded() -> None:
    names = ["we ird%name é.txt", "x\nDeletionDate=1999-01-01T00:00:00.txt", "semi;quote'\".txt"]
    for name in names:
        with tempfile.TemporaryDirectory(prefix="tr2_") as tmp:
            left, xdg = os.path.join(tmp, "l"), os.path.join(tmp, "xdg")
            os.makedirs(left)
            os.makedirs(xdg)
            with open(os.path.join(left, name), "w") as f:
                f.write("data")
            sess = start(tmp, left, xdg)
            try:
                trash_first_entry(sess)
                infos = read_info(xdg)
                assert len(infos) == 1, f"{name!r}: expected one info file, got {list(infos)}"
                raw = next(iter(infos.values()))
                lines = raw.split(b"\n")
                assert lines[0] == b"[Trash Info]" and lines[-1] == b"" and len(lines) == 4, f"{name!r}: forged layout {raw!r}"
                assert lines[1].startswith(b"Path=") and lines[2].startswith(b"DeletionDate="), f"{name!r}: {raw!r}"
                enc = lines[1][5:].decode("ascii")
                assert re.fullmatch(r"[A-Za-z0-9._~/%-]+", enc), f"{name!r}: Path not percent-encoded: {enc!r}"
                assert urllib.parse.unquote(enc) == os.path.join(left, name), f"{name!r}: Path does not decode back"
            finally:
                kill(sess)
    print("[PASS] TR2. Path= is percent-encoded and decodes back to the original name")


def test_undo_never_clobbers() -> None:
    with tempfile.TemporaryDirectory(prefix="tr3_") as tmp:
        left, xdg = os.path.join(tmp, "l"), os.path.join(tmp, "xdg")
        os.makedirs(left)
        os.makedirs(xdg)
        path = os.path.join(left, "alpha.txt")
        with open(path, "w") as f:
            f.write("ORIGINAL-OLD")
        sess = start(tmp, left, xdg)
        try:
            trash_first_entry(sess)
            assert not os.path.exists(path)
            with open(path, "w") as f:
                f.write("NEW-IMPORTANT-DATA")
            sess.send(KEY_CTRL_Z, wait=0.6)
            assert open(path).read() == "NEW-IMPORTANT-DATA", "undo overwrote a newer file"
            assert "already exists" in sess.vt.full_text(), "undo conflict was not reported"
            assert os.path.exists(os.path.join(xdg, "Trash", "files", "alpha.txt")), "trashed file lost"
            os.unlink(path)
            sess.send(KEY_CTRL_Z, wait=0.6)
            assert open(path).read() == "ORIGINAL-OLD", "undo entry was lost after the refused attempt"
            assert not os.listdir(os.path.join(xdg, "Trash", "info")), "info file left behind after a successful undo"
        finally:
            kill(sess)
    print("[PASS] TR3. Undo refuses to overwrite a newer file and keeps the entry for a retry")


def other_filesystem() -> str | None:
    shm = "/dev/shm"
    if os.path.isdir(shm) and os.access(shm, os.W_OK) and os.stat(shm).st_dev != os.stat(tempfile.gettempdir()).st_dev:
        return shm
    return None


def test_fifo_across_filesystems_does_not_hang() -> None:
    shm = other_filesystem()
    if shm is None:
        print("[SKIP] TR4. /tmp and /dev/shm share a filesystem; cross-device cases not testable here")
        return
    for layout in ("fifo", "dir-with-fifo"):
        with tempfile.TemporaryDirectory(prefix="tr4_") as tmp:
            xdg = tempfile.mkdtemp(prefix="duop_xdg_", dir=shm)
            left = os.path.join(tmp, "l")
            os.makedirs(left)
            if layout == "fifo":
                os.mkfifo(os.path.join(left, "aaa_pipe"))
                target = os.path.join(left, "aaa_pipe")
            else:
                os.makedirs(os.path.join(left, "aaa_dir"))
                os.mkfifo(os.path.join(left, "aaa_dir", "pipe"))
                with open(os.path.join(left, "aaa_dir", "file.txt"), "w") as f:
                    f.write("x")
                target = os.path.join(left, "aaa_dir")
            sess = start(tmp, left, xdg)
            try:
                trash_first_entry(sess)
                t0 = time.monotonic()
                sess.resize(101, 30)
                sess.drain(1.0)
                assert "Name" in sess.vt.full_text() and time.monotonic() - t0 < 4, f"{layout}: UI frozen by the trash move"
                assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0, f"{layout}: process died"
                assert os.path.lexists(target), f"{layout}: source vanished although the move failed"
                assert "Special file" in sess.vt.full_text(), f"{layout}: no clear message: {sess.vt.row_text(33)!r}"
            finally:
                kill(sess)
                shutil.rmtree(xdg, ignore_errors=True)
    print("[PASS] TR4. Trashing a FIFO (or a tree holding one) across filesystems reports an error, never hangs")


def test_regular_trees_cross_filesystem_roundtrip() -> None:
    shm = other_filesystem()
    if shm is None:
        print("[SKIP] TR5. /tmp and /dev/shm share a filesystem; cross-device cases not testable here")
        return
    with tempfile.TemporaryDirectory(prefix="tr5_") as tmp:
        xdg = tempfile.mkdtemp(prefix="duop_xdg_", dir=shm)
        left = os.path.join(tmp, "l")
        os.makedirs(os.path.join(left, "aaa_tree", "sub"))
        with open(os.path.join(left, "aaa_tree", "sub", "deep.txt"), "w") as f:
            f.write("deep-data")
        sess = start(tmp, left, xdg)
        try:
            trash_first_entry(sess)
            assert not os.path.exists(os.path.join(left, "aaa_tree")), "tree not removed from the source"
            assert open(os.path.join(xdg, "Trash", "files", "aaa_tree", "sub", "deep.txt")).read() == "deep-data"
            sess.send(KEY_CTRL_Z, wait=0.8)
            assert open(os.path.join(left, "aaa_tree", "sub", "deep.txt")).read() == "deep-data", "undo across filesystems failed"
        finally:
            kill(sess)
            shutil.rmtree(xdg, ignore_errors=True)
    print("[PASS] TR5. Trees trash and undo correctly across filesystems")


def test_unique_name_exhaustion_keeps_old_trash() -> None:
    with tempfile.TemporaryDirectory(prefix="tr6_") as tmp:
        left, xdg = os.path.join(tmp, "l"), os.path.join(tmp, "xdg")
        files = os.path.join(xdg, "Trash", "files")
        os.makedirs(left)
        os.makedirs(files)
        os.makedirs(os.path.join(xdg, "Trash", "info"))
        names = ["a.txt"] + [f"a.txt.{i}" for i in range(2, 1200)]
        for n in names:
            with open(os.path.join(files, n), "w") as f:
                f.write("KEEP-" + n)
        with open(os.path.join(left, "a.txt"), "w") as f:
            f.write("fresh")
        sess = start(tmp, left, xdg)
        try:
            trash_first_entry(sess)
            assert os.path.exists(os.path.join(left, "a.txt")), "source removed although no free trash name existed"
            for n in names:
                assert open(os.path.join(files, n)).read() == "KEEP-" + n, f"older trashed file {n} was overwritten"
            assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0
        finally:
            kill(sess)
    print("[PASS] TR6. No free unique trash name -> clean failure, nothing overwritten")


def main() -> None:
    test_trashinfo_format_and_date()
    test_trashinfo_path_is_percent_encoded()
    test_undo_never_clobbers()
    test_fifo_across_filesystems_does_not_hang()
    test_regular_trees_cross_filesystem_roundtrip()
    test_unique_name_exhaustion_keeps_old_trash()
    print("ALL TRASH SPEC TESTS PASSED.")


if __name__ == "__main__":
    main()
