---
name: duop-pty-verify
description: >-
  Runs Duop verification checks: modularity/lean/C-syntax gates, static zero-libc ELF hardening check, VERSION consistency,
  release and debug builds, memcheck and real PTY/differential tests (smart / release-only / full modes). Use after editing
  any .s, .c, .h, .inc, Makefile, VERSION or tests/*.py file.
---

# Duop Build, Modularity & PTY Verification

```bash
./.agents/skills/duop-pty-verify/scripts/verify_build.sh [--smart|--release-only|--full]
```

| Step | What |
|---|---|
| 1 | `check_modularity.py` (SRCS/C_SRCS/PAL_SRCS sync, PAL boundary, layers, i18n parity, SemVer), asm audits (`audit_stack_abi/cfg_stack/syscall_clobber/abi_regs/oop_vtables/fd_eintr`), `tools/abi_verify.c`, **`tools/check_c_syntax.py`** (every tracked/untracked `src/**/*.c`, cached single-probe CFLAGS, x86_64 gcc + aarch64 clang) and **`tools/faultlab/audit_null_alloc_c.py`**, lean gate, hook self-tests |
| 2 | `make release` (stripped ELF with `build/version.inc`) |
| 3 | `size` (reported, not gated), `audit_elf_hardening.py` (static, no libc/dynamic/W+X; `.data` allowed), `audit_live_regs.py`, `./duop --version` equals `VERSION` |
| 4 | `--smart`: `tests/run_smart_tests.py` (only suites mapped to the changed files; module registration in `Makefile` / additive `duop_*.h` / `VERSION` bumps stay local) — `--release-only` / `--full`: `make test` (127+ suites incl. all `test_c_*` differential tests, run by `tests/run_tests.py` with unified CPU budget, tmpfs scratch, and atomic object caching in `/dev/shm/duop_obj_cache_<uid>`; a test that fails under load is retried alone and reported FLAKY) |
| 5 | `make memcheck` (`MEMCHECK=1`, `tests/test_memcheck.py`); `--full` also rebuilds the DWARF debug binary and runs `tests/run_tests.py --binary-only` (all PTY/CLI tests that execute `./duop`, avoiding redundant double-runs of standalone `test_c_*` harnesses) |

Hooks: `.githooks/pre-commit` runs this in `--smart` mode (full for `src/core`, `src/os`, `include/*.inc`, edits of existing
declarations, `src/main.s`, `app_loop`); `.githooks/pre-push` runs the **complete** `make test` plus faultlab sweeps, SEU
and fuzzing. `DUOP_FULL_PTY_HOOK=1` forces `--release-only`-style full runs in pre-commit.

New features/bugfixes: follow `duop-tdd-first` (tests registered in `Makefile`, mapped in `PATH_TEST_RULES`).
