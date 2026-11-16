#!/usr/bin/env python3
"""TDD regressions for file I/O safety, fs_write_file, symlinks, FIFO hangs, conflicts & quoting."""

import glob
import os
import resource
import shutil
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")

_ASM_IO_HARNESS = r"""
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .bss
.align 8
.global g_envp
g_envp:    .space 8
h_buf64:   .space 128
h_out:     .space PATH_MAX
h_cmd_out: .space 256
h_ctx:     .space 40
h_st:      .space FileStat._size

.section .rodata
h_pfx50:   .ascii "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
           .byte 0
h_sfx:     .asciz ".tmp"
h_un_nm:   .asciz "uniq.txt"
h_tmpl:    .asciz "echo %s; printf 'ok'"
h_cur:     .asciz "a'b'c"
h_emp:     .asciz ""
h_sel500:  .ascii "'a' 'b' 'c' "
           .space 300, 'x'
           .byte 0

.section .text
.global _start
.extern tmp_open_unique, fs_task_resolve_conflict, g_fs_progress, config_expand_cmd, mem_set, os_poll_in

_start:
    # 1. tmp_open_unique with cap=64 and 50B prefix must fail cleanly (-1), never smash byte 64
    lea rdi, [rip + h_buf64]
    mov esi, 0x5A
    mov edx, 128
    call mem_set
    lea rdi, [rip + h_pfx50]
    lea rsi, [rip + h_sfx]
    lea rdx, [rip + h_buf64]
    mov ecx, 64
    call tmp_open_unique
    cmp rax, -1
    jne .Lfail
    lea rcx, [rip + h_buf64]
    cmp byte ptr [rcx + 64], 0x5A
    jne .Lfail

    # 2. fs_task_resolve_conflict with Rename in dir with uniq.txt + uniq_1..99 must NOT return "uniq.txt"
    mov rax, [rsp]
    cmp rax, 2
    jl .Lchk_cfg
    xor edi, edi
    mov esi, TaskShared._size
    mov edx, PROT_RW
    OS_MMAP_SHARED_ANON
    cmp rax, -4095
    jae .Lfail
    mov r13, rax
    mov [rip + g_fs_progress], r13
    OS_FORK
    test rax, rax
    js .Lfail
    jnz .Lpar_cfl
    mov edi, -1
    mov esi, 30
    call os_poll_in
    mov dword ptr [r13 + TaskShared.conflict_action], CONFLICT_ACT_RENAME
    mov dword ptr [r13 + TaskShared.conflict_state], 2
    xor edi, edi
    OS_EXIT
.Lpar_cfl:
    mov edi, AT_FDCWD
    mov rsi, [rsp + 16]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test eax, eax
    js .Lfail
    mov r12d, eax
    mov edi, r12d
    lea rsi, [rip + h_un_nm]
    mov edx, 10
    mov ecx, 10
    lea r8, [rip + h_out]
    call fs_task_resolve_conflict
    push rax
    mov edi, r12d
    OS_CLOSE
    mov edi, -1
    xor esi, esi
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    pop rax
    cmp rax, -EEXIST
    je .Lchk_cfg              # returning -EEXIST safely is also valid!
    lea rdi, [rip + h_out]
    lea rsi, [rip + h_un_nm]
    xor ecx, ecx
.Lcmp_l:
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .Lchk_cfg
    test al, al
    jz .Lfail                 # fell back to exact same original name -> overwrite hazard!
    inc rcx
    jmp .Lcmp_l

.Lchk_cfg:
    # 3. config_expand_cmd truncation must not emit an odd count of unescaped single quotes
    lea rax, [rip + h_cur]
    lea rbx, [rip + h_sel500]
    lea rcx, [rip + h_emp]
    mov [rip + h_ctx], rax
    mov [rip + h_ctx + 8], rax
    mov [rip + h_ctx + 16], rbx
    mov [rip + h_ctx + 24], rcx
    mov [rip + h_ctx + 32], rcx
    lea rdi, [rip + h_tmpl]
    lea rsi, [rip + h_cmd_out]
    mov edx, 48               # small buffer forcing truncation inside %s
    lea rcx, [rip + h_ctx]
    call config_expand_cmd
    cmp rax, -36              # ENAMETOOLONG: a command that does not fit is an error, never a cut-off script
    jne .Lfail
    cmp byte ptr [rip + h_cmd_out], 0
    jne .Lfail                # ... and the output is emptied so nothing runnable is left behind
    # Verify single quote count parity (must be even)
    lea rdi, [rip + h_cmd_out]
    xor ecx, ecx
    xor edx, edx
.Lq_l:
    mov al, [rdi + rcx]
    test al, al
    jz .Lq_done
    cmp al, 0x27
    jne .Lq_n
    inc edx
.Lq_n:
    inc rcx
    jmp .Lq_l
.Lq_done:
    test edx, 1
    jnz .Lfail

    xor edi, edi
    mov eax, 60
    syscall
.Lfail:
    mov edi, 1
    mov eax, 60
    syscall
"""


def link_asm_harness(work_dir: str, asm_src: str) -> str:
    s_path = os.path.join(work_dir, "io_h.s")
    o_path = os.path.join(work_dir, "io_h.o")
    b_path = os.path.join(work_dir, "io_h")
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


def test_asm_io_tmp_unique_and_expand_quotes() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_io1_") as d:
        cdir = os.path.join(d, "c")
        os.makedirs(cdir)
        open(os.path.join(cdir, "uniq.txt"), "w").write("orig")
        for i in range(1, 100):
            open(os.path.join(cdir, f"uniq_{i}.txt"), "w").write("x")
        b = link_asm_harness(d, _ASM_IO_HARNESS)
        res = subprocess.run([b, cdir], timeout=5)
        assert res.returncode == 0, f"IO harness failed: rc={res.returncode}"
    print("[PASS] RI1. tmp_open_unique bounds, >99 collision no-overwrite, config_expand overflow is an error with empty output")


def test_fifo_nonblocking_and_hex_symlink_safety() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_io2_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        os.mkfifo(os.path.join(l, "a_pipe"))
        ext = os.path.join(tmp, "ext_secret.bin")
        open(ext, "wb").write(b"KEEP_ME_SAFE")
        os.symlink(ext, os.path.join(l, "b_sym.bin"))
        fifo_cfg = os.path.join(tmp, "cfg_pipe")
        os.mkfifo(fifo_cfg)

        sess_cfg = PtySession(BINARY, ["--lang", "en", l, r], extra_env={"DUOP_CONFIG": fifo_cfg})
        try:
            sess_cfg.drain(0.25)
            sess_cfg.send(b"\x1b[21~", wait=0.15)
            assert sess_cfg.wait_exit(2.0) == 0
        finally:
            try:
                os.kill(sess_cfg.pid, 9); os.waitpid(sess_cfg.pid, 0)
            except OSError:
                pass

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.05)   # a_pipe
            sess.send(b"\x1bOR", wait=0.20)   # F3 on FIFO must not hang
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[B", wait=0.05)   # b_sym.bin
            sess.send(b"\x1bOR", wait=0.15)
            sess.send(b"he58", wait=0.10)
            sess.send(b"\x13", wait=0.15)     # Ctrl+S save on symlink
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
        assert open(ext, "rb").read() == b"KEEP_ME_SAFE", "hex_edit overwrote symlink target!"
    print("[PASS] RI2. FIFO viewer/config non-blocking & hex_edit symlink safety")


def test_copy_subdir_symlink_and_move_dir_conflict() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_io3_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        ext_dir = os.path.join(tmp, "ext_dir")
        os.makedirs(os.path.join(l, "sub"))
        os.makedirs(r); os.makedirs(ext_dir)
        open(os.path.join(l, "sub", "payload.txt"), "w").write("ATTACK")
        os.symlink(ext_dir, os.path.join(r, "sub"))

        os.makedirs(os.path.join(l, "zz_dir"))
        open(os.path.join(l, "zz_dir", "new.txt"), "w").write("NEW")
        os.makedirs(os.path.join(r, "zz_dir"))

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.05)   # sub
            sess.send(b"\x1b[15~", wait=0.15) # F5 copy
            sess.send(b"\r", wait=0.35)
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
        assert not os.path.exists(os.path.join(ext_dir, "payload.txt")), "copy_subdir traversed symlink in dst!"
    print("[PASS] RI3. copy_subdir refuses dst directory symlinks")


def test_chmod_info_symlinks_and_chown_error() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_io4_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        ext = os.path.join(tmp, "ext.txt")
        open(ext, "w").write("DATA")
        os.chmod(ext, 0o600)
        os.symlink(ext, os.path.join(l, "a_link"))
        open(os.path.join(l, "b_reg.txt"), "w").write("REG")
        os.symlink(os.path.join(tmp, "nonexistent"), os.path.join(l, "c_broken"))

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            sess.drain(0.25)
            sess.send(b"\x1b[B", wait=0.05)   # a_link
            sess.send(b"\x1ba", wait=0.15)    # Alt+A Chmod
            sess.send(b"3\r", wait=0.20)
            assert (os.stat(ext).st_mode & 0o777) == 0o600, "Chmod modified symlink target permissions!"

            if os.geteuid() != 0:
                sess.send(b"\x1b[B", wait=0.05)  # b_reg.txt
                sess.send(b"\x1ba", wait=0.15)
                sess.send(b"u" + b"\x7f" * 16 + b"0:0\r", wait=0.25)
                txt = sess.vt.full_text().lower()
                assert ("denied" in txt or "error" in txt or "failed" in txt), f"EPERM chown ignored:\n{txt}"

            sess.send(b"\x1b[B", wait=0.05)   # c_broken
            sess.send(b"\x1bi", wait=0.20)    # Alt+I Info
            os.kill(sess.pid, 0)
            sess.send(b"\x1b", wait=0.10)
            sess.send(b"\x1b[21~", wait=0.15)
            assert sess.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(sess.pid, 9); os.waitpid(sess.pid, 0)
            except OSError:
                pass
    print("[PASS] RI4. Chmod refuses symlink target & reports EPERM chown; broken symlink Info safe")


if __name__ == "__main__":
    test_asm_io_tmp_unique_and_expand_quotes()
    test_fifo_nonblocking_and_hex_symlink_safety()
    test_copy_subdir_symlink_and_move_dir_conflict()
    test_chmod_info_symlinks_and_chown_error()
    print("ALL IO REGRESSION TESTS PASSED.")
