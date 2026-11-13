#!/usr/bin/env python3
"""Claude Code adapter for the Antigravity lifecycle hook (.agents/hooks/duop_lifecycle.py).

Translates Claude Code hook payloads (stdin) into the Antigravity format, calls the
shared handlers, and translates their decisions back into Claude Code hook output.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".agents" / "hooks"))

import duop_lifecycle as dl  # noqa: E402

TOOL_MAP = {
    "Write": "write_file",
    "Edit": "edit_file",
    "MultiEdit": "edit_file",
    "NotebookEdit": "edit_file",
    "Bash": "run_command",
}


def to_agy(payload: dict) -> dict:
    tool = payload.get("tool_name") or ""
    tin = payload.get("tool_input") or {}
    name = TOOL_MAP.get(tool, tool)
    args: dict = {}
    if name in ("write_file", "edit_file"):
        args["Path"] = tin.get("file_path") or tin.get("notebook_path") or ""
        if tool == "Write":
            args["Content"] = tin.get("content") or ""
    elif name == "run_command":
        args["CommandLine"] = tin.get("command") or ""
    return {
        "hookEventName": payload.get("hook_event_name", ""),
        "conversationId": payload.get("session_id") or "default",
        "cwd": payload.get("cwd") or str(ROOT),
        "toolCall": {"name": name, "args": args},
        # Stop-hook fields expected by the shared handler
        "terminationReason": "NO_TOOL_CALL",
        "continuationActive": bool(payload.get("stop_hook_active")),
        "fullyIdle": True,
    }


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    event = payload.get("hook_event_name", "")
    agy = to_agy(payload)
    root = dl.resolve_repo_root(agy)
    out: dict = {}

    if event == "SessionStart":
        res = dl.handle_session_start(agy, root)
        steps = res.get("injectSteps") or []
        msgs = [
            (s.get("systemMessage") or {}).get("systemMessage", "")
            for s in steps
        ]
        ctx = "\n".join(m for m in msgs if m)
        if ctx:
            out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}

    elif event == "PreToolUse":
        res = dl.handle_pre_tool_use(agy, root)
        # Only deny is forwarded; "allow" is not, so normal permission prompts still apply.
        if res.get("decision") == "deny":
            out = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": res.get("reason", ""),
                }
            }

    elif event == "PostToolUse":
        dl.handle_post_tool_use(agy, root)

    elif event == "Stop":
        res = dl.handle_stop(agy, root)
        if res.get("decision") == "continue":
            out = {"decision": "block", "reason": res.get("reason", "")}

    if out:
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
