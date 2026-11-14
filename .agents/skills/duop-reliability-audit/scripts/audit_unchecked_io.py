#!/usr/bin/env python3
"""Ignored results of data-changing operations in data-safety modules.

A write / rename / unlink / chmod / truncate whose result is not tested before the next call,
syscall, return or jump can silently lose data (short write on ENOSPC, rename onto an existing
file that failed, ...). Reported per site; cleanup of private temporary files is the usual
false positive and is marked as such when the routine name says so.
"""

from __future__ import annotations

import re
import sys

from asm_index import ROOT, rel, routines

MODULES = ("src/fs/file_ops", "src/fs/task", "src/fs/trash_undo", "src/fs/pkg_manager",
           "src/fs/archive_extract", "src/fs/nav_state", "src/fs/pkg_archive", "src/core/config")
OPS = ("OS_WRITE", "call sys_write_all", "OS_RENAMEAT", "call fs_rename", "OS_UNLINKAT",
       "OS_FCHMODAT", "OS_FTRUNCATE", "call os_copy_file_range", "OS_LINKAT", "OS_SYMLINKAT")
CHECK_RE = re.compile(r"^(?:test|cmp)\s+(?:rax|eax)\b")
BARRIER_RE = re.compile(r"^(?:call|ret|jmp|OS_[A-Z_]+|syscall)\b")
CLEANUP_HINT = ("clean", "cleanup", "free", "close", "abort", "err", "fail", "undo", "tmp")


def main() -> int:
    findings = []
    files = sorted(p for m in MODULES for p in ROOT.glob(m + "*.s"))
    for p in files:
        for name, _, body in routines(p):
            for i, (ln, ins) in enumerate(body):
                op = next((o for o in OPS if ins.startswith(o)), None)
                if not op:
                    continue
                checked = False
                for _, nxt in body[i + 1:i + 8]:
                    if nxt.startswith("mov") and re.search(r",\s*(?:rax|eax)$", nxt):
                        checked = True          # result saved for a later test
                        break
                    if CHECK_RE.match(nxt) or nxt.startswith("push rax"):
                        checked = True          # tested, or saved across a call
                        break
                    if nxt == "ret" or nxt.startswith("jmp .L") and "_ret" in nxt:
                        checked = True          # propagated to the caller in rax
                        break
                    if re.match(r"^(?:mov|xor|lea|movzx|movsxd|pop)\s+(?:rax|eax)\b", nxt):
                        break                   # overwritten unchecked
                    if BARRIER_RE.match(nxt):
                        break
                if not checked:
                    tag = " (cleanup path?)" if any(h in name.lower() for h in CLEANUP_HINT) else ""
                    findings.append(f"{rel(p)}:{ln}: {name}: result of '{op}' ignored{tag}")
    for f in findings:
        print("WARN:", f)
    print(f"UNCHECKED-IO AUDIT: {len(findings)} ignored results in {len(files)} data-safety modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
