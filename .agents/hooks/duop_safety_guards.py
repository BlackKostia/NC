#!/usr/bin/env python3
"""Static & faultlab safety guards for Duop PreToolUse / PostToolUse hooks."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ALLOC_OR_OS_RE = re.compile(
    r"\b(?:call\s+(?:mem_alloc|mem_realloc|[A-Za-z0-9_]+_new)\b|"
    r"OS_(?:OPENAT|READ|WRITE|PIPE2|FORK|MMAP[A-Z_]*|RENAMEAT2?|UNLINKAT))\b"
)
RESULT_CHECK_RE = re.compile(
    r"\b(?:test\s+(?:r|e)ax|cmp\s+(?:r|e)ax|js|jns|jz|jnz|je|jne|jae|jb|jle|jg|"
    r"SCOPED_MEM_SET|USING_FD_SET)\b"
)
DESTRUCTIVE_RE = re.compile(r"\b(?:OS_RENAMEAT2?|O_TRUNC)\b")
SAFE_OVERWRITE_RE = re.compile(
    r"\b(?:RENAME_NOREPLACE|O_EXCL|O_NOFOLLOW)\b|#\s*(?:safe-overwrite|atomic-replace)"
)
PATH_CALL_RE = re.compile(r"\bcall\s+(?:path_join|str_copy|str_cat)\b")
PATH_CHECK_RE = re.compile(
    r"\b(?:PATH_MAX|str_len|cmp\s+|jae|ja|jb|jbe|jl|jg)\b|#\s*path-checked"
)


def _split_insns(text: str) -> list[str]:
    out: list[str] = []
    for raw in text.splitlines():
        for part in raw.split(";"):
            s = part.strip()
            if s:
                out.append(s)
    return out


def check_pre_tool_asm_guards(rel_path: str, added_text: str) -> str | None:
    """Enforce error-check, destructive-op, and path-truncation guards on new asm."""
    if os.environ.get("DUOP_SAFETY_BYPASS") == "1":
        return None
    if not (rel_path.startswith("src/") and rel_path.endswith(".s")):
        return None

    insns = _split_insns(added_text)
    for i, line in enumerate(insns):
        code = line.split("#", 1)[0].strip()
        if not code or code.endswith(":"):
            continue
        window = "\n".join(insns[max(0, i - 3) : min(len(insns), i + 6)])

        if ALLOC_OR_OS_RE.search(code) and "# fault-checked" not in line:
            after = "\n".join(insns[i + 1 : min(len(insns), i + 7)])
            if not RESULT_CHECK_RE.search(after):
                return (
                    f"Error-path guard (duop-error-path-contract) in {rel_path}: "
                    f"'{code}' has no result check within the next 6 instructions. "
                    "Check rax/eax (or annotate '# fault-checked' if intentionally void)."
                )

        if DESTRUCTIVE_RE.search(code) and not SAFE_OVERWRITE_RE.search(window):
            return (
                f"Destructive-op guard (duop-destructive-ops-guard) in {rel_path}: "
                f"'{code}' requires RENAME_NOREPLACE, O_EXCL, O_NOFOLLOW, or "
                "'# safe-overwrite' / '# atomic-replace' annotation."
            )

        if PATH_CALL_RE.search(code) and ("path" in window.lower() or "PATH_MAX" in window):
            if not PATH_CHECK_RE.search(window):
                return (
                    f"Path-safety guard (duop-path-safety) in {rel_path}: "
                    f"'{code}' on a path buffer without PATH_MAX/length/bounds check "
                    "(or '# path-checked')."
                )
    return None


C_DESTRUCTIVE_RE = re.compile(r"\bO_TRUNC\b|\bos_renameat2\s*\([^;]*,\s*0\s*\)")
C_SAFE_OVERWRITE_RE = re.compile(r"\b(?:RENAME_NOREPLACE|O_EXCL|O_NOFOLLOW)\b|/[*/]\s*(?:safe-overwrite|atomic-replace)")


def _c_audit_module(root: Path):
    """tools/faultlab/audit_null_alloc_c.py loaded by path (it is a script, not a package)."""
    import importlib.util

    path = root / "tools/faultlab/audit_null_alloc_c.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("audit_null_alloc_c", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def check_pre_tool_c_guards(root: Path, rel_path: str, added_text: str) -> str | None:
    """Same guarantees as the asm guards for freestanding C: unchecked allocations, destructive overwrites.

    Unchecked os_* / mem_alloc results and ignored path_join results are compile errors ([[nodiscard]] + -Werror), so the
    hook only adds what the compiler cannot see: a pointer from mem_alloc/*_new used before a NULL test, and O_TRUNC /
    renameat2 without a no-clobber flag."""
    if os.environ.get("DUOP_SAFETY_BYPASS") == "1":
        return None
    if not (rel_path.startswith("src/") and rel_path.endswith(".c")):
        return None
    mod = _c_audit_module(root)
    if mod is not None:
        found = mod.audit_text(added_text, rel_path)
        if found:
            return (
                f"Error-path guard (duop-error-path-contract / duop-oom-safety) in {rel_path}: {found[0]}. "
                "Test the pointer (`if (!p) return -ENOMEM;`) before the first use, or mark `/* null-ok */`."
            )
    lines = added_text.splitlines()
    for i, line in enumerate(lines):
        code = re.sub(r"/\*.*?\*/", "", line).split("//", 1)[0]
        if C_DESTRUCTIVE_RE.search(code):
            window = "\n".join(lines[max(0, i - 4) : i + 5])
            if not C_SAFE_OVERWRITE_RE.search(window):
                return (
                    f"Destructive-op guard (duop-destructive-ops-guard) in {rel_path}: '{code.strip()}' needs "
                    "RENAME_NOREPLACE, O_EXCL or O_NOFOLLOW nearby, or a `/* safe-overwrite */` / `/* atomic-replace */` comment."
                )
    return None


def run_post_tool_c_audits(root: Path, rel_path: str) -> str | None:
    """After an Edit of src/**/*.c: portability syntax gate (x86_64 + aarch64, real CFLAGS) and the null-alloc audit."""
    if not (rel_path.startswith("src/") and rel_path.endswith(".c")):
        return None
    notes: list[str] = []
    syntax = root / "tools/check_c_syntax.py"
    if syntax.is_file():
        try:
            res = subprocess.run([sys.executable, str(syntax), rel_path], cwd=root, capture_output=True, text=True, timeout=8, check=False)
            if res.returncode != 0:
                notes.append(f"[check_c_syntax]\n{(res.stderr or res.stdout).strip()[-900:]}")
        except subprocess.TimeoutExpired:
            notes.append("[check_c_syntax] timed out (>8s); run tools/check_c_syntax.py explicitly")
    audit = root / "tools/faultlab/audit_null_alloc_c.py"
    if audit.is_file():
        res = subprocess.run([sys.executable, str(audit), rel_path], cwd=root, capture_output=True, text=True, timeout=5, check=False)
        if res.returncode != 0:
            notes.append(f"[audit_null_alloc_c]\n{res.stdout.strip()}")
    return "\n".join(notes) if notes else None


def _scenario_for_path(rel_path: str) -> str | None:
    if not rel_path.startswith(("src/fs/", "src/core/", "src/os/")):
        return None
    if "delete" in rel_path:
        return "delete"
    if "conflict" in rel_path or "move" in rel_path:
        return "move"
    if "dir_" in rel_path or "du_" in rel_path:
        return "tree"
    if "file_ops" in rel_path or "archive" in rel_path or "inflate" in rel_path:
        return "copy"
    return "ui"


def run_post_tool_fault_audits(root: Path, rel_path: str) -> str | None:
    """Run audit_null_alloc.py, audit_stack_depth.py, and short campaign.py sweep."""
    if not (rel_path.startswith("src/") and rel_path.endswith(".s")):
        return None

    notes: list[str] = []
    null_audit = root / "tools/faultlab/audit_null_alloc.py"
    if null_audit.is_file():
        res = subprocess.run(
            [sys.executable, str(null_audit)],
            cwd=root, capture_output=True, text=True, timeout=3, check=False,
        )
        for ln in (res.stdout + res.stderr).splitlines():
            if rel_path in ln:
                notes.append(f"[audit_null_alloc] {ln}")

    stack_audit = root / "tools/faultlab/audit_stack_depth.py"
    if stack_audit.is_file() and (root / "duop").is_file():
        res = subprocess.run(
            [sys.executable, str(stack_audit)],
            cwd=root, capture_output=True, text=True, timeout=3, check=False,
        )
        if res.returncode != 0 and "no symbols" not in (res.stdout + res.stderr).lower():
            notes.append(f"[audit_stack_depth]\n{(res.stdout + res.stderr).strip()}")

    scenario = _scenario_for_path(rel_path)
    camp = root / "tools/faultlab/campaign.py"
    if scenario and camp.is_file() and os.environ.get("DUOP_SKIP_POST_CAMPAIGN") != "1":
        try:
            res = subprocess.run(
                [sys.executable, str(camp), "short", scenario],
                cwd=root, capture_output=True, text=True, timeout=4, check=False,
            )
            out = (res.stdout + res.stderr).strip()
            if res.returncode != 0 and any(
                tag in out for tag in ("CRASH_UI", "HANG", "DATA_LOSS", "SILENT_CORRUPTION")
            ):
                notes.append(f"[faultlab short {scenario}]\n{out[-600:]}")
        except subprocess.TimeoutExpired:
            notes.append(
                f"[faultlab] `campaign.py short {scenario}` timed out (>4s); run it explicitly before commit."
            )

    return "\n".join(notes) if notes else None
