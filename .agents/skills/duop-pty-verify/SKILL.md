---
name: duop-pty-verify
description: >-
  Runs Duop verification checks: modularity/lean/C-syntax gates, zero-.data ELF check, VERSION consistency, release and debug
  builds, memcheck and real PTY end-to-end tests (smart / release-only / full modes). Use after editing any .s, .c, .h, .inc,
  Makefile, VERSION or tests/*.py file.
---

# Duop Build, Modularity & PTY Verification

```bash
./.agents/skills/duop-pty-verify/scripts/verify_build.sh [--smart|--release-only|--full]
```

| Step | What |
|---|---|
| 1 | `check_modularity.py` (SRCS/C_SRCS/PAL_SRCS sync, PAL boundary, layers, i18n parity, `.data`-free, SemVer), asm audits (`audit_stack_abi/cfg_stack/syscall_clobber/abi_regs/oop_vtables/fd_eintr`), `tools/abi_verify.c`, **`tools/check_c_syntax.py`** (every `src/**/*.c`, project CFLAGS, x86_64 gcc + aarch64 clang) and **`tools/faultlab/audit_null_alloc_c.py`**, lean gate, hook self-tests |
| 2 | `make release` (stripped ELF with `build/version.inc`) |
| 3 | `size` (`.data == 0`), `audit_elf_hardening.py`, `audit_live_regs.py`, `./duop --version` equals `VERSION` |
| 4 | `--smart`: `tests/run_smart_tests.py` (only suites mapped to the changed files; module registration in `Makefile` / additive `duop_*.h` stays local) — `--full`/default: `make test` (~95 suites incl. all `test_c_*` differential tests, run in parallel by `tests/run_tests.py`: scratch files on a tmpfs, PTY tests in their own pool, a test that fails under load is retried alone and reported FLAKY; `make test-serial` runs them one by one) |
| 5 | `make memcheck` (`MEMCHECK=1`, `tests/test_memcheck.py`); `--full` also rebuilds the DWARF debug binary and re-runs `make test` |

Hooks: `.githooks/pre-commit` runs this in `--smart` mode (full for `src/core`, `src/os`, `include/*.inc`, edits of existing
declarations, `src/main.s`, `app_loop`); `.githooks/pre-push` runs the **complete** `make test` plus faultlab sweeps, SEU
and fuzzing. `DUOP_FULL_PTY_HOOK=1` forces `--release-only`-style full runs in pre-commit.

New features/bugfixes: follow `duop-tdd-first` (tests registered in `Makefile`, mapped in `PATH_TEST_RULES`).
