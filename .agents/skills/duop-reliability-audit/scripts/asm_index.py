#!/usr/bin/env python3
"""Shared helpers for Duop assembly audits: routine splitting, call graph and .asciz strings."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
LABEL_RE = re.compile(r"^([A-Za-z_][\w.$]*):")
CALL_RE = re.compile(r"\b(?:call|jmp)\s+([A-Za-z_][\w$]*)\b")
ASCIZ_RE = re.compile(r'^([A-Za-z_][\w.$]*):\s*\.asciz\s+"((?:[^"\\]|\\.)*)"')


def code(line: str) -> str:
    """Strip comments and string literals (keeps instruction text)."""
    out, q = [], False
    for i, ch in enumerate(line):
        if ch == '"' and (i == 0 or line[i - 1] != "\\"):
            q = not q
            continue
        if not q and ch == "#":
            break
        if not q:
            out.append(ch)
    return "".join(out)


def instructions(line: str) -> list[str]:
    """One source line may hold several `;`-separated instructions."""
    return [p.strip() for p in code(line).split(";") if p.strip()]


def sources(root: Path = ROOT, sub: str = "src") -> list[Path]:
    return sorted(p for p in (root / sub).rglob("*.s") if "/aarch64/" not in p.as_posix())


def routines(path: Path) -> list[tuple[str, int, list[tuple[int, str]]]]:
    """Top-level routines (non-.L labels) with their (line_no, instruction) bodies."""
    out, cur, start, body = [], None, 0, []
    for n, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        m = LABEL_RE.match(raw)
        if m and not m.group(1).startswith(".L") and not raw.lstrip().startswith("."):
            if cur:
                out.append((cur, start, body))
            cur, start, body = m.group(1), n, []
            rest = raw[m.end():]
            body.extend((n, ins) for ins in instructions(rest))
            continue
        if cur:
            body.extend((n, ins) for ins in instructions(raw))
    if cur:
        out.append((cur, start, body))
    return out


def call_graph(root: Path = ROOT) -> tuple[dict[str, set[str]], dict[str, tuple[Path, int]]]:
    graph: dict[str, set[str]] = {}
    where: dict[str, tuple[Path, int]] = {}
    for p in sources(root):
        for name, line, body in routines(p):
            callees = graph.setdefault(name, set())
            where.setdefault(name, (p, line))
            for _, ins in body:
                m = CALL_RE.search(ins)
                if m and not m.group(1).startswith(".L"):
                    callees.add(m.group(1))
    return graph, where


def asciz(root: Path = ROOT) -> dict[str, tuple[str, Path, int]]:
    out = {}
    for p in sources(root):
        for n, raw in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = ASCIZ_RE.match(raw.strip())
            if m:
                out[m.group(1)] = (m.group(2), p, n)
    return out


def rel(p: Path, root: Path = ROOT) -> str:
    return p.relative_to(root).as_posix()
