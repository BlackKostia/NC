#!/usr/bin/env python3
"""Parallel runner behind `make test`: runs every script of the Makefile test list (the `test-serial:` recipe is the registry) concurrently.

Why it is safe: every test builds its fixtures in its own temp directory; the shared build tree is brought up to date once, up front, so the
`make` calls some tests make are no-ops. Tests that write shared build output (selftest / headless / duop.sym) form an exclusive lane and
run one at a time; PTY tests are timing sensitive and get their own, smaller worker pool. Slowest tests start first (timing history in
build/test_times.json) so the wall time approaches max(longest test, total / jobs).

Scratch files go to a tmpfs when one is available (TMPDIR for every child): many tests copy, move and delete trees and the product fsyncs, so on a
shared disk the parallel tests starve each other (a copy that takes 1 s alone takes minutes). A test that fails in the parallel phase is run once
more on its own; passing on that retry is reported as FLAKY (the suite stays green, the warning names the test), failing twice is a real failure.

usage: run_tests.py [-j N] [--pty-jobs M] [--only SUBSTR ...] [--serial] [--no-tmpfs] [--no-retry] [--list]   exit 0 only when every test passes"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIMES = ROOT / "build/test_times.json"
EXCLUSIVE = ("test_pal_selftest.py", "test_headless.py", "test_audit_live_regs.py", "test_memcheck.py")      # write shared build outputs
PTY_MARKERS = ("PtySession", "import test_pty", "from test_pty", "pty.fork", "openpty")
# Standalone harness/audit scripts that compile their own test binaries and do not depend on release vs debug ./duop
HARNESS_PREFIXES = ("tests/test_c_", "tests/test_abi_", "tests/test_pal_", "tests/test_gen_abi",
                    "tests/test_run_tests", "tests/test_smart_runner", "tests/test_headless")
TIMEOUT = 1500


def registry() -> list[str]:
    text = (ROOT / "Makefile").read_text()
    block = re.search(r"^test-serial:.*?(?=^\S)", text, re.S | re.M)
    assert block, "Makefile has no test-serial: block"
    return re.findall(r"^\tpython3 (tests/\S+\.py)\s*$", block.group(0), re.M)


def is_pty(rel: str) -> bool:
    text = (ROOT / rel).read_text(errors="replace")
    return any(m in text for m in PTY_MARKERS)


EXDEV_TESTS = ("test_trash_spec.py", "test_security_reliability.py", "test_fs_reliability.py")      # need a second filesystem next to their TMPDIR
SCRATCH: dict[str, str] = {}                                                                          # "fast" / "exdev" -> TMPDIR for the children


def is_tmpfs(path: str) -> bool:
    try:
        for ln in Path("/proc/self/mountinfo").read_text().splitlines():
            f = ln.split()
            if f[4] == path and f[f.index("-") + 1] == "tmpfs":
                return True
    except (OSError, ValueError, IndexError):
        pass
    return False


def setup_scratch() -> None:
    """Scratch files go to a tmpfs: /dev/shm/dt (short: the UI shows paths and truncates long ones) for most tests; the cross-device tests use
    /dev/shm as "the other filesystem", so their TMPDIR is a second tmpfs, /run/user/<uid>/dt, when there is one."""
    shm = Path("/dev/shm")
    if is_tmpfs(str(shm)) and os.access(shm, os.W_OK):
        (shm / "dt").mkdir(exist_ok=True)
        SCRATCH["fast"] = str(shm / "dt")
    run = Path(f"/run/user/{os.getuid()}")
    if is_tmpfs(str(run)) and os.access(run, os.W_OK) and run.stat().st_dev != shm.stat().st_dev:
        (run / "dt").mkdir(exist_ok=True)
        SCRATCH["exdev"] = str(run / "dt")


def child_env(rel: str) -> dict[str, str]:
    kind = "exdev" if rel.endswith(EXDEV_TESTS) else "fast"
    return {**os.environ, **CHILD_ENV, **({"TMPDIR": SCRATCH[kind]} if kind in SCRATCH else {})}


CHILD_ENV: dict[str, str] = {}


def save_log(rel: str, out: str) -> None:
    """The full output of a failed run, kept next to the build so a flaky failure can be read after the retry has passed."""
    log = ROOT / "build/test-logs" / (Path(rel).stem + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(out)


def run_one(rel: str) -> tuple[str, int, float, str]:
    t0 = time.monotonic()
    try:
        res = subprocess.run([sys.executable, str(ROOT / rel)], cwd=ROOT, capture_output=True, text=True, timeout=TIMEOUT,
                             env=child_env(rel))
        out, rc = res.stdout + res.stderr, res.returncode
    except subprocess.TimeoutExpired as exc:
        out, rc = f"TIMEOUT after {TIMEOUT}s\n{(exc.stdout or b'')[-2000:]}", 124
    return rel, rc, time.monotonic() - t0, out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    cpus = os.cpu_count() or 4
    ap.add_argument("-j", "--jobs", type=int, default=max(2, min(6, cpus // 2)))
    ap.add_argument("--pty-jobs", type=int, default=max(2, min(3, cpus // 4)))
    ap.add_argument("--only", nargs="*", default=[], help="run only tests whose path contains one of these substrings")
    ap.add_argument("--binary-only", action="store_true", help="skip standalone harness/ABI tests that do not execute ./duop")
    ap.add_argument("--serial", action="store_true", help="one test at a time (the old behaviour)")
    ap.add_argument("--no-tmpfs", action="store_true", help="keep the default TMPDIR (a disk)")
    ap.add_argument("--no-retry", action="store_true", help="a failure in the parallel phase is final")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    tests = [t for t in registry() if not args.only or any(s in t for s in args.only)]
    if args.binary_only:
        tests = [t for t in tests if not t.startswith(HARNESS_PREFIXES)]
    if args.list:
        print("\n".join(tests))
        return 0
    history = json.loads(TIMES.read_text()) if TIMES.exists() else {}
    tests.sort(key=lambda t: -history.get(t, 30.0))
    if not args.no_tmpfs:
        setup_scratch()
    CHILD_ENV["DUOP_TEST_JOBS"] = "2"                                             # unified cap: total workers * 2 <= host threads
    t_start, failed, durations = time.monotonic(), [], {}
    total_workers = 1 if args.serial else max(1, args.jobs)
    pty_sem = threading.Semaphore(1 if args.serial else max(1, min(args.pty_jobs, total_workers)))
    excl_lock = threading.Lock()

    def run_gated(rel: str) -> tuple[str, int, float, str]:
        if rel.endswith(EXCLUSIVE):
            with excl_lock:
                return run_one(rel)
        if is_pty(rel):
            with pty_sem:
                return run_one(rel)
        return run_one(rel)

    with ThreadPoolExecutor(max_workers=total_workers) as pool:
        futures = [pool.submit(run_gated, t) for t in tests]
        done = 0
        for fut in as_completed(futures):
            rel, rc, dt, out = fut.result()
            done += 1
            durations[rel] = round(dt, 1)
            print(f"[{done:3}/{len(futures)}] {'PASS' if rc == 0 else 'FAIL'} {dt:6.1f}s {rel}", flush=True)
            if rc != 0:
                failed.append(rel)
                save_log(rel, out)
                print("\n".join("    | " + ln for ln in out.splitlines()[-40:]), flush=True)
    flaky: list[str] = []
    if failed and not args.no_retry and not args.serial:
        print(f"\nretrying {len(failed)} failed test(s) alone: {' '.join(Path(t).name for t in failed)}", flush=True)
        for rel in list(failed):
            _, rc, dt, out = run_one(rel)
            durations[rel] = round(dt, 1)
            print(f"[retry] {'PASS' if rc == 0 else 'FAIL'} {dt:6.1f}s {rel}", flush=True)
            if rc == 0:
                failed.remove(rel)
                flaky.append(rel)
            else:
                tail = out.splitlines()[-40:]
                print("\n".join("    | " + ln for ln in tail), flush=True)
                if os.environ.get("GITHUB_ACTIONS"):
                    msg = " | ".join(ln.strip() for ln in tail[-6:] if ln.strip())
                    print(f"::error title={rel}::{msg}", flush=True)
    if not args.only:
        TIMES.parent.mkdir(exist_ok=True)
        TIMES.write_text(json.dumps({**history, **durations}, indent=0))
    wall = time.monotonic() - t_start
    top = sorted(durations.items(), key=lambda kv: -kv[1])[:5]
    print(f"\n{len(futures) - len(failed)}/{len(futures)} test scripts passed in {wall:.0f}s wall ({sum(durations.values()):.0f}s of test time); slowest: "
          + ", ".join(f"{Path(t).name} {s}s" for t, s in top))
    if flaky:
        print("WARNING: FLAKY under parallel load (passed when run alone): " + " ".join(flaky), file=sys.stderr)
    if failed:
        print("FAILED: " + " ".join(failed), file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
