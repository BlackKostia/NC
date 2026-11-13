---
name: duop-pty-verify
description: >-
  Runs Duop verification checks: static modularity lint, zero-.data ELF check,
  VERSION consistency, release and debug builds, and real PTY end-to-end tests. Use
  after editing any .s, .inc, Makefile, VERSION, or tests/*.py file.
---

# Duop Build, Modularity & PTY Verification

Always verify changes in real builds and real PTY sessions before considering any task finished or ready to commit.

## Standard Verification Gate

Run the shared verification runner from the repository root:

```bash
./.agents/skills/duop-pty-verify/scripts/verify_build.sh
```

What this verifies:
1. `python3 .agents/skills/duop-modular-asm/scripts/check_modularity.py` — `SRCS` sync, `.intel_syntax noprefix`, zero `.data` directives, strict layer boundaries, `LangStrings` parity, valid SemVer `VERSION`.
2. `make release` — compiles stripped release ELF `duop` with generated `build/version.inc`.
3. `size duop` — fails if ELF `.data != 0` (mutable state belongs in `.bss` or heap).
4. `./duop --version` — verifies binary output embeds exact `VERSION`.
5. `make test` — runs `tests/test_pty.py` and `tests/test_fs_reliability.py` (all registered PTY test suites) against release build.
6. `make clean && make && make test` — verifies DWARF debug build also compiles cleanly and passes all PTY tests (skipped if `--release-only` is passed for fast pre-commit checks).

## When Adding Features or Bugfixes

Follow `duop-tdd-first`: add deterministic PTY / fault-injection test cases under `tests/` (`tests/test_pty.py`, `tests/test_fs_reliability.py`, or a new module registered in `Makefile`) covering new flags, keys, dialogs, UI text (both EN and UA), or filesystem behavior before editing `src/`/`include/` and running `verify_build.sh`.
