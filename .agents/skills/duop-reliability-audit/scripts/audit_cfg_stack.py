#!/usr/bin/env python3
"""Control-Flow Graph (CFG) Stack Balance Auditor for Duop x86-64 assembly.

Simulates stack depth (delta from routine entry) across basic blocks and
branches within each top-level routine in src/**/*.s, verifying that every
reachable `ret` returns with net stack depth == 0 (excluding the return address).
"""

from __future__ import annotations

import re
import sys
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_stack_abi import eval_expr, parse_includes, strip_comment  # noqa: E402

RE_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
RE_LOCAL = re.compile(r"^(\.L[A-Za-z0-9_]+|\d+):(.*)$")
RE_SUB_RSP = re.compile(r"^sub\s+rsp\s*,\s*(.+)$")
RE_ADD_RSP = re.compile(r"^add\s+rsp\s*,\s*(.+)$")
RE_PUSH = re.compile(r"^push\s+(?:r[a-z0-9]+|qword\b|byte\b|dword\b|\d+|0x[0-9a-fA-F]+)")
RE_POP = re.compile(r"^pop\s+r[a-z0-9]+\b")
RE_JMP = re.compile(r"^jmp\s+(\.L[A-Za-z0-9_]+|\d+[fb])\b")
RE_JCC = re.compile(r"^j(?!mp\b)[a-z]{1,4}\s+(\.L[A-Za-z0-9_]+|\d+[fb])\b")
RE_RET = re.compile(r"^ret\b")
RE_TAIL_JMP = re.compile(r"^jmp\s+([A-Za-z_][A-Za-z0-9_]*)\b")


def split_top_routines(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    routines: list[dict] = []
    cur = None
    in_text = False
    for idx, raw in enumerate(lines, 1):
        code, _ = strip_comment(raw)
        s = code.strip()
        if s.startswith(".text") or s.startswith(".section .text"):
            in_text = True
            continue
        if s.startswith(".section ") and ".text" not in s or s in (".rodata", ".bss", ".data"):
            in_text = False
            cur = None
            continue
        if not in_text or not s:
            continue
        ml = RE_LABEL.match(s)
        if ml and not ml.group(1).startswith(".L") and not ml.group(1).startswith("."):
            name = ml.group(1)
            cur = {"name": name, "start_line": idx, "stmts": [], "is_step": "__" in name}
            routines.append(cur)
        elif cur is not None:
            for part in [p.strip() for p in s.split(";") if p.strip()]:
                cur["stmts"].append((idx, part))
    return routines


def audit_routine_cfg(rel: Path, rt: dict, consts: dict[str, int]) -> list[str]:
    stmts = rt["stmts"]
    if not stmts or rt["is_step"] or rt["name"] == "_start":
        return []
    # Skip routines with conditional .ifdef/.if or dynamic alloca/lea rsp
    raw_joined = "\n".join(s for _, s in stmts)
    if ".ifdef" in raw_joined or ".if " in raw_joined or "lea rsp" in raw_joined or "and rsp" in raw_joined:
        return []

    labels: dict[str, int] = {}
    num_labels: dict[str, list[int]] = {}
    flat: list[tuple[int, str]] = []
    for lineno, s in stmts:
        ml = RE_LOCAL.match(s)
        if ml:
            lbl, rest = ml.group(1), ml.group(2).strip()
            if lbl.isdigit():
                num_labels.setdefault(lbl, []).append(len(flat))
            else:
                labels[lbl] = len(flat)
            if rest:
                flat.append((lineno, rest))
        else:
            flat.append((lineno, s))

    if not flat:
        return []

    def resolve_target(tok: str, cur_idx: int) -> int | None:
        if tok in labels:
            return labels[tok]
        if len(tok) >= 2 and tok[-1] in ("f", "b") and tok[:-1].isdigit():
            positions = num_labels.get(tok[:-1], [])
            if tok[-1] == "f":
                for p in positions:
                    if p > cur_idx:
                        return p
            else:
                for p in reversed(positions):
                    if p <= cur_idx:
                        return p
        return None

    visited: dict[int, int] = {0: 0}
    q: deque[tuple[int, int]] = deque([(0, 0)])
    findings: list[str] = []

    while q:
        idx, depth = q.popleft()
        if idx >= len(flat):
            continue
        lineno, s = flat[idx]
        if "OS_EXIT" in s:
            continue
        if RE_RET.match(s):
            if depth != 0:
                findings.append(f"{rel}:{lineno} ({rt['name']}): `ret` reached with unbalanced stack depth={depth:+d}B")
            continue

        new_depth = depth
        if RE_PUSH.match(s):
            new_depth += 8
        elif RE_POP.match(s):
            new_depth -= 8
        else:
            ms = RE_SUB_RSP.match(s)
            if ms:
                v = eval_expr(ms.group(1), consts)
                if v is None:
                    continue
                new_depth += v
            else:
                ma = RE_ADD_RSP.match(s)
                if ma:
                    v = eval_expr(ma.group(1), consts)
                    if v is None:
                        continue
                    new_depth -= v

        mj = RE_JMP.match(s)
        if mj:
            tgt = resolve_target(mj.group(1), idx)
            if tgt is not None and tgt not in visited:
                visited[tgt] = new_depth
                q.append((tgt, new_depth))
            continue
        if RE_TAIL_JMP.match(s):
            tgt_name = RE_TAIL_JMP.match(s).group(1)
            # Child process entry jumps (e.g. pv_helper_main / task_worker_main after OS_FORK) never return
            if tgt_name.endswith("_main"):
                continue
            if new_depth != 0:
                findings.append(f"{rel}:{lineno} ({rt['name']}): tail `{s}` with unbalanced stack depth={new_depth:+d}B")
            continue

        mc = RE_JCC.match(s)
        if mc:
            tgt = resolve_target(mc.group(1), idx)
            if tgt is not None and tgt not in visited:
                visited[tgt] = new_depth
                q.append((tgt, new_depth))

        if idx + 1 < len(flat) and (idx + 1) not in visited:
            visited[idx + 1] = new_depth
            q.append((idx + 1, new_depth))

    return findings


def main() -> int:
    consts, _ = parse_includes()
    findings: list[str] = []
    s_files = sorted((ROOT / "src").rglob("*.s"))
    for p in s_files:
        rel = p.relative_to(ROOT)
        for rt in split_top_routines(p):
            findings.extend(audit_routine_cfg(rel, rt, consts))
    if findings:
        print(f"CFG STACK AUDIT FAILED ({len(findings)} issue(s)):")
        for f in findings:
            print(f"  - {f}")
        return 1
    print(f"CFG STACK AUDIT PASSED (checked {len(s_files)} .s files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
