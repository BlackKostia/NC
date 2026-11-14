#!/usr/bin/env python3
"""Phase-1 fast paths: slab allocator, zero-copy/fd-relative file ops, SIMD strings, prefix-key
name sort and incremental filter narrowing. Syscall budgets are verified with strace."""

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

KEY_DOWN = b"\x1b[B"
KEY_ESC = b"\x1b"
KEY_F5 = b"\x1b[15~"
KEY_F8 = b"\x1b[19~"
KEY_PGDN = b"\x1b[6~"
KEY_HOME = b"\x1b[H"

LINE_RE = re.compile(r"^(\d+)\s+([a-z_0-9]+)\(")


def wait_for(sess: PtySession, pred, desc: str, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sess.drain(0.03)
        if pred():
            return
    raise AssertionError(f"Timeout waiting for {desc}\n--- SCREEN ---\n{sess.vt.full_text()}")


def wait_text(sess: PtySession, needle: str, timeout: float = 5.0) -> None:
    wait_for(sess, lambda: needle in sess.vt.full_text(), repr(needle), timeout)


def focus_by_filter(sess: PtySession, name: str) -> None:
    sess.send(b"/", wait=0.05)
    sess.send(name.encode() + b"\r", wait=0.08)
    sess.send(KEY_DOWN, wait=0.05)


def traced_session(trace: str, args: list[str], syscalls: str, **kw) -> PtySession:
    return PtySession(STRACE, ["-f", "-qq", "-o", trace, "-e", f"trace={syscalls}", BINARY] + args, **kw)


def parse_trace(trace: str) -> list[tuple[int, str, str]]:
    out = []
    with open(trace, encoding="utf-8", errors="replace") as f:
        for ln in f:
            m = LINE_RE.match(ln)
            if m:
                out.append((int(m.group(1)), m.group(2), ln))
    return out


def build_tree(root: str, n_files: int) -> dict[str, bytes]:
    payload = {}
    for d in range(5):
        sub = os.path.join(root, f"d{d}", "inner")
        os.makedirs(sub)
        for i in range(n_files // 5):
            rel = os.path.join(f"d{d}", "inner", f"f_{i:04d}.txt")
            data = f"payload {d}/{i} ".encode() * (1 + i % 7)
            with open(os.path.join(root, rel), "wb") as f:
                f.write(data)
            payload[rel] = data
    big = bytes((i * 37 + 11) & 0xFF for i in range(1 << 20)) * 8 + b"tail"
    with open(os.path.join(root, "big.bin"), "wb") as f:
        f.write(big)
    payload["big.bin"] = big
    os.symlink("big.bin", os.path.join(root, "link_big"))
    os.symlink("/nonexistent/dangling", os.path.join(root, "d0", "dangling"))
    return payload


def test_copy_delete_syscall_budget() -> None:
    if not STRACE:
        print("[SKIP] FP1/FP2: strace unavailable")
        return
    base_dir = "/var/tmp" if os.access("/var/tmp", os.W_OK) else None
    with tempfile.TemporaryDirectory(prefix="duop_fp_", dir=base_dir) as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(right)
        src = os.path.join(left, "tree")
        os.makedirs(src)
        payload = build_tree(src, 1500)

        # FP1: copy -> slab buffers (no mmap per file), copy_file_range for data, exact content
        trace = os.path.join(tmp, "copy.trace")
        sess = traced_session(trace, ["--lang", "en", left, right],
                              "mmap,munmap,copy_file_range,ioctl,read,write")
        try:
            wait_text(sess, "tree")
            focus_by_filter(sess, "tree")
            sess.send(KEY_F5, wait=0.1)
            wait_text(sess, "Copy destination path:")
            sess.send(b"\r", wait=0.1)
            wait_text(sess, "Copied successfully", timeout=30)
            sess.send(KEY_ESC, wait=0.05)
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass
        dst = os.path.join(right, "tree")
        for rel, data in payload.items():
            with open(os.path.join(dst, rel), "rb") as f:
                assert f.read() == data, f"Copied content mismatch: {rel}"
        assert os.readlink(os.path.join(dst, "link_big")) == "big.bin"
        assert os.readlink(os.path.join(dst, "d0", "dangling")) == "/nonexistent/dangling"
        ev = parse_trace(trace)
        mmaps = sum(1 for _, sc, _ in ev if sc == "mmap")
        munmaps = sum(1 for _, sc, _ in ev if sc == "munmap")
        cfr = sum(1 for _, sc, ln in ev if sc == "copy_file_range" and "= -1" not in ln)
        assert mmaps < 300, f"Allocator still mmaps per file/dir: {mmaps} mmap calls for 1500 files"
        assert munmaps < 300, f"Allocator still munmaps per file/dir: {munmaps}"
        assert cfr >= 1, "Large regular file was not copied with copy_file_range"
        print(f"[PASS] FP1. Copy 1500 files + 8 MiB: byte-exact, {mmaps} mmap / {munmaps} munmap, copy_file_range used")

        # FP2: recursive delete driven by d_type: no stat per entry, fd-relative unlinkat
        trace = os.path.join(tmp, "delete.trace")
        sess = traced_session(trace, ["--lang", "en", right, left], "newfstatat,statx,unlinkat,unlink,rmdir")
        try:
            wait_text(sess, "tree")
            focus_by_filter(sess, "tree")
            sess.send(KEY_F8, wait=0.1)
            wait_text(sess, "Confirm Delete")
            sess.send(b"\r", wait=0.1)
            wait_text(sess, "Deleted successfully", timeout=30)
            sess.send(KEY_ESC, wait=0.05)
            sess.send(b"q", wait=0.1)
            assert sess.wait_exit(timeout=5) == 0
        finally:
            pass
        assert not os.path.exists(dst), "Delete left the tree behind"
        assert os.path.isfile(os.path.join(src, "big.bin")), "Delete touched the source panel"
        ev = parse_trace(trace)
        workers = {pid for pid, sc, _ in ev if sc == "unlinkat"}
        assert workers, "No unlinkat seen"
        stats = sum(1 for pid, sc, _ in ev if pid in workers and sc in ("newfstatat", "statx"))
        rel_unlinks = sum(1 for pid, sc, ln in ev if pid in workers and sc == "unlinkat"
                          and not ln.split("(", 1)[1].startswith("AT_FDCWD"))
        assert stats < 60, f"Recursive delete still stats every entry: {stats} stat calls"
        assert rel_unlinks > 1000, f"Delete is not dirfd-relative ({rel_unlinks} relative unlinkat)"
        print(f"[PASS] FP2. Delete 1500+ entries with {stats} stat calls and {rel_unlinks} dirfd-relative unlinkat")


def ref_name_key(name: str):
    b = name.encode()
    return (bytes(c + 32 if 65 <= c <= 90 else c for c in b), b)


def ref_ext_key(name: str):
    b = name.encode()
    dot = b.rfind(b".")
    if dot <= 0 or dot > 255:
        return (0, b"", ref_name_key(name))
    ext = b[dot + 1:]
    return (1, bytes(c + 32 if 65 <= c <= 90 else c for c in ext), ref_name_key(name))


def make_sort_names() -> list[str]:
    names = set()
    for i in range(140):
        names.add(f"SamePrefix_{i:03d}.dat")          # long shared 8-byte prefix
        names.add(f"sameprefiX_{i:03d}.Log")          # case-only differences vs above
    for i in range(120):
        names.add(f"z{i % 10}_{i:03d}.{'txt' if i % 3 else 'TXT'}")
        names.add(f"Ab{i:03d}")                        # short names, no extension
    for w in ("a", "B", "c.d", "Zeta.tar.gz", "алфа.txt", "Бета", "ёж.md", "_under", "~tilde", "9num"):
        names.add(w)
    return sorted(names)


def visible_sequence(sess: PtySession, known: set[str], total: int) -> list[str]:
    seq: list[str] = []
    sess.send(KEY_HOME, wait=0.15)
    for _ in range(total // 10 + 5):
        rows = []
        for r in range(2, sess.rows - 4):
            line = sess.vt.row_text(r)[: sess.cols // 2]
            for tok in re.split(r"[\s│▸]+", line):
                if tok in known:
                    rows.append(tok)
                    break
        for name in rows:
            if name not in seq:
                seq.append(name)
        if len(seq) >= total:
            break
        sess.send(KEY_PGDN, wait=0.08)
    return seq


def click_header(sess: PtySession, label: str) -> None:
    for r in range(1, 4):
        line = sess.vt.row_text(r)
        x = line.find(label)
        if 0 <= x < sess.cols // 2:
            sess.send_mouse(0, x + 1, r, "M", wait=0.05)
            sess.send_mouse(0, x + 1, r, "m", wait=0.2)
            return
    raise AssertionError(f"Header {label!r} not found\n{sess.vt.full_text()}")


def test_prefix_sort_and_filter_narrowing() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_fps_") as tmp:
        left, right = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(left)
        os.makedirs(right)
        names = make_sort_names()
        for n in names:
            open(os.path.join(left, n), "w").close()
        os.makedirs(os.path.join(left, "DirB"))
        os.makedirs(os.path.join(left, "dira"))
        known = set(names) | {"DirB", "dira"}
        total = len(known)

        sess = PtySession(BINARY, ["--lang", "en", left, right], cols=100, rows=40)
        try:
            wait_text(sess, "dira")
            exp_dirs = sorted(["DirB", "dira"], key=ref_name_key)
            exp = exp_dirs + sorted(names, key=ref_name_key)
            got = visible_sequence(sess, known, total)
            assert got == exp, f"SORT_NAME asc mismatch at {next(i for i,(a,b) in enumerate(zip(got,exp)) if a!=b)}"
            click_header(sess, "Name")
            got = visible_sequence(sess, known, total)
            exp_desc = sorted(["DirB", "dira"], key=ref_name_key, reverse=True) + \
                sorted(names, key=ref_name_key, reverse=True)
            assert got == exp_desc, "SORT_NAME desc mismatch"
            print(f"[PASS] FP3. Prefix-key SORT_NAME asc/desc exact on {total} tricky names (case, shared prefixes, UTF-8)")

            if "Perms" in sess.vt.full_text():
                click_header(sess, "Perms")
                got = visible_sequence(sess, known, total)
                exp_ext = exp_dirs + sorted(names, key=ref_ext_key)
                assert got == exp_ext, "SORT_EXT asc mismatch"
                print("[PASS] FP4. Prefix-key SORT_EXT ordering (no-ext first, case-folded ext, name tie-break)")
            click_header(sess, "Name")

            # Filter narrowing / widening must always equal a fresh full filter
            def apply(flt: str) -> None:
                sess.send(b"/", wait=0.05)
                wait_text(sess, "Live Filter")
                sess.send(b"\x15" + flt.encode() + b"\r", wait=0.15)

            for flt in ("pre", "pref", "prefix_1", "prefix_12", "PREFIX_1", "a", "", "TXT", "txt"):
                apply(flt)
                cnt = sum(1 for n in names if flt.lower().encode() in ref_name_key(n)[0])
                dcnt = sum(1 for n in ("DirB", "dira") if flt.lower().encode() in ref_name_key(n)[0])
                wait_text(sess, f"{dcnt} dirs, {cnt} files")
            print("[PASS] FP5. Incremental filter narrowing/widening equals full ASCII-ci filter")
            sess.send(KEY_ESC, wait=0.05)
            sess.send(b"q", wait=0.05)
            assert sess.wait_exit() == 0
        finally:
            pass


def test_static_contracts() -> None:
    mem = open(os.path.join(REPO_ROOT, "src/core/memory.s"), encoding="utf-8").read()
    mk = open(os.path.join(REPO_ROOT, "Makefile"), encoding="utf-8").read()
    tgt = open(os.path.join(REPO_ROOT, "include/os/linux/x86_64/pal_target.inc"), encoding="utf-8").read()
    assert "src/os/$(OS)/$(ARCH)/pal_simd.s" in mk, "SIMD primitives must live in PAL pal_simd.s"
    assert "SLAB_" in mem, "memory.s must implement the slab small-object allocator"
    for sym in ("OS_SYS_copy_file_range", "FICLONE"):
        assert sym in tgt, f"Missing {sym} in pal_target.inc"
    print("[PASS] FP6. Static contracts: PAL SIMD module, slab allocator, copy_file_range/FICLONE PAL")


def main() -> None:
    t0 = time.monotonic()
    test_static_contracts()
    test_copy_delete_syscall_budget()
    test_prefix_sort_and_filter_narrowing()
    print(f"ALL FAST-PATH TESTS PASSED ({time.monotonic() - t0:.2f}s).")


if __name__ == "__main__":
    main()
