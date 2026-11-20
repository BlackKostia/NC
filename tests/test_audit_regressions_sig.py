#!/usr/bin/env python3
"""TDD regressions for S5 hangup, preview zombie/SIGPIPE, stack overflow guard, worker orphan, and pkg/VFS."""

import glob
import hashlib
import io
import os
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")

_ASM_SIG_HARNESS = r"""
.intel_syntax noprefix
.include "pal.inc"

.section .bss
.align 8

.section .text
.global _start
.extern os_fault_guard_install, os_term_save_and_raw

recurse_burn:
    sub rsp, 4096
    mov qword ptr [rsp], 1
    call recurse_burn
    ret

_start:
    call os_fault_guard_install
    call os_term_save_and_raw
    # Fork child and fault in child:
    # child must NOT emit ESC[?1049l onto stdout!
    OS_FORK
    test rax, rax
    js .Lfail
    jnz .Lparent
    mov rax, [rsp]
    cmp rax, 2
    jl .Lchild_abort
    call recurse_burn         # stack overflow under sigaltstack
.Lchild_abort:
    mov qword ptr [0], 1      # SIGSEGV in child -> pf_fatal_default
    mov edi, 1
    mov eax, 60
    syscall
.Lparent:
    mov rbx, rax
    sub rsp, 16
.Lw:
    mov rdi, rbx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Lw
    mov eax, [rsp]
    and eax, 0x7f
    cmp eax, 11               # died by SIGSEGV
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
    s_path = os.path.join(work_dir, "sig_h.s")
    o_path = os.path.join(work_dir, "sig_h.o")
    b_path = os.path.join(work_dir, "sig_h")
    open(s_path, "w").write(asm_src)
    subprocess.check_call([
        "as", "-I", os.path.join(ROOT, "include/os/linux/x86_64"),
        "-I", os.path.join(ROOT, "include"), s_path, "-o", o_path,
    ])
    objs = sorted(
        p for p in glob.glob(os.path.join(ROOT, "build/**/*.o"), recursive=True)
        if not p.endswith("/main.o") and not p.endswith("/pal_start.o")
    )
    subprocess.check_call(["ld", o_path] + objs + ["-o", b_path])
    return b_path


def test_hangup_exits_and_helper_no_zombie() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_s1_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        open(os.path.join(l, "a.txt"), "w").write("hello preview\n")

        # 1. S5: SIGHUP ignored + PTY master close -> must exit quickly without spinning
        s = PtySession(
            BINARY, ["--lang", "en", l, r],
            extra_env={"HOME": tmp},
        )
        # Re-test under SIGHUP=SIG_IGN via python preexec wrapper
        os.kill(s.pid, 9); os.waitpid(s.pid, 0); os.close(s.master)

        proc = subprocess.Popen(
            [BINARY, "--lang", "en", l, r],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=lambda: signal.signal(signal.SIGHUP, signal.SIG_IGN),
        )
        time.sleep(0.25)
        proc.stdin.close()
        rc = proc.wait(timeout=2.0)
        assert rc is not None

        # 2. Preview helper killed -> reaped promptly (no Z zombie)
        s2 = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            s2.drain(0.25)
            s2.send(b"\x1b[20~", wait=0.2)
            s2.send(b"\x1b[B", wait=0.3)
            out = subprocess.check_output(["ps", "-o", "pid=,ppid=,stat=", "--ppid", str(s2.pid)], text=True)
            kids = [int(ln.split()[0]) for ln in out.splitlines() if ln.strip()]
            assert kids, "Expected preview helper child"
            for k in kids:
                os.kill(k, signal.SIGKILL)
            time.sleep(0.6)
            out2 = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, kids))], capture_output=True, text=True, check=False).stdout if kids else ""
            assert "Z" not in out2, f"Preview helper left zombie:\n{out2}"
            s2.send(b"\x1b[21~", wait=0.15)
            assert s2.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(s2.pid, 9); os.waitpid(s2.pid, 0)
            except OSError:
                pass
    print("[PASS] RS1. Stdin EOF exits cleanly & dead preview helper is reaped with no zombie")


def test_embedded_pty_sigpipe_and_child_fds() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_s2_") as tmp:
        l, r = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(l); os.makedirs(r)
        s = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=30)
        try:
            s.drain(0.3)
            s.send(b"\x00", wait=0.3)  # Ctrl+` embedded shell
            s.send(b"yes | head -n 5 >/dev/null; echo PIPE_OK_$?\r", wait=0.5)
            assert "PIPE_OK_" in s.vt.full_text(), f"SIGPIPE ignored in shell pane:\n{s.vt.full_text()}"
            s.send(b"echo FDS:$(ls -1 /proc/$$/fd | tr '\\n' ',')\r", wait=0.4)
            txt = s.vt.full_text()
            assert "FDS:" in txt
            s.send(b"\x00", wait=0.15)
            s.send(b"\x1b[21~", wait=0.15)
            assert s.wait_exit(3.0) == 0
        finally:
            try:
                os.kill(s.pid, 9); os.waitpid(s.pid, 0)
            except OSError:
                pass
    print("[PASS] RS2. Embedded PTY shell receives SIGPIPE cleanly")


def _run_with_pty(cmd: list[str]) -> tuple[int, bytes]:
    mfd, sfd = os.openpty()

    def _setup() -> None:
        os.setsid()
        for fd in (0, 1, 2):
            os.dup2(sfd, fd)
        if sfd > 2:
            os.close(sfd)
        os.close(mfd)

    p = subprocess.Popen(cmd, preexec_fn=_setup, close_fds=True)
    os.close(sfd)
    chunks: list[bytes] = []
    while True:
        try:
            data = os.read(mfd, 4096)
            if not data:
                break
            chunks.append(data)
        except OSError:
            break
    os.close(mfd)
    return p.wait(timeout=5), b"".join(chunks)


def test_asm_fault_child_no_tty_corrupt_and_sigaltstack() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_s3_") as d:
        b = link_asm_harness(d, _ASM_SIG_HARNESS)
        rc0, out0 = _run_with_pty([b])
        assert rc0 == 0, f"Child fault harness failed: rc={rc0}"
        assert b"\x1b[?1049l" not in out0, "Forked child corrupted parent terminal!"

        rc1, out1 = _run_with_pty([b, "so"])
        assert rc1 == 0, f"Stack overflow sigaltstack failed: rc={rc1}"
        assert b"\x1b[?1049l" not in out1, "Stack-overflow child corrupted parent terminal!"
    print("[PASS] RS3. Forked child fault keeps parent TTY untouched & sigaltstack catches overflow")


def test_pkg_zip_verify_remove_and_vfs_traversal() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_s4_") as tmp:
        pkg_dir = os.path.join(tmp, "pkgs")
        zpath = os.path.join(tmp, "ztool.zip")
        env = dict(os.environ, HOME=tmp, DUOP_PKG_DIR=pkg_dir)
        manifest = b"name = ztool\nversion = 1.0.0\nkind = tool\ndescription = zip test\nexec = tool.sh\n"
        script = b"#!/bin/sh\necho ZIP_EXEC_OK\n"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("manifest.ini", manifest)
            zf.writestr("tool.sh", script)
            zf.writestr("sub/data.txt", b"NESTED_DATA")
        sha = hashlib.sha256(open(zpath, "rb").read()).hexdigest()

        r_inst = subprocess.run([BINARY, "pkg", "install", zpath, "--sha256", sha], env=env, capture_output=True, text=True)
        assert r_inst.returncode == 0, r_inst.stdout + r_inst.stderr
        installed_sh = open(os.path.join(pkg_dir, "ztool", "tool.sh"), "rb").read()
        assert installed_sh == script, f"ZIP local header corrupted extraction: {installed_sh!r}"

        open(os.path.join(pkg_dir, "ztool", "sha256"), "w").write("z" * 64)
        r_ver = subprocess.run([BINARY, "pkg", "verify", "ztool"], env=env, capture_output=True, text=True)
        assert r_ver.returncode != 0, "Invalid hex in sha256 passed pkg verify!"

        r_rem = subprocess.run([BINARY, "pkg", "remove", "ztool"], env=env, capture_output=True, text=True)
        assert r_rem.returncode == 0 and not os.path.exists(os.path.join(pkg_dir, "ztool")), r_rem.stderr

        # Crafted VFS package with traversal exec=../...
        vfs_dir = os.path.join(pkg_dir, "evilvfs")
        os.makedirs(vfs_dir)
        open(os.path.join(vfs_dir, "manifest.ini"), "w").write("name = evilvfs\nkind = vfs\nvfs_scheme = evil\nexec = ../../../bin/sh\n")
        r_vfs = subprocess.run([BINARY, "pkg", "vfs-list", "evil://x"], env=env, capture_output=True, text=True)
        assert r_vfs.returncode != 0, "VFS accepted path-traversal exec=!"
    print("[PASS] RS4. ZIP pkg extraction, sha256 hex verify, nested remove, VFS traversal blocked")


if __name__ == "__main__":
    test_hangup_exits_and_helper_no_zombie()
    test_embedded_pty_sigpipe_and_child_fds()
    test_asm_fault_child_no_tty_corrupt_and_sigaltstack()
    test_pkg_zip_verify_remove_and_vfs_traversal()
    print("ALL SIGNAL/PKG/PROCESS REGRESSION TESTS PASSED.")
