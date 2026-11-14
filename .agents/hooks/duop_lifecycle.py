#!/usr/bin/env python3
"""Antigravity lifecycle hook handler for Duop (.agents/hooks.json)."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
CODE_PATH_PREFIXES = ("src/", "include/")
VERIFY_RELEVANT_FILES = ("Makefile", "VERSION", "tests/test_pty.py")
LEAN_SUFFIXES = (".s", ".inc", ".py")
LEAN_SCRIPT = Path(".agents/skills/duop-lean-modules/scripts/check_lean.py")
MODULARITY_SCRIPT = Path(".agents/skills/duop-modular-asm/scripts/check_modularity.py")
RELIABILITY_SCRIPT = Path(".agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py")
I18N_PATHS = ("src/ui/", "src/tui/", "src/app/", "include/types.inc", "lang/uk.lang")


def lean_target(rel_path: str) -> bool:
    return rel_path.endswith(LEAN_SUFFIXES) and (
        rel_path.startswith(("src/", "include/")) or (rel_path.startswith("tests/") and rel_path.count("/") == 1)
    )


def lean_check(root: Path, rel_path: str, content: str | None = None) -> str:
    """Run the duop-lean-modules gate on one file; returns violation text ('' = ok)."""
    script = root / LEAN_SCRIPT
    if not script.is_file() or os.environ.get("DUOP_LEAN_BYPASS") == "1":
        return ""
    cmd = [sys.executable, str(script), "--root", str(root), "--file", rel_path]
    if content is not None:
        cmd += ["--text-from", "-"]
    try:
        res = subprocess.run(cmd, input=content, text=True, capture_output=True, timeout=4, check=False)
    except Exception:
        return ""
    return res.stderr.strip() if res.returncode != 0 else ""


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
    return Path(f"/tmp/duop-agy-state-{repo_tag}-{safe_cid}.json")


def load_state(path: Path) -> dict:
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    return {
        "modified_files": [],
        "edited_code": False,
        "edited_any": False,
        "tests_edited": False,
        "needs_verify": False,
    }


def is_test_path(rel_path: str) -> bool:
    return rel_path.startswith("tests/") and rel_path.endswith(".py")


def has_session_or_dirty_tests(root: Path, state: dict) -> bool:
    if state.get("tests_edited"):
        return True
    rc, out = run_git(root, "status", "--porcelain", "--untracked-files=all", "tests")
    if rc == 0:
        for p in parse_porcelain_paths(out):
            if is_test_path(p):
                return True
    return False


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
        f"[Duop Workspace] VERSION={ver} | branch={branch or 'detached'} ({head or 'unborn'}) "
        f"| latest_tag={tag or 'none'} | dirty_files={dirty_count} | git_hooks={hooks_path or 'default'}.\n"
        "Use workspace rules in AGENTS.md and skills in .agents/skills/: "
        "duop-tdd-first, duop-modular-asm, duop-lean-modules, duop-multiplatform-pal, duop-ui-i18n-widget, duop-pty-verify, duop-version-release. "
        "Keep modules lean: .s <= 400 lines, routines <= 80 lines, exports <= 16 (duop-lean-modules gate). "
        "Always design & write tests under tests/ before editing src/ or include/. "
        "Verify with ./.agents/skills/duop-pty-verify/scripts/verify_build.sh, maintain SemVer in VERSION, "
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
                rel in ("duop", "nc")
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
                        "reason": f"Invalid SemVer '{content}' for VERSION; expected X.Y.Z (e.g. 1.0.2).",
                    }
            if name == "write_file" and lean_target(rel):
                problems = lean_check(root, rel, str(args.get("Content") or ""))
                if problems:
                    return {
                        "decision": "deny",
                        "reason": (
                            "Lean-module gate (duop-lean-modules): " + problems.replace("LEAN: ", "")
                            + " Split the code into focused modules/helpers instead of growing this file."
                        ),
                    }
            if rel.startswith(CODE_PATH_PREFIXES) and os.environ.get("DUOP_TDD_BYPASS") != "1":
                spath = state_file_for(payload, root)
                state = load_state(spath)
                if not has_session_or_dirty_tests(root, state):
                    return {
                        "decision": "deny",
                        "reason": (
                            f"TDD-first gate (duop-tdd-first): create or update tests under tests/ before editing '{rel}'. "
                            "Write happy-path and fault/edge assertions first (or set DUOP_TDD_BYPASS=1 only for pure non-functional refactors)."
                        ),
                    }
        return {"decision": "allow"}

    if name == "run_command":
        cmd = str(args.get("CommandLine") or args.get("command") or "")
        for segment in re.split(r"(?:&&|\|\||[;\n|])", cmd):
            try:
                toks = shlex.split(segment)
            except ValueError:
                toks = segment.split()
            if not toks or Path(toks[0]).name != "git":
                continue
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
                        "reason": "Bypassing Git pre-commit/commit-msg hooks (--no-verify) violates Duop quality rules.",
                    }
                if os.environ.get("DUOP_ALLOW_UNCONFIGURED_HOOKS", os.environ.get("NC_ALLOW_UNCONFIGURED_HOOKS")) != "1":
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
            if is_test_path(rel):
                state["tests_edited"] = True
            if is_verify_relevant(rel):
                state["edited_code"] = True
                state["needs_verify"] = True
            if rel.startswith("docs/") or rel in ("README.md", "README.uk.md", "ROADMAP.md"):
                state["docs_edited"] = True
            save_state(spath, state)
            if rel.startswith(I18N_PATHS):
                mod_script = root / MODULARITY_SCRIPT
                if mod_script.is_file():
                    proc = subprocess.run(
                        [sys.executable, str(mod_script), "--root", str(root)],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    if proc.returncode != 0 and ("i18n" in (proc.stdout + proc.stderr).lower() or "lang" in (proc.stdout + proc.stderr).lower()):
                        return {
                            "feedback": (
                                "i18n symmetry gate (EN + UA) failed after editing " + rel + ":\n"
                                + (proc.stdout + proc.stderr).strip()
                                + "\nUpdate include/types.inc, src/tui/i18n.s (EN), src/tui/i18n_keys.s, and lang/uk.lang (UA) together."
                            )
                        }
                if rel.startswith(("src/ui/", "src/app/")) and not any(
                    f in ("src/tui/i18n.s", "lang/uk.lang") for f in state.get("modified_files") or []
                ) and not state.get("i18n_reminded"):
                    state["i18n_reminded"] = True
                    save_state(spath, state)
                    return {
                        "feedback": (
                            "UI/App file edited (" + rel + "): ensure any new or changed user-visible text "
                            "is immediately translated into both default project languages — English (src/tui/i18n.s) "
                            "and Ukrainian (lang/uk.lang), with matching keys in include/types.inc and src/tui/i18n_keys.s."
                        )
                    }
            if lean_target(rel) and (root / rel).is_file():
                problems = lean_check(root, rel)
                if problems:
                    return {
                        "feedback": (
                            "Lean-module gate (duop-lean-modules) violated by this edit:\n" + problems
                            + "\nRefactor now: extract helpers / move a cohesive part into a new module."
                        )
                    }
                script = root / LEAN_SCRIPT
                if script.is_file():
                    subprocess.run(
                        [sys.executable, str(script), "--root", str(root), "--update"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
            if rel.startswith(("src/", "include/")) and rel.endswith((".s", ".inc")):
                for rscript_name in ("audit_stack_abi.py", "audit_cfg_stack.py", "audit_syscall_clobber.py", "audit_oop_vtables.py", "audit_fd_eintr.py"):
                    rel_script = root / ".agents/skills/duop-reliability-audit/scripts" / rscript_name
                    if rel_script.is_file():
                        rproc = subprocess.run(
                            [sys.executable, str(rel_script)],
                            capture_output=True,
                            text=True,
                            timeout=4,
                            check=False,
                        )
                        if rproc.returncode != 0:
                            return {
                                "feedback": (
                                    "Reliability audit (duop-reliability-audit/" + rscript_name + ") failed after editing " + rel + ":\n"
                                    + (rproc.stdout + rproc.stderr).strip()
                                )
                            }
            if (
                rel.startswith(("src/app/", "src/ui/", "src/fs/pkg_", "src/main.s"))
                and not state.get("docs_edited")
                and not state.get("docs_reminded")
            ):
                state["docs_reminded"] = True
                save_state(spath, state)
                return {
                    "feedback": (
                        "Documentation sync reminder (duop-docs-sync): feature/UI/package code "
                        f"in `{rel}` was modified, but no docs file has been updated yet.\n"
                        "If user-facing behavior, hotkeys, or extension contracts changed, update "
                        "the relevant docs (`docs/USER_GUIDE.md`, `docs/HOTKEYS.md`, "
                        "`docs/EXTENSIONS_GUIDE.md`, or `ROADMAP.md`) before finishing."
                    )
                }

    elif name == "run_command" and not error:
        cmd = str(args.get("CommandLine") or args.get("command") or "")
        if re.search(
            r"(?:verify_build\.sh|\bmake\b[^\n]*\b(?:verify|test)\b|tests/test_[A-Za-z0-9_]+\.py|test_pty\.py)",
            cmd,
        ):
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
                state["tests_edited"] = False
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
    if os.environ.get("DUOP_SKIP_STOP_HOOK", os.environ.get("NC_SKIP_STOP_HOOK")) == "1":
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
                    "У цій сесії змінено код, конфіг збірки, VERSION або тести Duop, але перевірка "
                    "ще не виконана після останньої правки. Запусти ./.agents/skills/duop-pty-verify/scripts/verify_build.sh, "
                    "перевір VERSION згідно з duop-version-release та закоміть перевірені зміни."
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
