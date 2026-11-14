#!/usr/bin/env python3
"""Reliability & fault-tolerance tests for Duop.

Covers:
  1. Static ASM Stack & Struct Bounds Auditor (audit_stack_abi.py).
  2. Deep nested directory copy via PTY F5 (exercises copy_subdir / fs_copy_recursive).
  3. EEXIST conflict rename & overwrite via PTY F5 (exercises copy_reg_at / task_make_unique_name / copy_data).
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "duop"
AUDITOR = ROOT / ".agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py"


def run_pty(args: list[str], cwd: Path, seqs: list[bytes], post_wait: float = 0.6, timeout: float = 5.0) -> tuple[int, str]:
    master, slave = pty.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    env = os.environ.copy()
    env["TERM"] = "xterm-256color"
    env["LINES"] = "30"
    env["COLUMNS"] = "100"
    proc = subprocess.Popen(
        [str(BIN), *args],
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
        time.sleep(0.35)
        for seq in seqs:
            os.write(master, seq)
            time.sleep(0.12)
        time.sleep(post_wait)
        os.write(master, b"\x1b[21~")  # F10
        deadline = time.time() + timeout
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


def test_static_stack_struct_audit() -> None:
    res = subprocess.run(
        [sys.executable, str(AUDITOR)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert res.returncode == 0, f"Static stack/struct audit failed:\n{res.stdout}\n{res.stderr}"


def test_deep_nested_dir_copy() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "src"
        dst = base / "dst"
        src.mkdir()
        dst.mkdir()

        deep = src / "tree" / "lvl1" / "lvl2" / "lvl3"
        deep.mkdir(parents=True)
        (deep / "payload.bin").write_bytes(b"DUOP-DEEP-COPY-OK" * 32)
        os.chmod(src / "tree" / "lvl1", 0o750)
        sib = src / "tree" / "other"
        sib.mkdir()
        (sib / "note.txt").write_text("sibling-ok\n", encoding="utf-8")

        # Down to select 'tree' (past '..'), F5 Copy, Enter confirm
        seqs = [b"\x1b[B", b"\x1b[15~", b"\r"]
        rc, _ = run_pty([str(src), str(dst)], base, seqs, post_wait=0.8)
        assert rc == 0, f"duop exited with {rc}"

        copied_deep = dst / "tree" / "lvl1" / "lvl2" / "lvl3" / "payload.bin"
        copied_sib = dst / "tree" / "other" / "note.txt"
        assert copied_deep.is_file(), "Deep nested file was not copied"
        assert copied_deep.read_bytes() == b"DUOP-DEEP-COPY-OK" * 32
        assert copied_sib.is_file(), "Sibling dir file was not copied"
        assert copied_sib.read_text(encoding="utf-8") == "sibling-ok\n"


def test_copy_eexist_rename_conflict() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "src"
        dst = base / "dst"
        src.mkdir()
        dst.mkdir()

        (src / "alpha.txt").write_text("NEW-CONTENT-12345\n", encoding="utf-8")
        (dst / "alpha.txt").write_text("OLD-CONTENT\n", encoding="utf-8")

        # Down to alpha.txt, F5 Copy, Enter confirm -> Conflict dialog -> 'r' (Rename)
        seqs = [b"\x1b[B", b"\x1b[15~", b"\r", b"r"]
        rc, _ = run_pty([str(src), str(dst)], base, seqs, post_wait=0.8)
        assert rc == 0, f"duop exited with {rc}"

        assert (dst / "alpha.txt").read_text(encoding="utf-8") == "OLD-CONTENT\n"
        renamed = dst / "alpha_1.txt"
        assert renamed.is_file(), "Renamed conflict file alpha_1.txt missing"
        assert renamed.read_text(encoding="utf-8") == "NEW-CONTENT-12345\n"


def main() -> int:
    assert BIN.exists(), "duop binary missing; run make first"
    tests = [
        test_static_stack_struct_audit,
        test_deep_nested_dir_copy,
        test_copy_eexist_rename_conflict,
    ]
    for fn in tests:
        fn()
        print(f"PASS: {fn.__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
