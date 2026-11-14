#!/usr/bin/env python3
"""Unit tests for tests/run_smart_tests.py selective test mapping."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

import run_smart_tests as rsm  # noqa: E402


def test_file_ops_selects_only_fs_and_reliability() -> None:
    full, tests = rsm.select_tests(["src/fs/file_ops_copy.s"])
    assert not full
    assert "tests/test_fs_reliability.py" in tests
    assert "tests/test_bg_tasks.py" in tests
    assert "tests/test_reliability_audit.py" in tests
    assert "tests/test_img_preview.py" not in tests
    assert "tests/test_viewer_pro.py" not in tests


def test_pkg_change_selects_only_pkg_suites() -> None:
    full, tests = rsm.select_tests(["src/fs/pkg_manager.s"])
    assert not full
    assert tests == [
        "tests/test_pkg_manager.py",
        "tests/test_pkg_extensions.py",
        "tests/test_pkg_improvements.py",
        "tests/test_reliability_audit.py",
    ]


def test_core_header_triggers_full_suite() -> None:
    full, _ = rsm.select_tests(["include/pal.inc"])
    assert full


def test_docs_only_skips_pty_suites() -> None:
    full, tests = rsm.select_tests(["docs/EXTENSIONS.md"])
    assert not full
    assert tests == []


def main() -> int:
    for fn in (
        test_file_ops_selects_only_fs_and_reliability,
        test_pkg_change_selects_only_pkg_suites,
        test_core_header_triggers_full_suite,
        test_docs_only_skips_pty_suites,
    ):
        fn()
        print(f"PASS: {fn.__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
