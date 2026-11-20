#!/usr/bin/env python3
"""Phase F1: Full AArch64 static zero-libc Duop binary verification.

AF1. Zero non-PAL assembly files remain in src/ (every src/**/*.s is under src/os/)
AF2. `make ARCH=aarch64` links the full `duop` binary cleanly (using build_aarch64 headers)
AF3. ELF64 AArch64 hardening: static, no INTERP/.dynamic/TEXTREL, no W+X, NX stack
AF4. CLI under qemu-aarch64: --version, --help, -L == LICENSE, --lang uk, pkg, stdin EOF
AF5. Interactive PTY TUI session under qemu-aarch64: dual-pane render, navigation,
     F3 file viewer, F1 help dialog, F7 mkdir, --choosedir, F10 clean exit & TTY restore
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import c_harness as H  # noqa: E402
from pty_session import PtySession  # noqa: E402


def test_zero_non_pal_asm() -> None:
    asm_files = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "src").rglob("*.s"))
    non_pal = [p for p in asm_files if not p.startswith("src/os/")]
    assert not non_pal, f"Non-PAL assembly files still present: {non_pal}"
    assert len(asm_files) >= 28, f"Expected PAL assembly files under src/os/, found {len(asm_files)}"
    print(f"[PASS] AF1. Zero non-PAL .s files in src/ ({len(asm_files)} PAL modules under src/os/)")


def build_aarch64_duop() -> Path:
    out = ROOT / "build_aarch64" / "duop"
    res = subprocess.run(
        ["make", "-j8", "ARCH=aarch64", f"TARGET={out}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0, f"make ARCH=aarch64 failed:\n{res.stdout}\n{res.stderr}"
    assert out.is_file(), f"Missing {out}"
    print(f"[PASS] AF2. make ARCH=aarch64 linked full {out.relative_to(ROOT)} cleanly")
    return out


def test_elf_hardening(binary: Path) -> None:
    audit = ROOT / ".agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py"
    res = subprocess.run([sys.executable, str(audit), str(binary)], capture_output=True, text=True)
    assert res.returncode == 0, f"ELF hardening failed:\n{res.stdout}\n{res.stderr}"
    hdr = subprocess.run(["readelf", "-hlSdW", str(binary)], capture_output=True, text=True, check=True).stdout
    assert re.search(r"Machine:\s+AArch64", hdr), hdr[:400]
    assert "Class:                             ELF64" in hdr
    assert "INTERP" not in hdr and "There is no dynamic section" in hdr
    assert "RWE" not in hdr
    print("[PASS] AF3. AArch64 ELF64 hardening passed (static, zero-libc, no INTERP/.dynamic, no W+X)")


def run_a64(binary: Path, args: list[str], env: dict[str, str] | None = None,
            stdin: bytes = b"") -> subprocess.CompletedProcess:
    run_env = {"PATH": "/usr/bin:/bin", "DUOP_LANGS": str(ROOT / "lang"), **(env or {})}
    return subprocess.run(
        ["qemu-aarch64", str(binary), *args],
        input=stdin,
        capture_output=True,
        env=run_env,
        timeout=30,
    )


def test_cli(binary: Path) -> None:
    ver = (ROOT / "VERSION").read_text().strip()
    r = run_a64(binary, ["--version"])
    assert r.returncode == 0 and f"Duop v{ver}".encode() in r.stdout, r
    r_uk = run_a64(binary, ["--lang", "uk", "--version"])
    assert r_uk.returncode == 0 and "Розробник".encode() in r_uk.stdout, r_uk
    r_h = run_a64(binary, ["--help"])
    assert r_h.returncode == 0 and b"Usage: duop" in r_h.stdout, r_h
    r_l = run_a64(binary, ["-L"])
    assert r_l.returncode == 0 and r_l.stdout == (ROOT / "LICENSE").read_bytes(), r_l
    r_eof = run_a64(binary, [], stdin=b"")
    assert r_eof.returncode == 0, f"stdin EOF expected rc=0, got {r_eof.returncode}"
    with tempfile.TemporaryDirectory(prefix="duop_a64_pkg_") as td:
        r_pkg = run_a64(binary, ["pkg", "list"], env={"DUOP_PKG_DIR": td})
        assert r_pkg.returncode == 0, r_pkg
    print("[PASS] AF4. AArch64 CLI (--version, --help, -L, --lang uk, pkg list, stdin EOF) passed")


def test_pty_session(binary: Path) -> None:
    qemu = shutil.which("qemu-aarch64")
    assert qemu, "qemu-aarch64 not found"
    with tempfile.TemporaryDirectory(prefix="duop_a64_pty_") as tmp:
        left = os.path.join(tmp, "L")
        right = os.path.join(tmp, "R")
        os.mkdir(left)
        os.mkdir(right)
        with open(os.path.join(left, "alpha_arm64.txt"), "w") as f:
            f.write("HELLO_FROM_AARCH64_VIEWER\n")
        with open(os.path.join(right, "beta_right.txt"), "w") as f:
            f.write("RIGHT_PANE_OK\n")
        cdir = os.path.join(tmp, "chosen.txt")

        sess = PtySession(
            qemu,
            [str(binary), "--lang", "en", f"--choosedir={cdir}", left, right],
            cols=100,
            rows=28,
            extra_env={"HOME": tmp, "XDG_CONFIG_HOME": tmp, "XDG_DATA_HOME": tmp},
        )
        sess.drain(1.5, early=True)
        txt = sess.vt.full_text()
        assert "alpha_arm64.txt" in txt and "beta_right.txt" in txt, f"Initial render failed:\n{txt}"

        # Down to alpha_arm64.txt, open F3 viewer, check content, close with Esc
        sess.send(b"\x1b[B", wait=0.25)
        sess.send(b"\x1bOR", wait=0.5)
        vtxt = sess.vt.full_text()
        assert "HELLO_FROM_AARCH64_VIEWER" in vtxt, f"Viewer missing text:\n{vtxt}"
        sess.send(b"\x1b", wait=0.25)

        # Open F1 help dialog and close with Esc
        sess.send(b"\x1bOP", wait=0.4)
        htxt = sess.vt.full_text()
        assert "Overview" in htxt, f"Help dialog missing:\n{htxt}"
        sess.send(b"\x1b", wait=0.25)

        # Create a directory via F7 Mkdir
        sess.send(b"\x1b[18~", wait=0.35)
        sess.send(b"arm_dir\r", wait=0.4)
        assert os.path.isdir(os.path.join(left, "arm_dir")), "F7 mkdir failed under aarch64"

        # Quit via F10 and verify exit code, choosedir, and alt-screen exit
        sess.send(b"\x1b[21~", wait=0.3)
        rc = sess.wait_exit(timeout=5.0)
        assert rc == 0, f"Expected clean exit 0, got {rc}"
        assert sess.vt.saw_alt_enter and sess.vt.saw_alt_exit, "Alt-screen enter/exit missing"
        assert Path(cdir).read_text().strip() == left, "choosedir mismatch"
    print("[PASS] AF5. AArch64 interactive PTY TUI session (render, F3 viewer, F1 help, F7 mkdir, choosedir, F10) passed")


def main() -> None:
    test_zero_non_pal_asm()
    if not H.available("aarch64"):
        print("[SKIP] AF2-AF5: aarch64 toolchain or qemu-aarch64 unavailable")
        return
    binary = build_aarch64_duop()
    test_elf_hardening(binary)
    test_cli(binary)
    test_pty_session(binary)
    print("ALL FULL AARCH64 TESTS PASSED.")


if __name__ == "__main__":
    main()
