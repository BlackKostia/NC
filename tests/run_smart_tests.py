#!/usr/bin/env python3
"""Smart selective test runner for Duop.

Selects and runs only the test suites affected by modified/staged files,
falling back to the full Makefile `test` suite when core headers, runtime,
or build files change (or when --all is passed).
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Patterns that impact the entire binary and require running the full suite.
FULL_SUITE_PATTERNS = (
    "include/*",
    "Makefile",
    "VERSION",
    "src/main.s",
    "src/core/*",
    "src/os/*",
    "src/app/app.s",
    "src/app/app_loop.s",
    "src/app/app_events.s",
)

# A module migration only *registers* itself in the Makefile (a source in SRCS / C_SRCS, a test in `test:`) and appends
# declarations to include/duop_*.h. Such hunks cannot change how the rest of the tree builds, so they do not need the
# full suite (tiered pre-commit hook: the full `make test` runs in pre-push, before tags and in CI).
REGISTRATION_LINE = re.compile(r"^\s*(?:src/\S+\.(?:s|c)(?:\s*\\)?|python3 tests/test_\w+\.py)\s*$")
LOCAL_HEADER_GLOB = "include/duop_*.h"
ABI_TESTS = ("tests/test_abi_layouts.py", "tests/test_abi_cross.py")


# Subsystem path globs -> affected test scripts (relative to ROOT).
PATH_TEST_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("src/fs/file_ops_read*", ("tests/test_c_fops_small.py", "tests/test_viewer_pro.py", "tests/test_fs_reliability.py")),
    ("src/fs/file_ops*", ("tests/test_fs_reliability.py", "tests/test_bg_tasks.py", "tests/test_reliability_audit.py", "tests/test_copy_overwrite_atomic.py")),
    ("src/fs/task*", ("tests/test_fs_reliability.py", "tests/test_bg_tasks.py", "tests/test_reliability_audit.py", "tests/test_copy_overwrite_atomic.py")),
    ("src/app/app_task*", ("tests/test_fs_reliability.py", "tests/test_bg_tasks.py", "tests/test_reliability_audit.py")),
    ("src/ui/progress_dialog*", ("tests/test_bg_tasks.py",)),
    ("src/ui/conflict_dialog*", ("tests/test_fs_reliability.py", "tests/test_reliability_audit.py")),
    ("src/fs/dir_model*", ("tests/test_performance_dir.py", "tests/test_fastpath.py", "tests/test_nav_viewer.py", "tests/test_event_loop.py")),
    ("src/fs/dir_sort*", ("tests/test_performance_dir.py", "tests/test_pty.py")),
    ("src/fs/dir_cache*", ("tests/test_nav_viewer.py", "tests/test_performance_dir.py")),
    ("src/fs/dir_watch*", ("tests/test_event_loop.py", "tests/test_c_dir_watch.py")),
    ("src/ui/file_pane*", ("tests/test_pty.py", "tests/test_ui_visual.py", "tests/test_nav_tabs.py", "tests/test_pane_scrollbar.py")),
    ("src/fs/pkg_*", ("tests/test_pkg_manager.py", "tests/test_pkg_extensions.py", "tests/test_pkg_improvements.py")),
    ("src/ui/pkg_dialog*", ("tests/test_pkg_manager.py", "tests/test_pkg_extensions.py", "tests/test_pkg_improvements.py")),
    ("src/app/app_menu*", ("tests/test_pkg_extensions.py", "tests/test_pkg_improvements.py", "tests/test_cmd_expand_safety.py")),
    ("src/app/app_cmdline*", ("tests/test_cmd_expand_safety.py",)),
    ("src/fs/img_*", ("tests/test_img_preview.py", "tests/test_image_formats.py", "tests/test_image_quality.py", "tests/test_decoder_bounds.py")),
    ("src/fs/preview_*", ("tests/test_img_preview.py", "tests/test_event_loop.py")),
    ("src/ui/img_*", ("tests/test_img_preview.py", "tests/test_image_quality.py")),
    ("src/ui/preview_*", ("tests/test_img_preview.py", "tests/test_ui_visual.py")),
    ("src/fs/disk_usage*", ("tests/test_disk_usage.py", "tests/test_du_progress.py", "tests/test_du_sizes.py", "tests/test_c_du_populate.py")),
    ("src/fs/du_*", ("tests/test_disk_usage.py", "tests/test_du_progress.py", "tests/test_du_sizes.py", "tests/test_c_du_tables.py", "tests/test_c_du_walk.py")),
    ("src/ui/du_*", ("tests/test_disk_usage.py", "tests/test_du_progress.py", "tests/test_du_sizes.py")),
    ("src/app/app_du*", ("tests/test_disk_usage.py", "tests/test_du_progress.py", "tests/test_du_sizes.py")),
    ("src/fs/archive_*", ("tests/test_archive_vfs.py", "tests/test_archive_hardening.py")),
    ("src/fs/inflate*", ("tests/test_archive_vfs.py", "tests/test_pkg_manager.py")),
    ("src/app/app_arc*", ("tests/test_archive_vfs.py",)),
    ("src/fs/git_*", ("tests/test_git_status.py", "tests/test_git_trust.py")),
    ("src/ui/git_render*", ("tests/test_git_status.py",)),
    ("src/ui/header_bar_git*", ("tests/test_git_status.py",)),
    ("src/fs/nav_state*", ("tests/test_nav_tabs.py", "tests/test_nav_viewer.py", "tests/test_choosedir.py", "tests/test_c_nav_state.py")),
    ("src/fs/nav_persist*", ("tests/test_nav_tabs.py", "tests/test_nav_viewer.py", "tests/test_choosedir.py", "tests/test_c_nav_state.py", "tests/test_medium_fixes.py")),
    ("src/app/app_choosedir*", ("tests/test_choosedir.py",)),
    ("src/fs/dir_search*", ("tests/test_search_virtual.py", "tests/test_crash_regressions.py")),
    ("src/fs/dir_fuzzy*", ("tests/test_fuzzy_palette.py", "tests/test_c_dir_fuzzy.py")),
    ("src/fs/fs_write*", ("tests/test_c_dir_fuzzy.py", "tests/test_audit_regressions_io.py")),
    ("src/ui/search_dialog*", ("tests/test_search_virtual.py",)),
    ("src/ui/fuzzy_dialog*", ("tests/test_fuzzy_palette.py",)),
    ("src/fs/dir_diff*", ("tests/test_diff_menu_clip.py",)),
    ("src/ui/popup_menu*", ("tests/test_diff_menu_clip.py", "tests/test_pkg_extensions.py")),
    ("src/fs/trash_*", ("tests/test_trash_undo_attr.py", "tests/test_trash_spec.py", "tests/test_c_trash.py")),
    ("src/app/app_attr*", ("tests/test_trash_undo_attr.py",)),
    ("src/ui/attr_dialogs*", ("tests/test_trash_undo_attr.py",)),
    ("src/ui/info_dialog*", ("tests/test_trash_undo_attr.py",)),
    ("src/ui/viewer_*", ("tests/test_viewer_pro.py", "tests/test_nav_viewer.py")),
    ("src/ui/view_as_dialog*", ("tests/test_viewer_pro.py",)),
    ("src/ui/syntax*", ("tests/test_viewer_pro.py",)),
    ("src/ui/hex_edit*", ("tests/test_viewer_pro.py",)),
    ("src/ui/elf_inspect*", ("tests/test_viewer_pro.py",)),
    ("src/app/app_view*", ("tests/test_viewer_pro.py", "tests/test_nav_viewer.py")),
    ("src/ui/bulk_rename*", ("tests/test_bulk_rename.py",)),
    ("src/ui/term_*", ("tests/test_term_pane.py", "tests/test_crash_regressions.py")),
    ("src/ui/user_menu*", ("tests/test_config_usermenu.py",)),
    ("src/ui/bookmark*", ("tests/test_nav_tabs.py",)),
    ("src/tui/i18n*", ("tests/test_lang_packs.py", "tests/test_i18n_hook.py", "tests/test_c_i18n.py", "tests/test_c_i18n_table.py")),
    ("include/duop_app.h", ("tests/test_c_app_api.py",)),
    ("src/app/*", ("tests/test_c_app_api.py",)),
    ("src/core/memcheck*", ("tests/test_c_memcheck.py", "tests/test_memcheck.py")),
    ("tests/harness/memcheck_*", ("tests/test_c_memcheck.py",)),
    ("tests/c_harness.py", ("tests/test_c_harness_utils.py", "tests/test_c_i18n_table.py", "tests/test_c_syscall.py", "tests/test_c_hash.py")),
    ("tests/harness/script_cli.h", ("tests/test_c_harness_utils.py",)),
    ("tools/gen_i18n.py", ("tests/test_c_i18n_table.py", "tests/test_c_i18n.py", "tests/test_i18n_hook.py")),
    ("lang/*", ("tests/test_lang_packs.py", "tests/test_i18n_hook.py")),
    ("src/tui/kbd_*", ("tests/test_kbd_layout.py",)),
    ("layouts/*", ("tests/test_kbd_layout.py",)),
    ("src/ui/dialogs_help*", ("tests/test_help_instruction.py",)),
    ("src/ui/header_bar*", ("tests/test_ui_visual.py", "tests/test_pty.py")),
    ("src/ui/status_bar*", ("tests/test_ui_visual.py", "tests/test_pty.py")),
    ("src/ui/function_bar*", ("tests/test_ui_visual.py", "tests/test_pty.py")),
    ("src/tui/theme*", ("tests/test_ui_visual.py", "tests/test_pty.py")),
    ("src/tui/screen*", ("tests/test_ui_visual.py", "tests/test_event_loop.py")),
    ("src/tui/input*", ("tests/test_pty.py", "tests/test_kbd_layout.py")),
    ("src/app/app_cmds*", ("tests/test_pty.py", "tests/test_fs_reliability.py")),
    ("src/app/app_keys*", ("tests/test_pty.py", "tests/test_kbd_layout.py")),
    ("src/app/app_open*", ("tests/test_pty.py", "tests/test_archive_vfs.py")),
    ("src/app/app_toggles*", ("tests/test_pty.py", "tests/test_ui_visual.py")),
    ("src/app/app_ext*", ("tests/test_fuzzy_palette.py", "tests/test_diff_menu_clip.py")),
    ("src/app/app_layout*", ("tests/test_ui_visual.py", "tests/test_pty.py")),
    ("src/app/app_close_dialog*", ("tests/test_pty.py",)),
    (".agents/skills/duop-lean-modules/*", ("tests/test_lean_gate.py", "tests/test_lean_split.py")),
    (".agents/skills/duop-reliability-audit/*", ("tests/test_reliability_audit.py", "tests/test_fault_injection.py", "tests/test_audit_live_regs.py", "tests/test_elf_hardening.py")),
    ("tools/abi_verify.c", ("tests/test_reliability_audit.py",)),
    (".agents/hooks/*", ("tests/test_lean_gate.py", "tests/test_i18n_hook.py", "tests/test_c_guards.py")),
    (".claude/hooks/*", ("tests/test_i18n_hook.py", "tests/test_c_guards.py")),
    ("tools/check_c_syntax.py", ("tests/test_c_guards.py",)),
    ("tools/faultlab/audit_null_alloc_c.py", ("tests/test_c_guards.py",)),
    (".githooks/*", ("tests/test_smart_runner.py",)),
)


def _changed_lines(diff_text: str) -> list[str]:
    return [ln for ln in diff_text.splitlines() if ln[:1] in "+-" and not ln.startswith(("+++", "---"))]


def makefile_diff_is_local(diff_text: str) -> bool:
    """True when every changed Makefile line only registers a source file or a test script."""
    lines = _changed_lines(diff_text)
    return bool(lines) and all(REGISTRATION_LINE.match(ln[1:]) for ln in lines)


def header_diff_is_local(diff_text: str) -> bool:
    """True when a duop_*.h change only adds lines (existing declarations are untouched)."""
    lines = _changed_lines(diff_text)
    return bool(lines) and all(ln.startswith("+") for ln in lines)


def local_change(rel: str, staged_only: bool = False) -> bool:
    """Is the working-tree / staged change of a Makefile or duop_*.h file a pure registration / addition?"""
    if rel != "Makefile" and not fnmatch.fnmatch(rel, LOCAL_HEADER_GLOB):
        return False
    cmd = ["git", "diff", "--cached" if staged_only else "HEAD", "-U0", "--", rel]
    res = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, check=False)
    if res.returncode != 0:
        return False
    return makefile_diff_is_local(res.stdout) if rel == "Makefile" else header_diff_is_local(res.stdout)


def detect_changed_files(staged_only: bool = False) -> list[str]:
    cmds = [["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]]
    if not staged_only:
        cmds.append(["git", "diff", "--name-only", "--diff-filter=ACMR"])
        cmds.append(["git", "ls-files", "--others", "--exclude-standard"])
    changed: list[str] = []
    seen: set[str] = set()
    for cmd in cmds:
        res = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, check=False)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                p = line.strip()
                if p and p not in seen:
                    seen.add(p)
                    changed.append(p)
    if not changed and not staged_only:
        res = subprocess.run(
            ["git", "diff", "--name-only", "HEAD~1", "HEAD"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode == 0:
            changed = [line.strip() for line in res.stdout.splitlines() if line.strip()]
    return changed


def select_tests(changed_files: list[str], local_ok=None) -> tuple[bool, list[str]]:
    """Return (run_full_suite, list_of_test_paths). local_ok(rel) -> True for a Makefile / duop_*.h change that only
    registers or adds (see local_change); such files do not trigger the full suite."""
    selected: list[str] = []
    seen: set[str] = set()
    has_asm = False

    def add_test(t: str) -> None:
        if t not in seen and (ROOT / t).is_file():
            seen.add(t)
            selected.append(t)

    for rel in changed_files:
        if local_ok is not None and local_ok(rel):
            for t in ABI_TESTS if rel.startswith("include/") else ():
                add_test(t)
            continue
        for pat in FULL_SUITE_PATTERNS:
            if fnmatch.fnmatch(rel, pat):
                return True, []
        if rel.endswith(".s") or rel.endswith(".inc"):
            has_asm = True
        if rel.endswith(".c"):
            add_test("tests/test_c_stack_align.py")
        if rel.startswith("tests/test_") and rel.endswith(".py"):
            add_test(rel)
            continue
        matched = False
        for pat, tests in PATH_TEST_RULES:
            if fnmatch.fnmatch(rel, pat):
                matched = True
                for t in tests:
                    add_test(t)
        if not matched and rel.startswith(("src/", "include/")):
            add_test("tests/test_pty.py")

    if has_asm:
        add_test("tests/test_reliability_audit.py")
    return False, selected


def run_selected(tests: list[str], dry_run: bool = False) -> int:
    if dry_run:
        for t in tests:
            print(t)
        return 0
    t0 = time.time()
    for t in tests:
        print(f"==> [smart-test] {t}")
        res = subprocess.run([sys.executable, str(ROOT / t)], cwd=str(ROOT), check=False)
        if res.returncode != 0:
            print(f"FAILED: {t} (exit {res.returncode})", file=sys.stderr)
            return res.returncode
    print(f"SMART TESTS PASSED ({len(tests)} suite(s) in {time.time() - t0:.2f}s).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run only Duop tests affected by current changes")
    parser.add_argument("--staged", action="store_true", help="Inspect only git-staged files")
    parser.add_argument("--files", nargs="*", help="Explicit list of changed repo-relative files")
    parser.add_argument("--dry-run", action="store_true", help="Print selected tests without running")
    args = parser.parse_args()

    changed = args.files if args.files is not None else detect_changed_files(staged_only=args.staged)
    if not changed:
        print("No changed files detected; running core reliability & PTY smoke tests.")
        return run_selected(["tests/test_reliability_audit.py", "tests/test_pty.py"], dry_run=args.dry_run)

    run_full, tests = select_tests(changed, local_ok=lambda rel: local_change(rel, staged_only=args.staged))
    if run_full:
        if args.dry_run:
            print("FULL_SUITE")
            return 0
        print(f"Core/global changes detected ({len(changed)} file(s)); running full `make -s test`.")
        res = subprocess.run(["make", "-s", "test"], cwd=str(ROOT), check=False)
        return res.returncode

    if not tests:
        print("No code/test files affected (docs/meta only); skipping PTY test suites.")
        return 0
    return run_selected(tests, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
