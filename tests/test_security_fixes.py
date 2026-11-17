#!/usr/bin/env python3
"""TDD regression tests for security fixes:
1. Archive VFS OOB read / heap disclosure in .zip and .tar parsing & extraction.
2. Copy overwrite following symlinks in task_conflict.s (O_NOFOLLOW).
3. Global SIGBUS handler masking non-mapping SIGBUS / infinite loop.
"""
import os
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BINARY = os.path.join(ROOT, "duop")

_SIGBUS_HARNESS_ASM = r"""
.intel_syntax noprefix
.include "pal.inc"

.section .text
.global _start
.extern os_fault_guard_install
.extern os_sigbus_guard_install
.extern os_mmap_file_ro
.extern os_munmap

# argv[1]: "0" = mapped truncated file (expect exit 0)
#          "1" = unregistered SIGBUS via fault_guard (expect killed by SIGBUS)
#          "2" = unregistered SIGBUS via sigbus_guard (expect killed by SIGBUS)
_start:
    mov rax, [rsp]
    cmp rax, 2; jl .Lfail
    mov rbx, [rsp + 16]
    movzx r12d, byte ptr [rbx]
    cmp r12d, '0'; je .Lmapped
    cmp r12d, '1'; je .Lunreg_fault
    cmp r12d, '2'; je .Lunreg_sigbus
    jmp .Lfail

.Lmapped:
    call os_fault_guard_install
    mov edi, AT_FDCWD
    mov rsi, [rsp + 24]
    mov edx, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0600
    OS_OPENAT
    test eax, eax; js .Lfail
    mov r13d, eax
    sub rsp, 16
    mov rax, 0x1122334455667788
    mov [rsp], rax
    mov edi, r13d
    mov rsi, rsp
    mov edx, 8
    OS_WRITE
    add rsp, 16
    mov edi, r13d
    mov esi, 4096
    call os_mmap_file_ro
    test rax, rax; jz .Lfail
    mov r14, rax
    mov edi, r13d
    xor esi, esi
    mov eax, 77                 # SYS_ftruncate
    syscall
    test rax, rax; js .Lfail
    mov eax, [r14]
    test eax, eax; jnz .Lfail
    mov rdi, r14; mov esi, 4096; call os_munmap
    mov edi, r13d; OS_CLOSE
    xor edi, edi; mov eax, 60; syscall

.Lunreg_fault:
    call os_fault_guard_install
    jmp .Lkill_bus

.Lunreg_sigbus:
    call os_sigbus_guard_install

.Lkill_bus:
    OS_GETPID
    mov edi, eax
    mov esi, SIGBUS
    mov eax, OS_SYS_kill
    syscall
.Lfail:
    mov edi, 1; mov eax, 60; syscall
"""


def wait_for(sess, text, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        sess.drain(0.08)
        if text in sess.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{sess.vt.full_text()}")


def make_forged_zip(path, method=0, payload=b"HELLO", claim_comp=None, claim_uncomp=None, bad_off=None):
    name = b"evil.txt"
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    comp = len(payload) if claim_comp is None else claim_comp
    uncomp = len(payload) if claim_uncomp is None else claim_uncomp
    lh_off = 0 if bad_off is None else bad_off
    lh = struct.pack(
        "<IHHHHHIIIHH",
        0x04034B50, 20, 0, method, 0, 0, crc, comp, uncomp, len(name), 0,
    ) + name + payload
    cd_off = len(lh)
    cd = struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50, 20, 20, 0, method, 0, 0, crc, comp, uncomp,
        len(name), 0, 0, 0, 0, 0, lh_off,
    ) + name
    eocd = struct.pack(
        "<IHHHHIIH",
        0x06054B50, 0, 0, 1, 1, len(cd), cd_off, 0,
    )
    with open(path, "wb") as f:
        f.write(lh + cd + eocd)


def make_forged_tar(path, claim_size=65536):
    hdr = bytearray(512)
    name = b"evil.txt"
    hdr[0:len(name)] = name
    hdr[100:108] = b"0000644\x00"
    hdr[108:116] = b"0000000\x00"
    hdr[116:124] = b"0000000\x00"
    hdr[124:136] = f"{claim_size:011o}\x00".encode("ascii")
    hdr[136:148] = b"00000000000\x00"
    hdr[148:156] = b"        "
    hdr[156] = ord("0")
    chk = sum(hdr)
    hdr[148:156] = f"{chk:06o}\x00 ".encode("ascii")
    with open(path, "wb") as f:
        f.write(hdr + b"TARDATA\n" + b"\x00" * (512 - 8))


def _run_arc_view_no_crash(arc_name, build_fn):
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        build_fn(os.path.join(l, arc_name))
        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            wait_for(sess, arc_name)
            sess.send(b"\x1b[B")   # move to archive
            sess.send(b"\r")       # enter archive
            sess.drain(0.25)
            if "evil.txt" in sess.vt.full_text():
                sess.send(b"\x1b[B")   # move from '..' to evil.txt
                sess.send(b"\x1bOR")   # F3 view
                sess.drain(0.3)
                txt = sess.vt.full_text()
                assert "1048576" not in txt and "1024K" not in txt, f"Heap leak size in viewer:\n{txt}"
                sess.send(b"\x1b")     # close viewer if opened
                sess.drain(0.15)
            os.kill(sess.pid, 0)
            sess.send(b"\x1b[21~")  # F10 quit
            _, status = os.waitpid(sess.pid, 0)
            assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, f"Unexpected exit status: {status}"
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass


def test_archive_oob_zip_bad_offset():
    """Forged ZIP with local_header_offset past EOF must not crash duop."""
    _run_arc_view_no_crash(
        "oob_off.zip",
        lambda p: make_forged_zip(p, method=0, bad_off=0x100000),
    )


def test_archive_oob_zip_deflate_huge_comp():
    """Forged ZIP with deflate comp_size=4GiB-1 must not crash duop."""
    _run_arc_view_no_crash(
        "oob_def.zip",
        lambda p: make_forged_zip(p, method=8, payload=b"\x03\x00", claim_comp=0x7FFFFFFF, claim_uncomp=1024),
    )


def test_archive_oob_zip_stored_heap_leak():
    """Forged ZIP with stored uncomp_size >> file size must not crash or leak > file size."""
    _run_arc_view_no_crash(
        "oob_leak.zip",
        lambda p: make_forged_zip(p, method=0, payload=b"SAFE5", claim_comp=5, claim_uncomp=0x100000),
    )


def test_archive_oob_tar_huge_size():
    """Forged TAR with size >> file size must not crash duop."""
    _run_arc_view_no_crash(
        "oob_tar.tar",
        lambda p: make_forged_tar(p, claim_size=0x100000),
    )


def test_copy_overwrite_no_follow_symlink():
    """Overwriting an existing symlink in destination must NOT overwrite its target."""
    with tempfile.TemporaryDirectory() as tmp:
        l, r = os.path.join(tmp, "left"), os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        with open(os.path.join(l, "victim.txt"), "wb") as f:
            f.write(b"OVERWRITTEN_BY_COPY")
        secret = os.path.join(tmp, "secret.txt")
        with open(secret, "wb") as f:
            f.write(b"ORIGINAL_SECRET")
        os.symlink(secret, os.path.join(r, "victim.txt"))

        sess = PtySession(BINARY, ["--lang", "en", l, r], cols=100, rows=28)
        try:
            wait_for(sess, "victim.txt")
            sess.send(b"\x1b[B")    # select victim.txt
            sess.send(b"\x1b[15~")  # F5 copy
            wait_for(sess, "Copy")
            sess.send(b"\r")        # confirm copy
            wait_for(sess, "Overwrite")
            sess.send(b"\r")        # choose Overwrite
            sess.drain(0.4)
            sess.send(b"\x1b")      # dismiss any error/status if shown
            sess.send(b"\x1b[21~")  # F10 quit
            _, status = os.waitpid(sess.pid, 0)
            assert os.WIFEXITED(status), f"duop crashed with status {status}"
        finally:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass

        assert open(secret, "rb").read() == b"ORIGINAL_SECRET", "Symlink target was overwritten!"


def test_sigbus_handler_only_patches_registered_mappings():
    """SIGBUS in registered os_mmap_file_ro is patched; unregistered SIGBUS must terminate."""
    with tempfile.TemporaryDirectory() as d:
        s_path = os.path.join(d, "bus.s")
        o_path = os.path.join(d, "bus.o")
        b_path = os.path.join(d, "bus")
        open(s_path, "w").write(_SIGBUS_HARNESS_ASM)
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
        tmp_file = os.path.join(d, "trunc.bin")
        r0 = subprocess.run([b_path, "0", tmp_file], timeout=5)
        assert r0.returncode == 0, f"Mapped truncated file SIGBUS failed: rc={r0.returncode}"

        r1 = subprocess.run([b_path, "1"], timeout=5)
        assert r1.returncode == -signal.SIGBUS, f"Unregistered SIGBUS (fault_guard) was masked! rc={r1.returncode}"

        r2 = subprocess.run([b_path, "2"], timeout=5)
        assert r2.returncode == -signal.SIGBUS, f"Unregistered SIGBUS (sigbus_guard) was masked! rc={r2.returncode}"


if __name__ == "__main__":
    for fn in [
        test_archive_oob_zip_bad_offset,
        test_archive_oob_zip_deflate_huge_comp,
        test_archive_oob_zip_stored_heap_leak,
        test_archive_oob_tar_huge_size,
        test_copy_overwrite_no_follow_symlink,
        test_sigbus_handler_only_patches_registered_mappings,
    ]:
        print(f"RUN {fn.__name__}...", end=" ", flush=True)
        fn()
        print("OK")
