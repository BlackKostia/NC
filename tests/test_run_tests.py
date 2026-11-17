#!/usr/bin/env python3
"""tests/run_tests.py - the parallel runner behind `make test`: it reads the registry from the Makefile `test-serial:` recipe, puts tests that
write shared build output into an exclusive lane and PTY tests into their own pool, reports failures with the captured tail and exits non-zero,
and remembers durations so that the slowest tests start first."""

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import run_tests as R  # noqa: E402


def test_registry_matches_makefile() -> None:
    tests = R.registry()
    listed = subprocess.run([sys.executable, str(ROOT / "tests/run_tests.py"), "--list"], capture_output=True, text=True, check=True).stdout.split()
    assert tests == listed and len(tests) > 60, len(tests)
    assert len(set(tests)) == len(tests), "a test is registered twice"
    missing = [t for t in tests if not (ROOT / t).is_file()]
    assert not missing, f"registered but missing: {missing}"
    on_disk = {p.relative_to(ROOT).as_posix() for p in (ROOT / "tests").glob("test_*.py")}
    elsewhere = {"tests/test_lean_gate.py", "tests/test_lean_split.py", "tests/test_i18n_hook.py",   # verify_build.sh step 1
                 "tests/test_memcheck.py"}                                                                                # make memcheck
    unregistered = sorted(on_disk - set(tests) - elsewhere)
    assert not unregistered, f"tests/test_*.py not registered in the Makefile test-serial recipe: {unregistered}"
    print(f"[PASS] RT1. the Makefile registry lists {len(tests)} existing, unique scripts and every tests/test_*.py is registered")


def test_lanes() -> None:
    assert R.is_pty("tests/test_pty.py") and R.is_pty("tests/test_term_pane.py")
    assert not R.is_pty("tests/test_c_hash.py")
    assert all(any(t.endswith(e) for t in R.registry()) for e in R.EXCLUSIVE if e != "test_memcheck.py")
    print("[PASS] RT2. PTY tests are recognised, the exclusive lane names real tests")


def test_failure_and_output(tmp: Path) -> None:
    ok, bad = tmp / "test_ok.py", tmp / "test_bad.py"
    ok.write_text("print('fine')\n")
    bad.write_text("import sys\nprint('boom detail')\nsys.exit(3)\n")
    res_ok, res_bad = R.run_one(str(ok)), R.run_one(str(bad))             # absolute paths are used as they are (ROOT / abs == abs)
    assert res_ok[1] == 0 and "fine" in res_ok[3] and res_bad[1] == 3 and "boom detail" in res_bad[3], (res_ok, res_bad)
    print("[PASS] RT3. a passing script yields rc 0, a failing one its exit status and captured output")


def test_scratch_and_retry(tmp: Path) -> None:
    """Scratch dirs are tmpfs mounts (when the machine has them) and the two cross-device tests get a TMPDIR on a different filesystem than
    /dev/shm; a script that fails once and passes on its own is retried to FLAKY, one that always fails stays FAILED."""
    R.setup_scratch()
    if "fast" in R.SCRATCH and "exdev" in R.SCRATCH:
        assert Path(R.SCRATCH["fast"]).stat().st_dev == Path("/dev/shm").stat().st_dev
        assert Path(R.SCRATCH["exdev"]).stat().st_dev != Path("/dev/shm").stat().st_dev, "cross-device tests need a second filesystem"
        assert R.child_env("tests/test_trash_spec.py")["TMPDIR"] == R.SCRATCH["exdev"] and R.child_env("tests/test_c_hash.py")["TMPDIR"] == R.SCRATCH["fast"]
    flag = tmp / "first_run_done"
    (tmp / "tests").mkdir()
    once = tmp / "tests/test_once.py"
    once.write_text(f"import os, sys\nf = {str(flag)!r}\nif not os.path.exists(f):\n    open(f, 'w').close()\n    sys.exit(1)\n")
    always = tmp / "tests/test_always.py"
    always.write_text("import sys\nsys.exit(2)\n")
    mk = tmp / "Makefile"
    mk.write_text("test-serial:\n\tpython3 tests/test_once.py\n\tpython3 tests/test_always.py\n\nother:\n")
    res = subprocess.run([sys.executable, "-c", f"import sys; sys.path.insert(0, {str(ROOT / 'tests')!r}); import run_tests as R; "
                          f"from pathlib import Path; R.ROOT = Path({str(tmp)!r}); R.TIMES = R.ROOT / 'build/test_times.json'; sys.argv = ['run_tests.py', '-j', '2', '--no-tmpfs']; sys.exit(R.main())"],
                         capture_output=True, text=True, timeout=120)
    assert res.returncode == 1, res
    assert "FLAKY" in res.stderr and "test_once.py" in res.stderr and "FAILED: " in res.stderr and "test_always.py" in res.stderr, res.stderr
    assert (tmp / "build/test-logs/test_always.log").is_file(), "the full output of a failed run is kept for reading after the retry"
    print("[PASS] RT4. tmpfs scratch with a second filesystem for the cross-device tests; fail-then-pass is FLAKY, always-failing stays FAILED")


def main() -> None:
    test_registry_matches_makefile()
    test_lanes()
    with tempfile.TemporaryDirectory() as d:
        test_failure_and_output(Path(d))
        test_scratch_and_retry(Path(d))
    print("ALL TEST-RUNNER TESTS PASSED.")


if __name__ == "__main__":
    main()
