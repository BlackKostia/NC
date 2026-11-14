#!/usr/bin/env python3
"""Insecure temporary files & verify-then-reopen races.

  ERROR  a fixed path under /tmp (.asciz "/tmp/...") that the same routine opens with O_CREAT
         without O_EXCL / O_NOFOLLOW, or hands to an external writer (curl -o / wget -O):
         symlink planting, clobbering between two Duop instances, cross-user leaks
  ERROR  a file is hashed / verified and then opened again by path (TOCTOU: the bytes that were
         checked are not the bytes that are used)
  WARN   any other fixed /tmp path (review: per-user private dir or O_EXCL + unique name)
"""

from __future__ import annotations

import re
import sys

from asm_index import ROOT, asciz, rel, routines, sources

TMP_RE = re.compile(r"^/tmp/")
OPEN_FLAGS_RE = re.compile(r"mov\s+edx\s*,\s*(.+)$")
VERIFY_CALLS = ("hash_file", "sha256_file", "pkg_verify_digest")
REOPEN_CALLS = ("pkg_load_archive", "fs_read_file_alloc", "OS_OPENAT", "os_mmap_file_ro")


def audit() -> tuple[list[str], list[str]]:
    errors, warns = [], []
    strings = asciz()
    tmp_labels = {lbl: v for lbl, v in strings.items() if TMP_RE.match(v[0])}
    used: set[str] = set()
    for p in sources():
        for name, line, body in routines(p):
            text = [ins for _, ins in body]
            refs = [lbl for lbl in tmp_labels if any(lbl in ins for ins in text)]
            for lbl in refs:
                used.add(lbl)
                path = tmp_labels[lbl][0]
                for i, (ln, ins) in enumerate(body):
                    if ins.startswith("OS_OPENAT"):
                        flags = next((OPEN_FLAGS_RE.search(b).group(1) for _, b in reversed(body[max(0, i - 6):i])
                                      if OPEN_FLAGS_RE.search(b)), "")
                        if "O_CREAT" in flags and "O_EXCL" not in flags and "O_NOFOLLOW" not in flags:
                            errors.append(f"{rel(p)}:{ln}: {name} creates fixed '{path}' with {flags.strip()} "
                                          "(no O_EXCL/O_NOFOLLOW)")
                if any("pkg_fetch_url" in ins or "curl" in ins or "wget" in ins for ins in text):
                    errors.append(f"{rel(p)}:{line}: {name} lets an external downloader write fixed '{path}'")
            # verify-then-reopen on the same register-held path
            ver = [i for i, (_, ins) in enumerate(body) if any(f"call {v}" in ins for v in VERIFY_CALLS)]
            for i in ver:
                later = [(ln, ins) for ln, ins in body[i + 1:] if any(r in ins for r in REOPEN_CALLS)]
                if later:
                    ln, ins = later[0]
                    errors.append(f"{rel(p)}:{ln}: {name} reopens the file by path after verifying it "
                                  f"(TOCTOU: '{ins}')")
    for lbl, (path, p, n) in sorted(tmp_labels.items()):
        warns.append(f"{rel(p)}:{n}: fixed temporary path '{path}' ({lbl})"
                     + ("" if lbl in used else " [unused]"))
    return errors, warns


def main() -> int:
    errors, warns = audit()
    for w in warns:
        print("WARN:", w)
    for e in errors:
        print("ERROR:", e)
    if errors:
        print(f"TMP-FILE AUDIT FAILED ({len(errors)} errors, {len(warns)} fixed /tmp paths)")
        return 1
    print(f"TMP-FILE AUDIT PASSED ({len(warns)} fixed /tmp paths to review)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
