#!/usr/bin/env python3
"""Static FD & -EINTR Resilience Auditor for Duop x86-64 assembly.

Checks:
  1. OS_OPENAT calls in src/**/*.s include O_CLOEXEC (prevents FD leaks across execve).
  2. OS_WAIT4 calls handle -EINTR retries.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def strip_comment(line: str) -> str:
    return line.split("#", 1)[0].strip()


def audit_file(path: Path) -> list[str]:
    findings: list[str] = []
    rel = path.relative_to(ROOT)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    window: list[str] = []

    for idx, raw in enumerate(lines, 1):
        s = strip_comment(raw)
        if not s:
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", s):
            window.clear()
            continue
        for stmt in [p.strip() for p in s.split(";") if p.strip()]:
            window.append(stmt)
            if len(window) > 8:
                window.pop(0)
            if stmt == "OS_OPENAT":
                ctx = " | ".join(window)
                # Skip __step wrappers (where edx is set in caller) and child dup2 redirects (/dev/null, pts)
                ahead = " | ".join(strip_comment(x) for x in lines[idx : min(len(lines), idx + 8)])
                is_dup2_redirect = "OS_DUP2" in ahead or "pal_pty.s" in str(rel)
                is_step_inherit = len(window) <= 2
                if not is_dup2_redirect and not is_step_inherit and "O_CLOEXEC" not in ctx:
                    if not any("mov edx, r" in w or "mov edx, e" in w or "mov edx, [" in w or "test " in w for w in window[-4:]):
                        findings.append(f"{rel}:{idx}: `OS_OPENAT` without `O_CLOEXEC` in flags setup")
            if stmt == "OS_WAIT4":
                ahead = " | ".join(strip_comment(x) for x in lines[idx : min(len(lines), idx + 6)])
                if "EINTR" not in ahead:
                    findings.append(f"{rel}:{idx}: `OS_WAIT4` without `-EINTR` retry check")
    return findings


def main() -> int:
    findings: list[str] = []
    s_files = sorted((ROOT / "src").rglob("*.s"))
    for p in s_files:
        findings.extend(audit_file(p))
    if findings:
        print(f"FD/EINTR AUDIT FAILED ({len(findings)} issue(s)):")
        for f in findings:
            print(f"  - {f}")
        return 1
    print(f"FD/EINTR AUDIT PASSED (checked {len(s_files)} .s files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
