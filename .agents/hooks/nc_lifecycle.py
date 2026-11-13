#!/usr/bin/env python3
"""Antigravity lifecycle hook handler for NeoCommander (.agents/hooks.json)."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
CODE_PATH_PREFIXES = ("src/", "include/")
VERIFY_RELEVANT_FILES = ("Makefile", "VERSION", "tests/test_pty.py")


def resolve_repo_root(payload: dict) -> Path:
    candidates: list[Path] = []
    for p in payload.get("workspacePaths") or []:
        candidates.append(Path(p))
    if payload.get("cwd"):
        candidates.append(Path(payload["cwd"]))
    candidates.append(Path(__file__).resolve().parents[2])

    for cand in candidates:
        cur = cand.resolve()
        for parent in (cur, *cur.parents):
            if (parent / ".git").exists() and (parent / "Makefile").is_file():
                return parent
    return Path(__file__).resolve().parents[2]


def run_git(root: Path, *args: str) -> tuple[int, str]:
    res = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    return res.returncode, res.stdout.rstrip()


def state_file_for(payload: dict, root: Path) -> Path:
    cid = str(payload.get("conversationId") or "default")
    safe_cid = re.sub(r"[^A-Za-z0-9_-]", "_", cid)[:64]
    repo_tag = re.sub(r"[^A-Za-z0-9_-]", "_", root.name)[:24]
    return Path(f"/tmp/nc-agy-state-{repo_tag}-{safe_cid}.json")


def load_state(path: Path) -> dict:
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    return {"modified_files": [], "edited_code": False, "edited_any": False, "needs_verify": False}


def save_state(path: Path, state: dict) -> None:
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def to_rel_repo_path(raw_path: str, root: Path) -> str | None:
    if not raw_path:
        return None
    p = Path(raw_path)
    if not p.is_absolute():
        p = root / p
    try:
        return p.resolve().relative_to(root.resolve()).as_posix()
    except Exception:
        return None


def is_verify_relevant(rel_path: str) -> bool:
    return (
        rel_path.startswith(CODE_PATH_PREFIXES)
        or rel_path in VERIFY_RELEVANT_FILES
        or rel_path.startswith("tests/")
    )


def handle_session_start(payload: dict, root: Path) -> dict:
    ver_file = root / "VERSION"
    ver = ver_file.read_text(encoding="utf-8").strip() if ver_file.is_file() else "unknown"
    _, branch = run_git(root, "branch", "--show-current")
    _, head = run_git(root, "rev-parse", "--short", "HEAD")
    _, tag = run_git(root, "describe", "--tags", "--abbrev=0")
    _, dirty = run_git(root, "status", "--short")
    dirty_count = len([l for l in dirty.splitlines() if l.strip()]) if dirty else 0
    _, hooks_path = run_git(root, "config", "core.hooksPath")

    msg = (
        f"[NeoCommander Workspace] VERSION={ver} | branch={branch or 'detached'} ({head or 'unborn'}) "
        f"| latest_tag={tag or 'none'} | dirty_files={dirty_count} | git_hooks={hooks_path or 'default'}.\n"
        "Use workspace rules in AGENTS.md and skills in .agents/skills/: "
        "nc-modular-asm, nc-ui-i18n-widget, nc-pty-verify, nc-version-release. "
        "Verify with ./.agents/skills/nc-pty-verify/scripts/verify_build.sh, maintain SemVer in VERSION, "
        "and commit after verified changes."
    )
    return {"injectSteps": [{"systemMessage": {"systemMessage": msg}}]}


def handle_pre_tool_use(payload: dict, root: Path) -> dict:
    tool_call = payload.get("toolCall") or {}
    name = str(tool_call.get("name") or "")
    args = tool_call.get("args") or {}

    if name in ("write_file", "edit_file"):
        raw_path = str(
            args.get("Path") or args.get("path") or args.get("TargetFile") or ""
        )
        rel = to_rel_repo_path(raw_path, root)
        if rel:
            if (
                rel == "nc"
                or rel.startswith("build/")
                or rel.startswith(".git/")
                or rel.endswith(".o")
            ):
                return {
                    "decision": "deny",
                    "reason": f"'{rel}' is a generated artifact or internal Git metadata; edit sources instead.",
                }
            if rel == "VERSION" and name == "write_file":
                content = str(args.get("Content") or "").strip()
                if not SEMVER_RE.match(content):
                    return {
                        "decision": "deny",
                        "reason": f"Invalid SemVer '{content}' for VERSION; expected X.Y.Z (e.g. 1.0.1).",
                    }
        return {"decision": "allow"}

    if name == "run_command":
        import shlex

        cmd = str(args.get("CommandLine") or args.get("command") or "")
        for segment in re.split(r"(?:&&|\|\||[;\n|])", cmd):
            try:
                toks = shlex.split(segment)
            except ValueError:
                toks = segment.split()
            if not toks or Path(toks[0]).name != "git":
                continue
            # Locate git subcommand (skip git global options like -C <dir>)
            subcmd = None
            idx = 1
            while idx < len(toks):
                t = toks[idx]
                if t in ("-C", "-c", "--git-dir", "--work-tree"):
                    idx += 2
                    continue
                if t.startswith("-"):
                    idx += 1
                    continue
                subcmd = t
                break
            if subcmd == "commit":
                if any(t == "--no-verify" or re.match(r"^-[A-Za-z]*n[A-Za-z]*$", t) for t in toks[idx + 1 :]):
                    return {
                        "decision": "deny",
                        "reason": "Bypassing Git pre-commit/commit-msg hooks (--no-verify) violates NeoCommander quality rules.",
                    }
                if os.environ.get("NC_ALLOW_UNCONFIGURED_HOOKS") != "1":
                    _, hooks_path = run_git(root, "config", "core.hooksPath")
                    if (root / ".githooks/pre-commit").is_file() and hooks_path != ".githooks":
                        return {
                            "decision": "deny",
                            "reason": "Git hooks are not active (core.hooksPath != .githooks). Run 'make hooks' first.",
                        }
        return {"decision": "allow"}

    return {"decision": "allow"}


def handle_post_tool_use(payload: dict, root: Path) -> dict:
    tool_call = payload.get("toolCall") or {}
    name = str(tool_call.get("name") or "")
    args = tool_call.get("args") or {}
    error = payload.get("error")

    spath = state_file_for(payload, root)
    state = load_state(spath)

    if name in ("write_file", "edit_file") and not error:
        raw_path = str(
            args.get("Path") or args.get("path") or args.get("TargetFile") or ""
        )
        rel = to_rel_repo_path(raw_path, root)
        if rel:
            files = list(state.get("modified_files") or [])
            if rel not in files:
                files.append(rel)
            state["modified_files"] = files
            state["edited_any"] = True
            state["stop_nudged_sig"] = ""
            if is_verify_relevant(rel):
                state["edited_code"] = True
                state["needs_verify"] = True
            save_state(spath, state)

    elif name == "run_command" and not error:
        cmd = str(args.get("CommandLine") or args.get("command") or "")
        if re.search(r"(?:verify_build\.sh|\bmake\b[^\n]*\bverify\b|\bmake\b[^\n]*\btest\b|test_pty\.py)", cmd):
            state["needs_verify"] = False
            state["stop_nudged_sig"] = ""
            save_state(spath, state)
        if re.search(r"\bgit\b[^\n]*\bcommit\b", cmd):
            _, dirty = run_git(root, "status", "--porcelain", "--untracked-files=all")
            dirty_paths = parse_porcelain_paths(dirty)
            remaining = [f for f in (state.get("modified_files") or []) if f in dirty_paths]
            state["modified_files"] = remaining
            if not remaining:
                state["edited_code"] = False
                state["edited_any"] = False
            save_state(spath, state)

    return {}


def parse_porcelain_paths(status_out: str) -> set[str]:
    paths: set[str] = set()
    for line in status_out.splitlines():
        if len(line) < 4:
            continue
        p = line[3:].strip()
        if " -> " in p:
            p = p.split(" -> ", 1)[1].strip()
        if p:
            paths.add(p)
    return paths


def handle_stop(payload: dict, root: Path) -> dict:
    if os.environ.get("NC_SKIP_STOP_HOOK") == "1":
        return {"decision": "allow"}
    if payload.get("terminationReason") != "NO_TOOL_CALL":
        return {"decision": "allow"}
    if payload.get("continuationActive"):
        return {"decision": "allow"}
    if payload.get("fullyIdle") is False:
        return {"decision": "allow"}

    spath = state_file_for(payload, root)
    state = load_state(spath)
    if not state.get("edited_any"):
        return {"decision": "allow"}

    _, dirty_out = run_git(root, "status", "--porcelain", "--untracked-files=all")
    dirty_paths = parse_porcelain_paths(dirty_out)
    session_files = set(state.get("modified_files") or [])
    uncommitted_session = sorted(dirty_paths & session_files)
    # Also detect if a script generated/modified tracked session files outside write_file
    dirty_code = sorted(p for p in dirty_paths if is_verify_relevant(p))

    if uncommitted_session or (state.get("edited_code") and dirty_code) or state.get("needs_verify"):
        targets = uncommitted_session or dirty_code
        sig = json.dumps({"targets": targets, "needs_verify": bool(state.get("needs_verify"))}, sort_keys=True)
        if state.get("stop_nudged_sig") == sig:
            return {"decision": "allow"}
        state["stop_nudged_sig"] = sig
        save_state(spath, state)

        if state.get("needs_verify"):
            return {
                "decision": "continue",
                "reason": (
                    "У цій сесії змінено код, конфіг збірки, VERSION або тести NeoCommander, але перевірка "
                    "ще не виконана після останньої правки. Запусти ./.agents/skills/nc-pty-verify/scripts/verify_build.sh, "
                    "перевір VERSION згідно з nc-version-release та закоміть перевірені зміни."
                ),
            }

        sample = ", ".join(targets[:6])
        return {
            "decision": "continue",
            "reason": (
                f"Перевірені зміни ({sample}) ще не зафіксовані в Git. "
                "Перевір SemVer у VERSION (за потреби онови через bump_version.py) та виконай git commit "
                "(або коротко поясни користувачеві, якщо коміт свідомо відкладено)."
            ),
        }

    return {"decision": "allow"}


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        print("{}")
        return 0

    event = payload.get("hookEventName", "")
    root = resolve_repo_root(payload)

    if event == "SessionStart":
        out = handle_session_start(payload, root)
    elif event == "PreToolUse":
        out = handle_pre_tool_use(payload, root)
    elif event == "PostToolUse":
        out = handle_post_tool_use(payload, root)
    elif event == "Stop":
        out = handle_stop(payload, root)
    else:
        out = {}

    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
