---
name: duop-tdd-first
description: >-
  Enforces test-first (TDD) workflow for every new Duop feature or bugfix.
  Designs deterministic PTY functional and fault-injection tests in tests/ before
  modifying src/ or include/, verifies Red -> Green -> Refactor, and integrates
  with duop_lifecycle.py hooks.
---

# Duop Test-Driven Development (`duop-tdd-first`)

Never treat assembly implementation as the starting point for a feature or bugfix. Every behavior change in Duop follows **Design Test -> Red -> Green -> Verify -> Commit**.

Workspace lifecycle hooks (`.agents/hooks/duop_lifecycle.py`) actively enforce this gate in `PreToolUse`: edits to `src/` or `include/` are blocked until at least one test file under `tests/` has been created or updated in the current development cycle (use `DUOP_TDD_BYPASS=1` only for pure non-functional refactors or comment cleanups).

## 1. Design the Test Matrix First

Before writing any `.s` or `.inc` code, list all verification scenarios across four axes:

1. **Happy path (EN & UA)**:
   - Core feature works end-to-end in a real PTY (`tests/test_pty.py` or a dedicated `tests/test_<subsystem>.py` registered in `Makefile`).
   - Verify rendered labels in both English (`--lang en`) and Ukrainian (`--lang ua` or `Alt+L`), plus mouse hit zones if interactive.
2. **Data-safety & filesystem edge cases**:
   - Empty inputs, `..` (`FE_IS_PARENT`), whitespace/quotes/UTF-8 Cyrillic names, deep/large trees (>300 entries to exercise multiple `getdents64` batches), large files (>32 KiB buffer boundary), read-only files (`0444`), symlinks & dangling symlinks (`AT_SYMLINK_NOFOLLOW`).
3. **Fault / failure injection**:
   - Permission denied (`0555` parent directory -> `-EACCES`), missing source/destination (`-ENOENT`), collision (`-EEXIST`, `-ENOTDIR`, `-EISDIR`), same-inode or self-ancestry copy/move hazard, partial batch failure, canceled dialogs.
   - **Golden Safety Invariant**: whenever copy, move, rename, or delete fails or is canceled, **existing source data must remain 100% intact and uncorrupted**, the UI must display a clear EN/UA status error (`StatusBar`), and the process must remain alive and responsive (`exit 0` on `q`).
4. **ABI / static / ELF invariants**:
   - Keep `make test` fast (<15 s) by putting unit-level fault/edge tests in focused suites (`tests/test_fs_reliability.py`, etc.) using isolated `tempfile.TemporaryDirectory()` workspaces and clean teardown (restoring `0755` permissions before cleanup).

## 2. Red Phase (Write & Run Failing Tests)

1. Import `PtySession` / `VirtualTerminal` from `tests/test_pty.py` into dedicated subsystem suites (`tests/test_<feature>.py`) or add targeted assertions in `tests/test_pty.py`.
2. Ensure new test suites are wired into `Makefile` (`test:` target) so `make test` and `./.agents/skills/duop-pty-verify/scripts/verify_build.sh` run them automatically.
3. Run the new test against the unmodified `./duop` binary first to observe a clean **RED** failure (or validate test harness behavior):
   ```bash
   python3 tests/test_<feature>.py
   ```

## 3. Green Phase (Modular Assembly Implementation)

1. Implement the minimal, modular `.s`/`.inc` solution following `duop-modular-asm` and `duop-ui-i18n-widget`:
   - Keep subsystem code in focused modules under `src/<layer>/`.
   - Maintain System V AMD64 ABI (`rbx, rbp, r12-r15`, 16-byte stack alignment), `ELF .data == 0`, and synchronized EN/UA `LangStrings`.
2. Re-run the targeted test until **GREEN**.

## 4. Full Verification & Release

1. Update `VERSION` (`python3 ./.agents/skills/duop-version-release/scripts/bump_version.py patch|minor`) whenever `src/` or `include/` changed.
2. Run full verification (modularity lint + release/debug builds + ELF audit + all PTY test suites):
   ```bash
   ./.agents/skills/duop-pty-verify/scripts/verify_build.sh
   ```
3. Commit tests + implementation together with a Conventional Commit message (`feat:`, `fix:`, `test:`).
