#!/usr/bin/env python3
"""TDD tests for:
1. TRY_BEGIN/CATCH/TRY_END (SIGSEGV/SIGFPE/SIGBUS) and USING_FD/SCOPED_MEM macros.
2. Safe PID/UID-scoped temp files (no fixed /tmp/duop_* paths or symlink races).
3. Disk Usage depth > 24 (nested 32 levels).
4. Auto-generated docs/SYMBOLS.md catalog synchronization.
"""
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession
from du_util import du_text

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")
GEN_SYMBOLS = os.path.join(
    ROOT, ".agents", "skills", "duop-docs-sync", "scripts", "gen_symbols_catalog.py"
)

_TRY_HARNESS_ASM = r"""
.intel_syntax noprefix
.include "pal.inc"
.include "try_using.inc"

.section .text
.global _start
.extern os_fault_guard_install
.extern mem_alloc
.extern mem_free

_start:
    call os_fault_guard_install
    mov rbx, 0x1111222233334444
    mov r12, 0x5555666677778888
    mov r13, 0x9999aaaabbbbcccc
    mov r14, 0xddddeeeeffff0001
    mov r15, 0x0123456789abcdef
    mov rbp, rsp

    sub rsp, TRY_FRAME_SIZE + 16
    TRY_BEGIN rsp, .Lcatch_segv
    xor rax, rax
    mov dword ptr [rax], 42      # trigger SIGSEGV
    TRY_END rsp
    jmp .Lfail

.Lcatch_segv:
    cmp eax, 11
    jne .Lfail
    mov rax, 0x1111222233334444
    cmp rbx, rax; jne .Lfail
    mov rax, 0x5555666677778888
    cmp r12, rax; jne .Lfail
    mov rax, 0x9999aaaabbbbcccc
    cmp r13, rax; jne .Lfail
    mov rax, 0xddddeeeeffff0001
    cmp r14, rax; jne .Lfail
    mov rax, 0x0123456789abcdef
    cmp r15, rax; jne .Lfail
    lea rbp, [rsp + TRY_FRAME_SIZE + 16]

    TRY_BEGIN rsp, .Lcatch_fpe
    xor edx, edx
    mov eax, 100
    xor ecx, ecx
    div ecx                      # trigger SIGFPE
    TRY_END rsp
    jmp .Lfail

.Lcatch_fpe:
    cmp eax, 8
    jne .Lfail

    USING_FD_INIT [rsp + TRY_FRAME_SIZE]
    mov edi, AT_FDCWD
    lea rsi, [rip + dev_null]
    xor edx, edx
    xor r10d, r10d
    OS_OPENAT
    test eax, eax; js .Lfail
    USING_FD_SET [rsp + TRY_FRAME_SIZE], eax
    mov r12d, eax
    USING_FD_CLOSE [rsp + TRY_FRAME_SIZE]
    cmp dword ptr [rsp + TRY_FRAME_SIZE], -1
    jne .Lfail

    mov edi, r12d
    OS_CLOSE
    cmp rax, -9                  # -EBADF proves fd is closed
    jne .Lfail

    SCOPED_MEM_INIT [rsp + TRY_FRAME_SIZE + 8]
    mov edi, 128
    call mem_alloc
    test rax, rax; jz .Lfail
    SCOPED_MEM_SET [rsp + TRY_FRAME_SIZE + 8], rax
    SCOPED_MEM_FREE [rsp + TRY_FRAME_SIZE + 8]
    cmp qword ptr [rsp + TRY_FRAME_SIZE + 8], 0
    jne .Lfail

    xor edi, edi
    mov eax, 60
    syscall

.Lfail:
    mov edi, 1
    mov eax, 60
    syscall

.section .rodata
dev_null: .asciz "/dev/null"
"""


def wait_for(sess, text, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def test_no_fixed_tmp_paths_in_source():
    """Ensure fixed /tmp/duop_* literals are removed from src/."""
    forbidden = [
        "/tmp/duop_arc_view.tmp",
        "/tmp/duop_pkg_dl.tar.gz",
        "/tmp/duop_vfs_view",
        "/tmp/duop_marked_",
    ]
    for dirpath, _, files in os.walk(os.path.join(ROOT, "src")):
        for fn in files:
            if not fn.endswith(".s"):
                continue
            p = os.path.join(dirpath, fn)
            txt = open(p, encoding="utf-8", errors="replace").read()
            for bad in forbidden:
                assert bad not in txt, f"Fixed temp path {bad!r} still in {p}"


def test_archive_view_symlink_safe():
    """Viewing an archive entry must not follow a pre-planted /tmp/duop_arc_view.tmp symlink."""
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        arc_path = os.path.join(l, "sample.tar")
        payload = b"hello-from-safe-archive-view\n"
        with tarfile.open(arc_path, "w") as tf:
            ti = tarfile.TarInfo("inside.txt")
            ti.size = len(payload)
            tf.addfile(ti, io.BytesIO(payload))

        sentinel = os.path.join(tmp, "sentinel.txt")
        open(sentinel, "wb").write(b"UNTOUCHED")
        legacy_tmp = "/tmp/duop_arc_view.tmp"
        created_symlink = False
        try:
            if not os.path.lexists(legacy_tmp):
                os.symlink(sentinel, legacy_tmp)
                created_symlink = True
            sess = PtySession(BINARY, [l, r], cols=100, rows=28)
            try:
                wait_for(sess, "sample.tar")
                sess.send(b"\x1b[B")   # move from '..' to sample.tar
                sess.send(b"\r")
                wait_for(sess, "inside.txt")
                sess.send(b"\x1b[B")   # move from '..' to inside.txt
                sess.send(b"\x1b[13~")  # F3 view
                wait_for(sess, "hello-from-safe-archive-view")
                sess.send(b"\x1b")
                sess.send(b"\x1b[21~")  # F10 quit
            finally:
                try:
                    os.kill(sess.pid, 9)
                    os.waitpid(sess.pid, 0)
                except OSError:
                    pass
            assert open(sentinel, "rb").read() == b"UNTOUCHED"
        finally:
            if created_symlink and os.path.islink(legacy_tmp):
                os.unlink(legacy_tmp)


def test_du_deep_nesting():
    """Disk Usage (Alt+D) must count files deeper than 24 levels (e.g. depth 32)."""
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        cur = os.path.join(l, "d00")
        os.makedirs(cur)
        for i in range(1, 32):
            cur = os.path.join(cur, f"d{i:02d}")
            os.makedirs(cur)
        with open(os.path.join(cur, "deep_payload.bin"), "wb") as f:
            f.write(b"D" * 262144)
        expected_sz = du_text(os.path.join(l, "d00"))
        sess = PtySession(BINARY, [l, r], cols=100, rows=28)
        try:
            wait_for(sess, "d00")
            sess.send(b"\x1bd")
            wait_for(sess, expected_sz, timeout=5.0)
            sess.send(b"\x1b[21~")
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_try_catch_and_using_asm():
    """Assemble and run a standalone x86-64 harness verifying TRY_BEGIN/CATCH/TRY_END & USING."""
    with tempfile.TemporaryDirectory() as d:
        s_path = os.path.join(d, "harness.s")
        o_path = os.path.join(d, "harness.o")
        b_path = os.path.join(d, "harness")
        open(s_path, "w").write(_TRY_HARNESS_ASM)
        subprocess.check_call([
            "as", "-I", os.path.join(ROOT, "include/os/linux/x86_64"),
            "-I", os.path.join(ROOT, "include"),
            s_path, "-o", o_path,
        ])
        subprocess.check_call([
            "ld", o_path,
            os.path.join(ROOT, "build/os/linux/x86_64/pal_os.o"),
            os.path.join(ROOT, "build/os/linux/x86_64/pal_file.o"),
            os.path.join(ROOT, "build/os/linux/x86_64/pal_sys_mem.o"),
            os.path.join(ROOT, "build/os/linux/x86_64/pal_fault.o"),
            os.path.join(ROOT, "build/os/linux/x86_64/pal_simd.o"),
            os.path.join(ROOT, "build/core/try_rt.o"),
            os.path.join(ROOT, "build/core/memory.o"),
            "-o", b_path,
        ])
        res = subprocess.run([b_path], timeout=5)
        assert res.returncode == 0, f"TRY/USING harness failed with rc={res.returncode}"


def test_symbols_catalog_up_to_date():
    """docs/SYMBOLS.md must exist and match gen_symbols_catalog.py --check."""
    assert os.path.exists(GEN_SYMBOLS), f"Missing {GEN_SYMBOLS}"
    res = subprocess.run([sys.executable, GEN_SYMBOLS, "--check"], cwd=ROOT)
    assert res.returncode == 0, "docs/SYMBOLS.md is out of date; run make symbols"


if __name__ == "__main__":
    tests = [
        test_no_fixed_tmp_paths_in_source,
        test_archive_view_symlink_safe,
        test_du_deep_nesting,
        test_try_catch_and_using_asm,
        test_symbols_catalog_up_to_date,
    ]
    for fn in tests:
        print(f"RUN {fn.__name__}...", end=" ", flush=True)
        fn()
        print("OK")
