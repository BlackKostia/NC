#!/usr/bin/env python3
"""Phase-2: LRU directory cache + lexical chdir, mmap viewer for any file size (SIGBUS-safe),
rolling io_uring statx with batched symlink targets, and interleaved pane streaming."""

import os
import re
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO_ROOT, "duop")
STRACE = shutil.which("strace")
LINE_RE = re.compile(r"^(\d+)\s+([a-z_0-9]+)\(")

KEY_DOWN = b"\x1b[B"
KEY_ESC = b"\x1b"
KEY_ENTER = b"\r"
KEY_BS = b"\x7f"
KEY_F3 = b"\x1bOR"
KEY_END = b"\x1b[F"
KEY_HOME = b"\x1b[H"
KEY_PGDN = b"\x1b[6~"


def wait_for(sess, pred, desc, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.03)
        if pred():
            return
    raise AssertionError(f"Timeout waiting for {desc}\n--- SCREEN ---\n{sess.vt.full_text()}")


def wait_text(sess, needle, timeout=5.0):
    wait_for(sess, lambda: needle in sess.vt.full_text(), repr(needle), timeout)


def focus(sess, name):
    sess.send(b"/", wait=0.05)
    sess.send(name.encode() + b"\r", wait=0.08)
    sess.send(KEY_DOWN, wait=0.05)


def traced(trace, args, syscalls, **kw):
    return PtySession(STRACE, ["-f", "-qq", "-o", trace, "-e", f"trace={syscalls}", BINARY] + args, **kw)


def events(trace):
    out = []
    with open(trace, encoding="utf-8", errors="replace") as f:
        for ln in f:
            m = LINE_RE.match(ln)
            if m:
                out.append((int(m.group(1)), m.group(2), ln))
    return out


def test_dir_cache_and_lexical_chdir() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_nav_") as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        big = os.path.join(left, "big_dir")
        os.makedirs(big)
        os.makedirs(right)
        os.makedirs(os.path.join(left, "sub"))
        dfd = os.open(big, os.O_RDONLY)
        for i in range(20000):
            os.close(os.open(f"e_{i:05d}.txt", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd))
        os.close(dfd)
        with open(os.path.join(big, "e_00000.txt"), "wb") as f:
            f.write(b"x" * 10)
        os.symlink("sub", os.path.join(left, "link_sub"))
        locked = os.path.join(left, "zz_locked")
        os.makedirs(locked)
        os.chmod(locked, 0)

        trace = os.path.join(tmp, "nav.trace") if STRACE else None
        args = ["--lang", "en", left, right]
        sess = traced(trace, args, "getdents64,chdir,getcwd,openat") if STRACE else PtySession(BINARY, args)
        try:
            wait_text(sess, "big_dir")
            focus(sess, "big_dir")
            sess.send(KEY_ENTER, wait=0.2)
            wait_text(sess, "e_00000.txt")
            wait_text(sess, "10 B")
            sess.send(KEY_BS, wait=0.2)
            wait_text(sess, "link_sub")
            mark = sum(1 for _ in open(trace)) if trace else 0

            # File grows while away (directory mtime unchanged) -> visible size must refresh
            with open(os.path.join(big, "e_00000.txt"), "ab") as f:
                f.write(b"y" * 2038)
            focus(sess, "big_dir")
            sess.send(KEY_ENTER, wait=0.2)
            wait_text(sess, "e_00000.txt")
            wait_text(sess, "2.0 K")
            if trace:
                after = open(trace).read().splitlines()[mark:]
                gd = sum(1 for ln in after if "getdents64(" in ln and not ln.rstrip().endswith("= 0"))
                assert gd == 0, f"Returning to a cached directory re-read it ({gd} getdents64 batches)"
            print("[PASS] N1. LRU dir cache: instant return without getdents64; stale sizes re-stat lazily")

            # Directory mutated while away (mtime changes) -> cache invalidated, new entry shown
            sess.send(KEY_BS, wait=0.2)
            open(os.path.join(big, "new_arrival.txt"), "w").close()
            focus(sess, "big_dir")
            sess.send(KEY_ENTER, wait=0.2)
            sess.send(b"/", wait=0.05)
            sess.send(b"new_arrival\r", wait=0.2)
            wait_text(sess, "new_arrival.txt")
            sess.send(KEY_ESC, wait=0.1)
            sess.send(KEY_BS, wait=0.2)
            print("[PASS] N2. Directory mtime change invalidates the cached snapshot")

            # Lexical (logical) chdir through a symlink and back
            focus(sess, "link_sub")
            sess.send(KEY_ENTER, wait=0.2)
            wait_text(sess, os.path.join(left, "link_sub"))
            sess.send(KEY_BS, wait=0.2)
            wait_text(sess, "big_dir")
            assert os.path.join(left, "link_sub") not in sess.vt.row_text(1)
            print("[PASS] N3. Logical symlink navigation and return to the original parent")

            if os.geteuid() != 0:
                focus(sess, "zz_locked")
                sess.send(KEY_ENTER, wait=0.2)
                wait_text(sess, "Permission denied")
                assert "big_dir" in sess.vt.full_text() or "zz_locked" in sess.vt.full_text()
                print("[PASS] N4. Entering an unreadable directory fails cleanly and keeps the listing")

            sess.send(KEY_ESC, wait=0.05)
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
            if trace:
                ev = events(trace)
                cd = [ln for _, sc, ln in ev if sc in ("chdir", "getcwd")]
                assert not cd, f"Navigation still uses process-wide chdir/getcwd: {cd[:3]}"
                print("[PASS] N5. Navigation performs zero chdir/getcwd syscalls")
        finally:
            os.chmod(locked, 0o755)


def test_mmap_viewer() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_view_", dir="/var/tmp") as tmp:
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        path = os.path.join(left, "huge_log.txt")
        n = 400000
        with open(path, "w") as f:
            for i in range(1, n + 1):
                f.write(f"line {i:07d} payload-{i % 97:02d}\n")
        assert os.path.getsize(path) > 8 * 1024 * 1024
        trunc = os.path.join(left, "vanish.txt")
        with open(trunc, "w") as f:
            for i in range(200000):
                f.write(f"volatile {i:07d}\n")

        trace = os.path.join(tmp, "view.trace") if STRACE else None
        args = ["--lang", "en", left, right]
        sess = traced(trace, args, "mmap,read") if STRACE else PtySession(BINARY, args)
        try:
            wait_text(sess, "huge_log.txt")
            focus(sess, "huge_log")
            t0 = time.monotonic()
            sess.send(KEY_F3, wait=0.1)
            wait_text(sess, "line 0000001 payload-01")
            sess.send(KEY_END, wait=0.2)
            wait_text(sess, f"line {n:07d} payload-{n % 97:02d}")
            assert time.monotonic() - t0 < 3.0, "Viewer is not O(1) on a large file"
            wait_text(sess, str(n))                   # line numbers stay exact at the end
            sess.send(KEY_HOME, wait=0.1)
            wait_text(sess, "line 0000001 payload-01")
            sess.send(KEY_PGDN, wait=0.1)
            assert "line 0000001 payload" not in sess.vt.full_text()
            sess.send(b"h", wait=0.1)
            sess.send(KEY_END, wait=0.2)
            last_off = f"{(os.path.getsize(path) - 1) // 16 * 16:08x}"
            wait_text(sess, last_off)
            sess.send(KEY_ESC, wait=0.1)
            print("[PASS] V1. F3 on >8 MiB file: instant open, End/Home/PgDn exact (text + hex), no 1 MiB cap")

            # Truncation while mapped must not kill the process (SIGBUS guard)
            sess.send(KEY_ESC, wait=0.05)
            focus(sess, "vanish")
            sess.send(KEY_F3, wait=0.1)
            wait_text(sess, "volatile 0000000")
            os.truncate(trunc, 0)
            sess.send(KEY_END, wait=0.3)
            sess.send(KEY_HOME, wait=0.2)
            sess.send(KEY_ESC, wait=0.1)
            wait_for(sess, lambda: "File Viewer" not in sess.vt.full_text(), "viewer closed")
            print("[PASS] V2. File truncated while viewed: no SIGBUS crash, viewer stays usable")
            sess.send(KEY_ESC, wait=0.05)
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass
        if trace:
            ev = events(trace)
            file_maps = [ln for _, sc, ln in ev if sc == "mmap" and "PROT_READ, MAP_PRIVATE," in ln
                         and ", -1, 0)" not in ln]
            assert file_maps, "Viewer did not mmap the file"
            big_reads = [ln for _, sc, ln in ev if sc == "read" and re.search(r", 10485\d\d\) = ", ln)]
            assert not big_reads, "Viewer still reads the file eagerly into RAM"
            print("[PASS] V3. Viewer maps the file read-only instead of reading it into RAM")


def test_uring_symlinks_and_interleave() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_ur_") as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        dfd = os.open(left, os.O_RDONLY)
        for i in range(1200):
            fd = os.open(f"f_{i:04d}.bin", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd)
            os.write(fd, b"z" * (i * 3))
            os.close(fd)
        for i in range(300):
            os.makedirs(os.path.join(left, f"d_{i:03d}"))
            os.symlink(f"d_{i:03d}", f"ld_{i:03d}", dir_fd=dfd)
        os.close(dfd)

        trace = os.path.join(tmp, "ur.trace") if STRACE else None
        args = ["--lang", "en", left, right]
        sess = traced(trace, args, "newfstatat,statx,io_uring_enter") if STRACE else PtySession(BINARY, args)
        try:
            wait_text(sess, "d_000")
            mark = sum(1 for _ in open(trace)) if trace else 0
            # Size sort forces stats of all 1800 entries (300 symlinks must resolve to dirs)
            hdr = sess.vt.row_text(2)
            x = hdr.find("Size")
            sess.send_mouse(0, x + 1, 2, "M", wait=0.05)
            sess.send_mouse(0, x + 1, 2, "m", wait=0.3)
            wait_for(sess, lambda: "Size ▲" in sess.vt.row_text(2) or "Size ▼" in sess.vt.row_text(2), "size sort")
            wait_text(sess, "600 dirs, 1200 files")
            if trace:
                after = open(trace).read().splitlines()[mark:]
                sync = sum(1 for ln in after if ("newfstatat(" in ln or "statx(" in ln) and "ld_" in ln)
                assert sync < 30, f"Symlink targets still stat'ed one by one ({sync} syscalls)"
            print("[PASS] U1. Rolling io_uring statx + batched symlink targets (600 dirs incl. 300 dir-links)")
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass

        # Interleaved streaming: right pane must progress while the left pane is still loading
        l2, r2 = os.path.join(tmp, "L2"), os.path.join(tmp, "R2")
        for d in (l2, r2):
            os.makedirs(d)
            dfd = os.open(d, os.O_RDONLY)
            for i in range(30000):
                os.close(os.open(f"s_{i:05d}", os.O_CREAT | os.O_WRONLY, 0o644, dir_fd=dfd))
            os.close(dfd)
        if not STRACE:
            print("[SKIP] U2: strace unavailable (used to slow the event loop for observation)")
            return
        # strace on ppoll stretches every event-loop iteration so streaming spans many frames
        sess = PtySession(STRACE, ["-f", "-qq", "-o", "/dev/null", "-e", "trace=ppoll", BINARY,
                                   "--lang", "en", l2, r2], extra_env={"DUOP_STREAM_BATCH": "16"})
        try:
            both = False
            deadline = time.monotonic() + 10
            first_right = None
            import select as _select
            while time.monotonic() < deadline:
                # read without PtySession.drain's quiet-period extension (frames stream continuously)
                r, _, _ = _select.select([sess.master], [], [], 0.01)
                if r:
                    try:
                        sess.vt.feed(os.read(sess.master, 65536))
                    except OSError:
                        break
                txt = sess.vt.full_text()
                rows = [ln for ln in txt.split("\n") if "Loading:" in ln]
                for ln in rows:
                    halves = (ln[: len(ln) // 2], ln[len(ln) // 2:])
                    if "Loading:" in halves[0] and "Loading:" in halves[1]:
                        rc = int(re.search(r"Loading: (\d+)", halves[1]).group(1))
                        if first_right is None:
                            first_right = rc
                        elif rc > first_right:
                            both = True
                if both or ("30000 files" in txt and txt.count("30000 files") >= 2):
                    break
            assert both, "Right pane did not stream while the left pane was loading (no interleave)"
            print("[PASS] U2. Interleaved streaming: both panes fill concurrently")
            sess.send(b"q", wait=0.1)
            sess.wait_exit(timeout=5)
        finally:
            pass


def main() -> None:
    t0 = time.monotonic()
    test_dir_cache_and_lexical_chdir()
    test_mmap_viewer()
    test_uring_symlinks_and_interleave()
    print(f"ALL NAVIGATION/VIEWER/URING TESTS PASSED ({time.monotonic() - t0:.2f}s).")


if __name__ == "__main__":
    main()
