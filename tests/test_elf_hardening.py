#!/usr/bin/env python3
"""ELF hardening of the built binary (audit 2026-11-16).

EH1 PT_GNU_STACK is present and not executable.  Without the header, kernels older than 5.8 start the process with
    READ_IMPLIES_EXEC, which makes every readable mapping (heap arenas, .bss, the stack) executable.
EH2 no segment is writable and executable at the same time; static, no interpreter, .data == 0
"""

import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.environ.get("DUOP", os.path.join(REPO_ROOT, "duop"))
AUDIT = os.path.join(REPO_ROOT, ".agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py")


def program_headers() -> list[str]:
    out = subprocess.run(["readelf", "-lW", BINARY], capture_output=True, text=True, check=True).stdout
    return [ln for ln in out.splitlines() if re.match(r"\s+[A-Z_]+\s+0x", ln)]


def test_gnu_stack_present_and_nx() -> None:
    stacks = [ln for ln in program_headers() if ln.split()[0] == "GNU_STACK"]
    assert len(stacks) == 1, "binary has no PT_GNU_STACK header (executable stack/heap on kernels < 5.8)"
    flags = " ".join(stacks[0].split()[6:-1])                     # "RW", "R E", "RWE"
    assert "W" in flags and "E" not in flags, f"GNU_STACK must be RW (non-executable), got {flags!r}: {stacks[0].strip()}"
    print("[PASS] EH1. PT_GNU_STACK present and non-executable")


def test_no_wx_segment_and_audit_passes() -> None:
    for ln in program_headers():
        if ln.split()[0] == "LOAD":
            assert "RWE" not in ln, f"writable+executable segment: {ln.strip()}"
    res = subprocess.run([sys.executable, AUDIT, BINARY], capture_output=True, text=True)
    assert res.returncode == 0, f"audit_elf_hardening failed:\n{res.stdout}{res.stderr}"
    print("[PASS] EH2. No W+X segment; audit_elf_hardening.py passes (requires GNU_STACK)")


def main() -> None:
    test_gnu_stack_present_and_nx()
    test_no_wx_segment_and_audit_passes()
    print("ALL ELF HARDENING TESTS PASSED.")


if __name__ == "__main__":
    main()
