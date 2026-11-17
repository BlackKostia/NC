#!/usr/bin/env python3
"""Self-test of the EN/UA i18n gate in the shared agent lifecycle hook, exercised through the
Claude Code adapter (.claude/hooks/claude_adapter.py) exactly as Claude Code calls it."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / ".claude/hooks/claude_adapter.py"
sys.path.insert(0, str(ROOT / ".agents/hooks"))
import duop_lifecycle as dl  # noqa: E402


def copy_repo(dst: Path) -> None:
    files = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    for rel in filter(None, files.decode().split("\0")):
        src = ROOT / rel
        if src.is_file():
            (dst / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst / rel)
    (dst / ".git").mkdir()                        # repo-root marker for resolve_repo_root


def post_edit(repo: Path, rel: str, session: str) -> dict:
    payload = {"hook_event_name": "PostToolUse", "session_id": session, "cwd": str(repo),
               "tool_name": "Edit", "tool_input": {"file_path": str(repo / rel)}}
    env = dict(os.environ, DUOP_LEAN_BYPASS="1")
    res = subprocess.run([sys.executable, str(ADAPTER)], input=json.dumps(payload), text=True,
                         capture_output=True, env=env, timeout=60, check=False)
    assert res.returncode == 0, res.stderr
    state = dl.state_file_for({"conversationId": session}, repo)
    state.unlink(missing_ok=True)
    return json.loads(res.stdout) if res.stdout.strip() else {}


def main() -> None:
    assert (ROOT / dl.MODULARITY_SCRIPT).is_file(), f"hook points to a missing script: {dl.MODULARITY_SCRIPT}"
    print("[PASS] H1. i18n gate runs the real check_modularity.py")

    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "repo"
        copy_repo(repo)
        out = post_edit(repo, "lang/uk.lang", "i18n-hook-ok")
        assert "i18n symmetry gate" not in out.get("reason", ""), out
        pack = repo / "lang/uk.lang"
        pack.write_text("".join(l for l in pack.read_text(encoding="utf-8").splitlines(True)
                                if not l.startswith("hdr_btn_help ")), encoding="utf-8")
        out = post_edit(repo, "lang/uk.lang", "i18n-hook-miss")
        assert out.get("decision") == "block" and "i18n symmetry gate" in out.get("reason", ""), out
        assert "hdr_btn_help" in out["reason"], out
        print("[PASS] H2. Claude PostToolUse: a key missing from lang/uk.lang blocks with the gate report")
        shutil.copy2(ROOT / "lang/uk.lang", pack)
        out = post_edit(repo, "src/ui/info_dialog.s", "i18n-hook-ui")
        assert out.get("decision") == "block" and "English (src/tui/i18n_en.lang)" in out.get("reason", ""), out
        print("[PASS] H3. Claude PostToolUse: UI edits get the EN + UA translation reminder")
    print("ALL I18N HOOK TESTS PASSED.")


if __name__ == "__main__":
    main()
