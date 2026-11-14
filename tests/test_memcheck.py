#!/usr/bin/env python3
"""TDD tests for Duop MEMCHECK=1 memory leak & bad-free detector + scripts/memcheck.py."""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts", "memcheck.py")


def test_cli_flags_zero_leaks():
    for flag in ("--version", "--help"):
        res = subprocess.run(
            [sys.executable, SCRIPT, "--no-build", "--", os.path.join(ROOT, "duop_memcheck"), flag],
            cwd=ROOT, capture_output=True, text=True, timeout=15,
        )
        assert res.returncode == 0, f"Leak/error on {flag}:\n{res.stdout}\n{res.stderr}"
        assert "bad_frees=0" in res.stdout, f"Missing summary for {flag}:\n{res.stdout}"
    print("[PASS] MC1. CLI flags (--version, --help) report 0 leaks and 0 bad frees")


def test_pty_smoke_session():
    res = subprocess.run(
        [sys.executable, SCRIPT, "--smoke"],
        cwd=ROOT, capture_output=True, text=True, timeout=30,
    )
    assert res.returncode == 0, f"PTY smoke memcheck failed:\n{res.stdout}\n{res.stderr}"
    assert "bad_frees=0" in res.stdout, f"Unexpected bad frees in smoke:\n{res.stdout}"
    assert "live_bytes=0" in res.stdout or "MEMCHECK" in res.stdout, res.stdout
    print("[PASS] MC2. Interactive PTY smoke session (nav + F3 viewer + quit) passes memcheck")


def test_leak_and_badfree_reporting():
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as tf:
        log_path = tf.name
        # Grab a real symbol address from duop_memcheck via nm
        nm = subprocess.check_output(["nm", os.path.join(ROOT, "duop_memcheck")], text=True)
        addr = None
        for ln in nm.splitlines():
            parts = ln.split()
            if len(parts) == 3 and parts[2] == "mem_alloc":
                addr = "0x" + parts[0]
                break
        assert addr is not None, "Could not find mem_alloc symbol in duop_memcheck"
        tf.write(f"MC_BADFREE ptr=0xdeadbeef caller={addr}\n")
        tf.write(f"MC_LEAK ptr=0x12340000 size=128 caller={addr} seq=1\n")
        tf.write("MC_SUMMARY allocs=1 frees=0 live=1 live_bytes=128 peak_bytes=128 bad_frees=1\n")
    try:
        res = subprocess.run(
            [sys.executable, SCRIPT, "--parse-log", log_path],
            cwd=ROOT, capture_output=True, text=True, timeout=10,
        )
        assert res.returncode != 0, "Expected non-zero exit when leaks/bad_frees exist"
        assert "128" in res.stdout and "memory.s" in res.stdout, (
            f"Expected resolved memory.s location in report:\n{res.stdout}"
        )
        print("[PASS] MC3. Leak & bad-free log parser resolves caller RIP to .s file:line via addr2line")
    finally:
        os.unlink(log_path)


if __name__ == "__main__":
    test_cli_flags_zero_leaks()
    test_pty_smoke_session()
    test_leak_and_badfree_reporting()
    print("ALL MEMCHECK TESTS PASSED.")
