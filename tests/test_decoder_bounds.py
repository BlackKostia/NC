#!/usr/bin/env python3
"""Image decoders must never read outside their input (audit 2026-11-16, fuzzed with a guard-page heap).

Links the real decoder objects from build/ with tests/harness/guard_alloc.c: every allocation sits against an
unmapped page, and the file under test is mapped so that its last byte is the last mapped byte.  A decoder that
reads past the end of the file (or past any buffer) dies with SIGSEGV and fails this test.

DB1 BMP palettes that extend past the end of the file (or are missing) are clamped, never read
DB2 well-formed images of every format still decode
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_BMP, IMG_PNG = 4, 1


def build_harness(work: str) -> str | None:
    if not shutil.which("gcc") or not shutil.which("objcopy"):
        print("[SKIP] decoder bounds: gcc/objcopy not available")
        return None
    subprocess.run(["make", "-s"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)
    objs = []
    for root, _, files in os.walk(os.path.join(REPO_ROOT, "build")):
        for f in files:
            if f.endswith(".o") and f not in ("main.o", "pal_start.o", "memory.o"):
                objs.append(os.path.join(root, f))
    mem = os.path.join(work, "memory_ren.o")
    subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=orig_mem_alloc", "--redefine-sym", "mem_free=orig_mem_free",
                    "--redefine-sym", "mem_realloc=orig_mem_realloc", os.path.join(REPO_ROOT, "build/core/memory.o"), mem],
                   check=True)
    exe = os.path.join(work, "decode_one")
    subprocess.run(["gcc", "-O1", "-static", "-fno-pie", "-no-pie", "-w", "-o", exe,
                    os.path.join(REPO_ROOT, "tests/harness/decode_one.c"),
                    os.path.join(REPO_ROOT, "tests/harness/guard_alloc.c"), mem] + sorted(objs),
                   check=True, stderr=subprocess.DEVNULL)
    return exe


def bmp(width: int, height: int, bpp: int, palette: bytes, pixels: bytes, clr_used: int = 0, off_bits: int | None = None) -> bytes:
    dib = struct.pack("<IiiHHIIiiII", 40, width, height, 1, bpp, 0, len(pixels), 2835, 2835, clr_used, 0)
    off = off_bits if off_bits is not None else 14 + 40 + len(palette)
    return b"BM" + struct.pack("<IHHI", off + len(pixels), 0, 0, off) + dib + palette + pixels


def decode(exe: str, work: str, fmt: int, data: bytes, name: str) -> int:
    path = os.path.join(work, name)
    with open(path, "wb") as f:
        f.write(data)
    return subprocess.run([exe, str(fmt), path], timeout=20).returncode


def test_bmp_palette_never_read_out_of_bounds(exe: str, work: str) -> None:
    row8 = bytes(range(200, 216)) * 2                      # indices 200..215 (outside a short palette)
    cases = {
        "full_palette_ok": bmp(32, 1, 8, bytes(1024), row8),
        "palette_cut_short": bmp(32, 1, 8, bytes(16), row8, clr_used=256),          # 4 of 256 entries present
        "no_palette_at_all": bmp(32, 1, 8, b"", row8, clr_used=256, off_bits=54),    # data starts where the palette should
        "palette_declared_huge": bmp(32, 1, 8, bytes(8), row8, clr_used=0x7FFFFFFF),
        "4bit_short_palette": bmp(32, 1, 4, bytes(8), bytes(range(0, 16)) * 1, clr_used=16),
        "1bit_no_palette": bmp(32, 1, 1, b"", b"\xaa\xaa\xaa\xaa", off_bits=54),
        "palette_runs_into_eof": bmp(8, 1, 8, bytes(40), bytes(range(10, 18)), clr_used=64, off_bits=54 + 40),
    }
    for name, data in cases.items():
        rc = decode(exe, work, IMG_BMP, data, name + ".bmp")
        assert rc in (0, 3), f"{name}: decoder died with status {rc} (out-of-bounds read)"
    assert decode(exe, work, IMG_BMP, cases["full_palette_ok"], "again.bmp") == 0, "a valid 8-bit BMP must decode"
    print("[PASS] DB1. BMP palettes beyond the end of the file are clamped, never read")


def png_chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def test_valid_images_still_decode(exe: str, work: str) -> None:
    raw = b"".join(b"\x00" + bytes([x * 7 & 255 for x in range(3 * 9)]) for _ in range(5))
    png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 9, 5, 8, 2, 0, 0, 0)) \
        + png_chunk(b"IDAT", zlib.compress(raw)) + png_chunk(b"IEND", b"")
    assert decode(exe, work, IMG_PNG, png, "ok.png") == 0, "valid PNG no longer decodes"
    assert decode(exe, work, IMG_BMP, bmp(4, 2, 24, b"", bytes(range(24)), off_bits=54), "ok24.bmp") == 0
    print("[PASS] DB2. Valid PNG / BMP inputs still decode under the guard-page heap")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="db_") as work:
        exe = build_harness(work)
        if exe is None:
            return
        test_bmp_palette_never_read_out_of_bounds(exe, work)
        test_valid_images_still_decode(exe, work)
    print("ALL DECODER BOUNDS TESTS PASSED.")


if __name__ == "__main__":
    main()
