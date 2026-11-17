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


MAKEFILE_REGISTRATION = """@@ -10,2 +10,3 @@
-\tsrc/fs/dir_search.c
+\tsrc/fs/dir_search.c \\
+\tsrc/fs/dir_fuzzy.c
@@ -40,1 +41,2 @@
+\tpython3 tests/test_c_dir_fuzzy.py
-\tsrc/fs/dir_fuzzy.s \\
"""


def test_makefile_registration_is_local() -> None:
    assert rsm.makefile_diff_is_local(MAKEFILE_REGISTRATION)
    assert not rsm.makefile_diff_is_local(MAKEFILE_REGISTRATION + "+CFLAGS += -DFOO\n")
    assert not rsm.makefile_diff_is_local("")


def test_header_addition_is_local_but_edit_is_global() -> None:
    assert rsm.header_diff_is_local("@@ -1,0 +2,2 @@\n+int new_fn(void);\n+int other(void);\n")
    assert not rsm.header_diff_is_local("@@ -3,1 +3,1 @@\n-int f(int);\n+int f(long);\n")


def test_local_registration_skips_full_suite() -> None:
    full, tests = rsm.select_tests(["Makefile", "include/duop_fs.h", "src/fs/dir_fuzzy.c", "tests/test_c_dir_fuzzy.py"], local_ok=lambda rel: rel in ("Makefile", "include/duop_fs.h"))
    assert not full
    assert "tests/test_abi_layouts.py" in tests and "tests/test_abi_cross.py" in tests
    assert "tests/test_c_stack_align.py" in tests and "tests/test_c_dir_fuzzy.py" in tests
    full, _ = rsm.select_tests(["Makefile", "src/fs/dir_fuzzy.c"], local_ok=lambda rel: False)
    assert full                                                  # a non-registration Makefile change still needs everything


def test_core_and_inc_stay_global() -> None:
    for rel in ("src/core/memory.c", "src/os/linux/x86_64/pal_os.s", "include/types.inc", "src/main.s", "src/app/app_loop.s"):
        full, _ = rsm.select_tests([rel], local_ok=lambda r: True if r == "Makefile" else False)
        assert full, rel


def main() -> int:
    for fn in (
        test_makefile_registration_is_local,
        test_header_addition_is_local_but_edit_is_global,
        test_local_registration_skips_full_suite,
        test_core_and_inc_stay_global,
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
