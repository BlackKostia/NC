#!/usr/bin/env python3
"""TDD regressions for image/ELF/archive parsers, TRY_END RAX clobbering, and Sixel/JPEG bounds."""

import glob
import io
import os
import struct
import subprocess
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")

_ASM_PARSER_HARNESS = r"""
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "try_using.inc"

.section .bss
.align 8
.global g_envp
g_envp:   .space 8
h_try:    .space TRY_FRAME_SIZE
h_img:    .space Image._size
h_six:    .space 128

.section .rodata
h_bad_bmp: .ascii "BM"
           .space 60, 0

.section .text
.global _start
.extern g_try_frame, os_fault_guard_install, img_decode, img_fit, img_sixel_encode, mem_set

_start:
    call os_fault_guard_install
    # 1. TRY_END must preserve RAX when g_try_frame prev is NULL
    lea r8, [rip + h_try]
    TRY_BEGIN r8, .Lfail
    mov eax, -3
    lea r8, [rip + h_try]
    TRY_END r8
    cmp eax, -3
    jne .Lfail

    # 2. img_decode on corrupt BMP must return nonzero (< 0)
    lea rdi, [rip + h_bad_bmp]
    mov esi, 62
    mov edx, IMG_FMT_BMP
    lea rcx, [rip + h_img]
    call img_decode
    test eax, eax
    jge .Lfail

    # 3. img_fit(0, 0, 10, 10) must not raise SIGFPE
    xor edi, edi
    xor esi, esi
    mov edx, 10
    mov ecx, 10
    call img_fit

    # 4. img_sixel_encode with cap=16 must return 0 and preserve canary beyond byte 16
    lea rdi, [rip + h_six]
    mov esi, 0xAA
    mov edx, 128
    call mem_set
    lea rdi, [rip + h_six + 64]
    mov esi, 1
    mov edx, 1
    xor ecx, ecx
    lea r8, [rip + h_six]
    mov r9d, 16
    call img_sixel_encode
    test rax, rax
    jnz .Lfail
    lea rcx, [rip + h_six]
    cmp byte ptr [rcx + 16], 0xAA
    jne .Lfail

    xor edi, edi
    mov eax, 60
    syscall
.Lfail:
    mov edi, 1
    mov eax, 60
    syscall
"""


def link_asm_harness(work_dir: str, asm_src: str) -> str:
    s_path = os.path.join(work_dir, "harness.s")
    o_path = os.path.join(work_dir, "harness.o")
    b_path = os.path.join(work_dir, "harness")
    open(s_path, "w").write(asm_src)
    subprocess.check_call([
        "as", "-I", os.path.join(ROOT, "include/os/linux/x86_64"),
        "-I", os.path.join(ROOT, "include"), s_path, "-o", o_path,
    ])
    objs = sorted(
        p for p in glob.glob(os.path.join(ROOT, "build/**/*.o"), recursive=True)
        if not p.endswith("/main.o")
    )
    subprocess.check_call(["ld", o_path] + objs + ["-o", b_path])
    return b_path


def make_corrupt_images(left_dir: str) -> list[str]:
    names = []
    bmp = bytearray(b"BM" + b"\x00" * 68)
    struct.pack_into("<I", bmp, 10, 0xFFFF0036)
    struct.pack_into("<IiiHHI", bmp, 14, 40, 37, 23, 1, 24, 0)
    open(os.path.join(left_dir, "01.bmp"), "wb").write(bmp)
    names.append("01.bmp")

    buf = io.BytesIO()
    Image.new("RGB", (37, 23)).save(buf, "PNG")
    open(os.path.join(left_dir, "02.png"), "wb").write(buf.getvalue()[:60])
    names.append("02.png")

    dht_counts = bytes([255] + [0] * 15)
    dht = b"\xff\xc4" + struct.pack(">H", 2 + 1 + 16 + 255) + b"\x00" + dht_counts + b"\x00" * 255
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, 8, 8, 1) + b"\x01\x31\x00"
    jpg = b"\xff\xd8" + dht + sof + b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x00\xff\xd9"
    open(os.path.join(left_dir, "03.jpg"), "wb").write(jpg)
    names.append("03.jpg")

    tga = struct.pack("<BBBHHBHHHHBB", 0, 0, 1, 0, 0, 0, 0, 0, 4, 4, 8, 0) + b"\x00" * 16
    open(os.path.join(left_dir, "04.tga"), "wb").write(tga)
    names.append("04.tga")

    qoi = b"qoif" + struct.pack(">IIBB", 4, 4, 3, 0) + b"\xfe\x11"
    open(os.path.join(left_dir, "05.qoi"), "wb").write(qoi)
    names.append("05.qoi")
    return names


def make_test_zip(path: str, name: bytes, method: int, payload: bytes, uncomp_size: int) -> None:
    lh = struct.pack(
        "<IHHHHHIIIHH", 0x04034B50, 20, 0, method, 0, 0, 0,
        len(payload), uncomp_size, len(name), 0,
    ) + name + payload
    cd = struct.pack(
        "<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, method, 0, 0, 0,
        len(payload), uncomp_size, len(name), 0, 0, 0, 0, 0, 0,
    ) + name
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(cd), len(lh), 0)
    open(path, "wb").write(lh + cd + eocd)


def test_viewer_corrupt_images_no_sigfpe() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_p1_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        names = make_corrupt_images(l)
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            sess.drain(0.25)
            for _ in names:
                sess.send(b"\x1b[B", wait=0.05)
                sess.send(b"\x1bOR", wait=0.15)
                sess.send(b"i", wait=0.20)
                os.kill(sess.pid, 0)
                sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(timeout=3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RP1. Corrupt BMP/PNG/JPG/TGA/QOI do not crash ViewerDialog (no SIGFPE)")


def test_elf_inspector_wraparound_and_nonul() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_p2_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        ehdr = bytearray(64)
        ehdr[0:5] = b"\x7fELF\x02"
        struct.pack_into("<HH", ehdr, 16, 2, 62)
        struct.pack_into("<Q", ehdr, 40, 0xFFFFFFFFFFFFFFF0)
        struct.pack_into("<HHH", ehdr, 58, 64, 4, 0)
        open(os.path.join(l, "wrap.elf"), "wb").write(ehdr)

        eh2 = bytearray(64 + 64 + 8)
        eh2[0:5] = b"\x7fELF\x02"
        struct.pack_into("<HH", eh2, 16, 2, 62)
        struct.pack_into("<Q", eh2, 40, 64)
        struct.pack_into("<HHH", eh2, 58, 64, 1, 0)
        struct.pack_into("<II", eh2, 64, 1, 3)
        struct.pack_into("<QQ", eh2, 64 + 24, 128, 8)
        eh2[128:136] = b"NO_NUL__"
        open(os.path.join(l, "nonul.elf"), "wb").write(eh2)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[20~", wait=0.15)
            sess.send(b"\x1b[B", wait=0.25)
            sess.send(b"\x1b[B", wait=0.25)
            os.kill(sess.pid, 0)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RP2. Malformed ELF64 wraparound & missing NUL in shstrtab survive PreviewPane")


def test_zip_unsupported_method_and_bomb() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_p3_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        payload = b"RAW_UNSUPPORTED_99_MARKER"
        make_test_zip(os.path.join(l, "m99.zip"), b"m.bin", 99, payload, len(payload))
        make_test_zip(os.path.join(l, "z_bomb.zip"), b"b.bin", 8, b"\x03\x00", 256 * 1024 * 1024)

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            sess.drain(0.25)
            for _ in range(2):
                sess.send(b"\x1b[B", wait=0.05)
                sess.send(b"\r", wait=0.20)
                sess.send(b"\x1b[B", wait=0.05)
                sess.send(b"\x1bOR", wait=0.25)
                assert "RAW_UNSUPPORTED_99_MARKER" not in sess.vt.full_text()
                sess.send(b"\x1b", wait=0.10)
                sess.send(b"\x7f", wait=0.15)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RP3. ZIP unsupported compression rejected & deflate bomb capped")


def test_asm_parser_contracts() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_p4_") as d:
        b = link_asm_harness(d, _ASM_PARSER_HARNESS)
        res = subprocess.run([b], timeout=5)
        assert res.returncode == 0, f"ASM parser contract harness failed: rc={res.returncode}"
    print("[PASS] RP4. TRY_END preserves RAX, img_decode propagates error, img_fit(0) safe, sixel bounds")


if __name__ == "__main__":
    test_viewer_corrupt_images_no_sigfpe()
    test_elf_inspector_wraparound_and_nonul()
    test_zip_unsupported_method_and_bomb()
    test_asm_parser_contracts()
    print("ALL PARSER REGRESSION TESTS PASSED.")
