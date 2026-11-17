#!/usr/bin/env python3
"""TDD regressions for memory wraparound, OOM ScreenBuffer, CRLF config, input compaction, tiny PTY & fuzzy walk."""

import glob
import io
import os
import subprocess
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")

_ASM_MEM_HARNESS = r"""
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .bss
.align 8
h_pool:   .space 16384
h_items:  .space 1024

.section .text
.global _start
.extern mem_alloc, mem_realloc, mem_free, ScreenBuffer_new, ScreenBuffer_dtor
.extern dir_fuzzy_collect, alloc_initial_arrays

_start:
    # 1. mem_realloc wraparound must return NULL (0) instead of old ptr
    mov edi, 32
    call mem_alloc
    test rax, rax
    jz .Lfail
    mov r12, rax
    mov rdi, r12
    mov rsi, -16
    call mem_realloc
    test rax, rax
    jnz .Lfail
    mov rdi, r12
    call mem_free

    # 2. ScreenBuffer_new huge dimensions must return NULL (resize OOM)
    mov edi, 2000000
    mov esi, 2000000
    call ScreenBuffer_new
    test rax, rax
    jnz .Lfail

    # 3. dir_fuzzy_collect on deeply nested argv[1] (~4000B root + 200B dir) must not smash stack
    mov rax, [rsp]
    cmp rax, 2
    jl .Lok
    mov rdi, [rsp + 16]
    lea rsi, [rip + h_pool]
    mov edx, 16384
    lea rcx, [rip + h_items]
    mov r8d, 64
    call dir_fuzzy_collect
.Lok:
    xor edi, edi
    mov eax, 60
    syscall
.Lfail:
    mov edi, 1
    mov eax, 60
    syscall
"""


def link_asm_harness(work_dir: str, asm_src: str) -> str:
    s_path = os.path.join(work_dir, "mem_h.s")
    o_path = os.path.join(work_dir, "mem_h.o")
    b_path = os.path.join(work_dir, "mem_h")
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


def test_asm_mem_oom_and_dfc_stack_safety() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_m1_") as d:
        deep = d
        for _ in range(19):
            deep = os.path.join(deep, "d" * 200)
            os.mkdir(deep)
        sub = os.path.join(deep, "s" * 200)
        os.mkdir(sub)
        open(os.path.join(sub, "f.txt"), "w").write("x")
        b = link_asm_harness(d, _ASM_MEM_HARNESS)
        res = subprocess.run([b, deep], timeout=5)
        assert res.returncode == 0, f"Memory/dfc harness failed: rc={res.returncode}"
    print("[PASS] RM1. mem_realloc wraparound NULL, ScreenBuffer_new OOM clean, dfc_join stack safe")


def test_crlf_config_empty_lines() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_m2_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        cfg = os.path.join(tmp, "duoprc")
        open(cfg, "wb").write(b"\r\n\r\ntheme 1\r\n\r\nbind x quit\r\n")
        sess = PtySession(BINARY, ["--lang", "en", l, r], extra_env={"DUOP_CONFIG": cfg})
        try:
            sess.drain(0.25)
            assert "Catppuccin" in sess.vt.full_text(), f"CRLF blank line stopped config parse:\n{sess.vt.full_text()}"
            sess.send(b"x", wait=0.15)
            assert sess.wait_exit(2.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RM2. CRLF duoprc with blank lines parses completely")


def test_tiny_terminal_image_and_zoom() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_m3_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        buf = io.BytesIO()
        Image.new("RGB", (24, 24), (20, 120, 220)).save(buf, "PNG")
        open(os.path.join(l, "ok.png"), "wb").write(buf.getvalue())
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=40, rows=16)
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.05)
            sess.send(b"\x1bOR", wait=0.15)
            sess.send(b"i", wait=0.20)
            sess.send(b"+", wait=0.10)
            sess.resize(4, 4)
            os.kill(sess.pid, 0)
            sess.resize(80, 24)
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RM3. Tiny 4x4 terminal resize during zoomed image view avoids SIGFPE")


def test_split_csi_and_fuzzy_subdirs() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_m4_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(os.path.join(l, "dirA", "subA"))
        os.makedirs(os.path.join(l, "dirB"))
        os.makedirs(r)
        open(os.path.join(l, "dirA", "subA", "x1.txt"), "w").write("1")
        open(os.path.join(l, "dirB", "unique_b_target.txt"), "w").write("2")

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            sess.drain(0.25)
            # Fill near 512B in_buf with long partial CSI + compaction trigger, then Alt+P
            sess.send(b"x" * 490 + b"\x1b[" + b"1;" * 20, wait=0.003)
            sess.send(b"1~", wait=0.08)
            sess.send(b"\x1bp", wait=0.20)
            sess.send(b"unique_b", wait=0.20)
            assert "unique_b_target.txt" in sess.vt.full_text(), (
                f"dfc_walk shared dirent buffer lost dirB sibling:\n{sess.vt.full_text()}"
            )
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RM4. in_buf CSI compaction & multi-subdir fuzzy finder work cleanly")


if __name__ == "__main__":
    test_asm_mem_oom_and_dfc_stack_safety()
    test_crlf_config_empty_lines()
    test_tiny_terminal_image_and_zoom()
    test_split_csi_and_fuzzy_subdirs()
    print("ALL MEM/TUI REGRESSION TESTS PASSED.")
