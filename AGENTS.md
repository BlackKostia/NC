# Duop Engineering Rules

Duop (`duop`) is a dual-pane TUI file manager in pure x86-64 GNU Assembler (`.intel_syntax noprefix`, zero `libc`, direct Linux syscalls, OOP via vtable macros). Preserve tiny static ELF size, instant startup, strict modularity, continuous SemVer versioning, and commit-after-verify discipline.

## 1. Strict Modular Layering & Dependencies

Code flows downward only — never introduce upward or cyclic dependencies across layers:

1. **`include/`** (`linux_sys.inc`, `config.inc`, `types.inc`, `oop.inc`, `classes.inc`): macros, constants, `.struct` layouts, and vtable contracts only; emit no instructions or writable data.
2. **`src/core/`** (`memory.s`, `string.s`, `utf8.s`, `oop_rt.s`, `syscall.s`, future `config.s`): runtime, allocator, strings, UTF-8 width, base `Object`/`Widget` vtables, syscall wrappers. **Must never** depend on `src/tui/`, `src/fs/`, concrete `src/ui/` widgets, or `src/app/`.
3. **`src/tui/`** (`theme.s`, `i18n.s`, `screen.s`, `input.s`): terminal TrueColor rendering, themes, EN/UA tables, SGR mouse/key parser. **Must never** depend on `src/fs/`, concrete `src/ui/` widgets, or `src/app/`.
4. **`src/fs/`** (`dir_model.s`, `file_ops.s`, future `inflate.s`/`trash.s`): directory traversal, sorting, virtual panels, async file ops (may query `i18n_get` for error text). **Must never** depend on `Screen_*`, `Input_*`, `theme_*`, concrete UI widgets, or `src/app/`.
5. **`src/ui/`** (`header_bar.s`, `function_bar.s`, `status_bar.s`, `file_pane.s`, `preview_pane.s`, `dialogs.s` and split widget modules): concrete `Widget`/`Dialog` subclasses rendering exclusively via `ScreenBuffer`, `theme_get`, and `i18n_get`.
6. **`src/app/`** & **`src/main.s`**: application controller, `poll` event loop, command dispatch, CLI arguments.

### Anti-Monolith Rule for New Features
- Place cohesive new subsystems in dedicated files registered in `Makefile` `SRCS` (e.g., `src/core/config.s`, `src/fs/task_queue.s`, `src/fs/inflate.s`, `src/ui/fuzzy_dialog.s`, `src/ui/progress_dialog.s`) rather than growing `src/ui/dialogs.s`, `src/app/app.s`, or `src/ui/file_pane.s`.
- Put shared syscall numbers in `include/linux_sys.inc` and reusable syscall wrappers in `src/core/syscall.s`.

## 2. Assembly, ABI & I18n Invariants

- Use `.intel_syntax noprefix` at the top of every `.s`/`.inc` file.
- Keep `ELF .data == 0`: immutable data in `.section .rodata`, mutable globals in `.section .bss` (or heap `mem_alloc`).
- Follow System V AMD64 ABI (`rdi` = `this`, preserve `rbx`, `rbp`, `r12`–`r15`, 16-byte stack alignment across `call`).
- Every user-visible string MUST exist in both English and Ukrainian in `include/types.inc` (`LangStrings`) and `src/tui/i18n.s` (`lang_en_table` / `lang_ua_table`). Compute layout columns via `utf8_display_width`.

## 3. Verification, SemVer & Git Commits

- Use workspace skills in `.agents/skills/`:
  - `duop-modular-asm` when adding/splitting modules, OOP classes, or syscalls
  - `duop-ui-i18n-widget` when building UI widgets, themes, mouse zones, or translations
  - `duop-pty-verify` to validate modularity, ELF footprint, release/debug builds, and PTY tests
  - `duop-version-release` to manage `VERSION`, `ROADMAP.md`, Conventional Commits, and Git tags
- Never consider code changes complete until `.agents/skills/duop-pty-verify/scripts/verify_build.sh` passes cleanly.
- Whenever modifying `src/` or `include/`, ensure `VERSION` is ahead of any existing release tag `vX.Y.Z` (bump via `bump_version.py`), rebuild so `build/version.inc` matches, verify with PTY tests, and commit with a Conventional Commit (`feat|fix|refactor|perf|build|docs|test|chore`).
