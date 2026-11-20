# Contributing to Duop

Thank you for your interest in contributing to **Duop**! Duop is an ultra-fast, zero-`libc` dual-pane terminal file manager for Linux (`x86_64` & `aarch64`).

---

## Ways to Contribute (Good First Issues)

1. **New Interface Languages (`lang/*.lang`) — zero C/assembly required!**
   - Copy [`lang/uk.lang`](lang/uk.lang) or [`src/tui/i18n_en.lang`](src/tui/i18n_en.lang) to `lang/<id>.lang` (e.g., `lang/de.lang`, `lang/pl.lang`, `lang/es.lang`, `lang/fr.lang`).
   - Set `code` (2-letter badge) and `name`, then translate the `key = value` lines. Any omitted key automatically falls back to English.
   - Test live with `./duop --lang <id>` or by pressing `Alt+L`.
2. **Keyboard Layout Maps (`layouts/*.layout`) — zero code required!**
   - Copy [`layouts/uk.layout`](layouts/uk.layout) to `layouts/<id>.layout` so physical hotkeys (`Alt+T`, `Alt+L`, `j`/`k`) work while a non-Latin keyboard layout is active.
3. **Out-of-Process Extension Packages (`packages/`)**
   - Build standalone tools or VFS providers following [`docs/EXTENSIONS_GUIDE.md`](docs/EXTENSIONS_GUIDE.md) (see [`packages/duop-inspect/`](packages/duop-inspect/manifest.ini) and [`packages/duop-sysmon/`](packages/duop-sysmon/manifest.ini)).
4. **Core Engine & UI (`src/**/*.c`)**
   - Pick an item from [`ROADMAP.md`](ROADMAP.md) or [`docs/DEVELOPMENT_PLAN_2026-11-17.md`](docs/DEVELOPMENT_PLAN_2026-11-17.md).

---

## Architecture & Engineering Invariants

Before modifying `src/` or `include/`, review [`AGENTS.md`](AGENTS.md):

1. **Zero `libc`, Zero External Runtime Libraries**:
   - Static ELF64 verified by `.agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py` (no `.dynamic`, no `INTERP`, no W+X segments).
   - Application layers (`src/core/`, `src/tui/`, `src/fs/`, `src/ui/`, `src/app/`) are **100% portable freestanding C23** (`-ffreestanding`, compiler headers `<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<stdarg.h>`, and `include/duop_*.h` only).
   - Platform-specific syscalls, kernel structs, and SIMD live exclusively in the compile-time assembly PAL (`src/os/<os>/<arch>/` and `include/os/<os>/<arch>/pal_target.inc`).
2. **Strict Downward Layering** (enforced by `check_modularity.py`):
   - `include/` → `src/os/` → `src/core/` → `src/tui/` / `src/fs/` → `src/ui/` → `src/app/`.
3. **Lean Module Budgets** (enforced by `check_lean.py`):
   - Source files (`.c` / `.s`) ≤ **500 lines**, functions ≤ **80 lines**, ≤ **16 non-`static` functions** per file, stack frame ≤ **4608 bytes**.
   - headers (`.h` / `.inc`) ≤ **400 lines**, test files (`tests/*.py`) ≤ **500 lines**.
4. **Every Return Value Checked**:
   - `os_*`, `mem_alloc`/`mem_realloc`, `path_join`, `sys_write_all`, `sys_read_retry`, and `tmp_*` are `[[nodiscard]]` under `-Werror`. Every allocation must be checked for `NULL`.
5. **Localization**:
   - Every user-visible string belongs in `include/types.inc` (`LangStrings`), `src/tui/i18n_en.lang`, and `lang/uk.lang`.

---

## Build & Verification Workflow (TDD-First)

### 1. Prerequisites
- Linux (`x86_64` or `aarch64`), `binutils`, `make`, `python3`, `gcc >= 13` (on `x86_64`), and `clang` + `binutils-aarch64-linux-gnu` + `qemu-user` (for cross-arch verification).

### 2. Enable Git Hooks
```bash
make hooks
```

### 3. Write or Update a Test First (`tests/test_*.py`)
Every feature or bugfix starts with a deterministic test in `tests/` (using `tests/pty_session.py` for end-to-end PTY interaction or headless C harnesses).

### 4. Run Full Verification
```bash
./.agents/skills/duop-pty-verify/scripts/verify_build.sh
```
Or run the parallel test suite directly:
```bash
make test
```

### 5. Commit Convention
Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `refactor:`, `perf:`, `docs:`, `test:`, `build:`, `chore:`). By submitting a contribution, you agree that your work is licensed under the [MIT License](LICENSE).
