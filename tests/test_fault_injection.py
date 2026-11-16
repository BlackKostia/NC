#!/usr/bin/env python3
"""Fault-injection & fuzzing tests for Duop parsers, image decoders, and config loaders.

Ensures malformed, truncated, or adversarial inputs never cause SIGSEGV/SIGBUS/SIGFPE
or memory leaks (checked against duop_memcheck when available).
"""

from __future__ import annotations

import os
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "duop"
MC_BIN = ROOT / "duop_memcheck"


def run_pty(bin_path: Path, args: list[str], cwd: Path, seqs: list[bytes], env_extra: dict[str, str] | None = None) -> tuple[int, str]:
    master, slave = pty.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    env = os.environ.copy()
    env["TERM"] = "xterm-256color"
    env["LINES"] = "28"
    env["COLUMNS"] = "96"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen(
        [str(bin_path), *args],
        cwd=str(cwd),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    out = bytearray()
    try:
        time.sleep(0.3)
        for seq in seqs:
            os.write(master, seq)
            time.sleep(0.1)
        time.sleep(0.25)
        os.write(master, b"\x1b[21~")  # F10
        deadline = time.time() + 4.0
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(master, 4096)
                    if not chunk:
                        break
                    out.extend(chunk)
                except OSError:
                    break
            elif proc.poll() is not None:
                break
        proc.wait(timeout=2.0)
    finally:
        try:
            os.close(master)
        except OSError:
            pass
    return proc.returncode, out.decode("utf-8", errors="replace")


def write_malformed_images(d: Path) -> None:
    # 1. PNG with huge width/height (integer overflow / OOM guard) + truncated IDAT
    ihdr = struct.pack(">IIBBBBB", 0x7FFFFFFF, 0x7FFFFFFF, 8, 6, 0, 0, 0)
    (d / "bad_huge.png").write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr + b"\x00\x00\x00\x00")
    # 2. Truncated JPEG SOF0 with 0 components / 0xFFFF dims
    (d / "bad_trunc.jpg").write_bytes(b"\xff\xd8\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x00")
    # 3. GIF with LZW clear code flood / zero dimensions
    (d / "bad_lzw.gif").write_bytes(b"GIF89a\x00\x00\x00\x00\x80\x00\x00" + b"\xff" * 64 + b"\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x08\x02\x00\x01\x00;")
    # 4. BMP with negative/huge header size & 0 bpp
    (d / "bad_hdr.bmp").write_bytes(b"BM" + struct.pack("<IHHI", 64, 0, 0, 54) + struct.pack("<IiiHH", 40, -1, -1, 1, 0))
    # 5. PNM P6 with 0 maxval (division-by-zero guard)
    (d / "bad_zero.ppm").write_bytes(b"P6\n10 10\n0\n" + b"\xaa" * 30)
    # 6. TGA RLE packet overflowing buffer
    (d / "bad_rle.tga").write_bytes(b"\x00\x00\x0a" + b"\x00" * 9 + struct.pack("<HHBB", 2, 2, 32, 0) + b"\xff\x11\x22\x33")


def test_corrupt_images_preview_and_viewer() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "imgs"
        dst = base / "empty"
        src.mkdir()
        dst.mkdir()
        write_malformed_images(src)

        # Toggle Preview (Ctrl+P), step down through all 6 bad images, open F3 on one, Esc
        seqs = [b"\x10"] + [b"\x1b[B"] * 6 + [b"\x1bOR", b"\x1b"]
        rc, _ = run_pty(BIN, [str(src), str(dst)], base, seqs)
        assert rc == 0, f"duop crashed on malformed images (rc={rc})"


def test_corrupt_configs_and_lang_packs() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        cfg = base / "duoprc"
        cfg.write_bytes(b"lang = \xff\xfe\x00\n" + b"A" * 8192 + b"\nkeymap = ../../../etc/passwd\n")
        lang_dir = base / "lang"
        lang_dir.mkdir()
        (lang_dir / "bad.lang").write_bytes(b"\x00\xff=broken\n" + b"k=v\n" * 500)
        lay_dir = base / "layouts"
        lay_dir.mkdir()
        (lay_dir / "bad.layout").write_bytes(b"not_hex=zzzz\n\xff\xfe\n")

        env = {
            "DUOP_CONFIG": str(cfg),
            "DUOP_LANGS": str(lang_dir),
            "DUOP_LAYOUTS": str(lay_dir),
        }
        rc, _ = run_pty(BIN, [str(base), str(base)], base, [b"\x1b[B"], env_extra=env)
        assert rc == 0, f"duop crashed on malformed config/lang/layout (rc={rc})"


def test_memcheck_malformed_image_no_leaks() -> None:
    if not MC_BIN.is_file():
        return
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "imgs"
        src.mkdir()
        write_malformed_images(src)
        mc_log = base / "mc.log"
        rc, _ = run_pty(
            MC_BIN,
            [str(src), str(base)],
            base,
            [b"\x10", b"\x1b[B", b"\x1b[B", b"\x1bOR", b"\x1b"],
            env_extra={"DUOP_MEMCHECK_LOG": str(mc_log)},
        )
        assert rc == 0, f"duop_memcheck crashed (rc={rc})"
        if mc_log.is_file():
            txt = mc_log.read_text(encoding="utf-8", errors="replace")
            assert "LEAK " not in txt and "BAD_FREE" not in txt, f"Memcheck error:\n{txt}"


def test_path_max_boundary_no_crash() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "src"
        dst = base / "dst"
        src.mkdir()
        dst.mkdir()
        # Build deep tree exceeding PATH_MAX (4096 bytes) using dir_fd
        dfd = os.open(src, os.O_RDONLY)
        seg = "d" * 200
        try:
            for i in range(21):
                name = f"{seg}_{i:02d}"
                os.mkdir(name, dir_fd=dfd)
                ndfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=dfd)
                os.close(dfd)
                dfd = ndfd
            lfd = os.open("leaf.txt", os.O_WRONLY | os.O_CREAT, 0o644, dir_fd=dfd)
            os.write(lfd, b"deep-path-ok\n")
            os.close(lfd)
        finally:
            os.close(dfd)

        # Select deep dir and attempt F5 copy; must not crash on ENAMETOOLONG / truncation
        rc, _ = run_pty(BIN, [str(src), str(dst)], base, [b"\x1b[B", b"\x1b[15~", b"\r", b"\x1b"])
        assert rc == 0, f"duop crashed on PATH_MAX boundary tree (rc={rc})"


def test_parallel_du_stress() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "du_tree"
        dst = base / "dst"
        src.mkdir()
        dst.mkdir()
        for d in range(8):
            sub = src / f"dir_{d}"
            sub.mkdir()
            for f in range(30):
                (sub / f"f_{f}.dat").write_bytes(b"X" * 128)

        # Trigger Ctrl+U / Alt+D or navigate while DU is active, then quit cleanly
        mc_log = base / "mc_du.log"
        target_bin = MC_BIN if MC_BIN.is_file() else BIN
        rc, _ = run_pty(
            target_bin,
            [str(src), str(dst)],
            base,
            [b"\x1bd", b"\x1b[B", b"\x1b[B", b"\x1b"],
            env_extra={"DUOP_MEMCHECK_LOG": str(mc_log)},
        )
        assert rc == 0, f"duop crashed during parallel DU stress (rc={rc})"
        if MC_BIN.is_file() and mc_log.is_file():
            txt = mc_log.read_text(encoding="utf-8", errors="replace")
            assert "LEAK " not in txt and "BAD_FREE" not in txt, f"DU memcheck error:\n{txt}"


def test_ppoll_enomem_stays_alive() -> None:
    """Transient ppoll -ENOMEM must retry instead of closing stdin/quitting UI."""
    import shutil
    if not (ROOT / "tools/faultlab/faultlab.c").is_file() or not shutil.which("gcc"):
        return
    rules = []
    for occ in range(2, 6):
        rules += ["-r", f"e:u:271:{occ}:1:12:any"]
    res = subprocess.run(
        [sys.executable, str(ROOT / "tools/faultlab/campaign.py"), "one", "copy", *rules],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=30,
        check=True,
    )
    json_part = res.stdout.split("\n}\n", 1)[0] + "\n}"
    import json
    data = json.loads(json_part)
    assert data["cls"] == "OK", f"ppoll -ENOMEM killed UI early: {data}"


def main() -> int:
    assert BIN.exists(), "duop binary missing; run make first"
    for fn in (
        test_corrupt_images_preview_and_viewer,
        test_corrupt_configs_and_lang_packs,
        test_memcheck_malformed_image_no_leaks,
        test_path_max_boundary_no_crash,
        test_parallel_du_stress,
        test_ppoll_enomem_stays_alive,
    ):
        fn()
        print(f"PASS: {fn.__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
