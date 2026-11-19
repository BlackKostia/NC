---
name: duop-tdd-first
description: >-
  Enforces test-first (TDD) workflow for every new Duop feature, bugfix or module migration. Designs deterministic PTY,
  fault-injection and differential (new C vs frozen asm oracle) tests in tests/ before modifying src/ or include/,
  verifies Red -> Green -> Refactor, and integrates with the duop_lifecycle.py hooks.
---

# Duop Test-Driven Development (`duop-tdd-first`)

Every behaviour change follows **Design Test -> Red -> Green -> Verify -> Commit**. The lifecycle hook
(`.agents/hooks/duop_lifecycle.py`, `PreToolUse`) blocks edits of `src/` or `include/` until a test under `tests/` has been
created or updated in the session (`DUOP_TDD_BYPASS=1` only for pure non-functional refactors / comment cleanups).

## 1. Design the test matrix first

1. **Happy path (EN & UA)** in a real PTY (`tests/test_pty.py` helpers, or a dedicated `tests/test_<subsystem>.py` registered in
   the Makefile `test:` list); mouse hit zones when interactive.
2. **Data-safety edge cases**: empty input, `..`, quotes/UTF-8 names, > 300 entries (several `getdents64` batches), > 32 KiB
   buffers, read-only files, symlinks and dangling symlinks, FIFOs (never opened blockingly), `PATH_MAX` boundaries.
3. **Fault injection**: `EACCES` / `ENOENT` / `EEXIST` / `EXDEV`, partial batch failure, canceled dialogs, OOM. Golden
   invariant: a failed or canceled copy / move / rename / delete leaves the source intact, shows an EN/UA status error, and
   the process stays responsive.
4. **ABI / static invariants**: static ELF without libc/dynamic/W+X, struct layouts (`tests/test_abi_layouts.py`), PAL constants (`test_abi_cross.py`).
5. **Module migration (asm -> C)**: the test *is* a differential harness against the frozen asm oracle
   (`tests/harness/<m>_reference.s`) on random + boundary + real-filesystem inputs, followed by mutation checks
   (`duop-asm-to-c-migration`). Red = the harness fails (or the C does not exist yet); Green = identical results.

## 2. Red -> Green

1. Add/extend the test and register it in `Makefile` (`test:`) and `tests/run_smart_tests.py` (`PATH_TEST_RULES`).
2. Run it against the unmodified code and observe the failure (`python3 tests/test_<feature>.py`).
3. Implement the minimal change (C by default; `duop-modular-asm`), re-run until green.

## 3. Verify & commit

1. Bump `VERSION` when `src/`/`include/` changed and `v$(cat VERSION)` is already tagged (`duop-version-release`).
2. Fast loop: `python3 tests/run_smart_tests.py --files <changed files>` or `verify_build.sh --smart`; before pushing: `./.agents/skills/duop-pty-verify/scripts/verify_build.sh`.
   The full `make test` is 127+ suites run in parallel by `tests/run_tests.py` (with unified CPU concurrency, tmpfs scratch, and atomic
   object caching in `/dev/shm/duop_obj_cache_<uid>` — disable via `DUOP_NO_TEST_CACHE=1`; `make test-serial` runs one by one): the pre-commit hook runs
   the smart subset for module-local commits, the complete set runs in `pre-push` and CI. For UI migrations reuse `tests/harness/ui_{render,event,app_stub}.h`
   and `c_harness.perf_gate`. Keep tests independent so they can run concurrently (isolated `tempfile` trees, no fixed paths, permissions restored
   before cleanup), prefer polling waits to fixed sleeps, and register a new test as one `python3 tests/test_x.py` line in the Makefile `test-serial:` recipe (that recipe is the
   registry the runner reads; `tests/test_run_tests.py` fails for an unregistered `tests/test_*.py`). Tests that must not overlap (they write
   shared build output) belong in `EXCLUSIVE` of `tests/run_tests.py`; independent cases inside one test go through `tests/par.py:run_parallel`.
3. Commit tests + implementation together (`feat:`, `fix:` with a `Test:` line, `refactor:`).
