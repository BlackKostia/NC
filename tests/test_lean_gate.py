#!/usr/bin/env python3
"""Self-test of the duop-lean-modules gate (checker + agent hook integration)."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / ".agents/skills/duop-lean-modules/scripts/check_lean.py"
sys.path.insert(0, str(ROOT / ".agents/hooks"))
import duop_lifecycle as dl  # noqa: E402


def run(*args, stdin=None):
    return subprocess.run([sys.executable, str(CHECK), *args], input=stdin, text=True,
                          capture_output=True, check=False)


def asm(n_lines: int, routine_len: int = 10) -> str:
    body = [".intel_syntax noprefix", ".section .text", ".global f", "f:"]
    body += ["    nop"] * (routine_len - 1)
    body.append(".section .rodata")
    while len(body) < n_lines:
        body.append("    .byte 0")
    return "\n".join(body) + "\n"


def main() -> None:
    scope = ["--staged"] if os.environ.get("DUOP_LEAN_STAGED") else []
    res = run("--root", str(ROOT), *scope)
    assert res.returncode == 0, f"Real tree violates lean budgets:\n{res.stderr}"
    print("[PASS] L1. Current tree respects module/routine/API budgets (ratchet baseline)")

    res = run("--root", str(ROOT), "--file", "src/core/new_mod.s", "--text-from", "-", stdin=asm(401))
    assert res.returncode == 1 and "401 lines > 400" in res.stderr, res.stderr
    res = run("--root", str(ROOT), "--file", "src/core/new_mod.s", "--text-from", "-", stdin=asm(400))
    assert res.returncode == 0, res.stderr
    res = run("--root", str(ROOT), "--file", "src/core/new_mod.s", "--text-from", "-", stdin=asm(200, 81))
    assert res.returncode == 1 and "new_mod.s:f: 81 lines > 80" in res.stderr, res.stderr
    exports = ".intel_syntax noprefix\n" + "".join(f".global g{i}\n" for i in range(17))
    res = run("--root", str(ROOT), "--file", "src/core/api.s", "--text-from", "-", stdin=exports)
    assert res.returncode == 1 and "17 exported symbols > 16" in res.stderr, res.stderr
    print("[PASS] L2. Budgets: 400-line module, 80-line routine, 16 exports (boundaries exact)")

    base = json.loads((ROOT / ".agents/skills/duop-lean-modules/scripts/lean_baseline.json").read_text())
    if base["files"]:
        rp, frozen = next(iter(sorted(base["files"].items())))
        res = run("--root", str(ROOT), "--file", rp, "--text-from", "-", stdin=asm(frozen + 1))
        assert res.returncode == 1 and "frozen legacy size" in res.stderr, res.stderr
        print(f"[PASS] L3. Ratchet: legacy {rp} may not grow beyond {frozen} lines")

    with tempfile.TemporaryDirectory() as tmp:
        payload = {"hookEventName": "PreToolUse", "conversationId": "lean-selftest", "cwd": str(ROOT),
                   "toolCall": {"name": "write_file",
                                "args": {"Path": str(ROOT / "src/core/huge_new.s"), "Content": asm(900)}}}
        os.environ["DUOP_TDD_BYPASS"] = "1"
        out = dl.handle_pre_tool_use(payload, ROOT)
        assert out.get("decision") == "deny" and "Lean-module gate" in out.get("reason", ""), out
        payload["toolCall"]["args"]["Content"] = asm(100)
        assert dl.handle_pre_tool_use(payload, ROOT).get("decision") == "allow"
        del tmp
    print("[PASS] L4. Agent PreToolUse hook denies oversized writes, allows lean ones")
    print("ALL LEAN-GATE TESTS PASSED.")


if __name__ == "__main__":
    main()
