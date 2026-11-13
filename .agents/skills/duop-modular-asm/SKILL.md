---
name: duop-modular-asm
description: >-
  Guides modular x86-64 GNU Assembler development in Duop. Use when creating,
  splitting, or refactoring .s modules, adding OOP classes/vtables in include/classes.inc,
  adding Linux syscalls, extending structs in include/types.inc, or registering objects in Makefile.
---

# Duop Modular Assembly Workflow

Keep every Duop subsystem small, decoupled, zero-libc, and single-purpose.

## Layer Ownership & Dependency Matrix

| Layer | Directory | Allowed Dependencies | Forbidden Dependencies |
| :--- | :--- | :--- | :--- |
| Contracts | `include/` | Other `include/*.inc` only | Code/data emission; raw OS structs outside `include/os/` |
| OS PAL | `src/os/<os>/<arch>/` | `include/pal.inc`, `include/os/<os>/<arch>/*` | `tui/*`, `fs/*`, `ui/*`, `app/*` |
| Core | `src/core/` | `include/*`, `src/os/*` PAL, other `core/*` | Raw `syscall`, kernel structs, `tui/*`, `fs/*`, `ui/*`, `app/*` |
| TUI | `src/tui/` | `include/*`, `core/*`, `src/os/*` PAL, other `tui/*` | Raw `syscall`, kernel structs, `fs/*`, `ui/*`, `app/*` |
| FS | `src/fs/` | `include/*`, `core/*`, `src/os/*` PAL, `i18n_get` | Raw `syscall`, `KSTAT_*`/`KDIRENT_*`, `Screen_*`, `Input_*`, `ui/*`, `app/*` |
| UI | `src/ui/` | `include/*`, `core/*`, `tui/*`, `fs/*` (`DirModel`/`FileEntry`) | Raw `syscall`, `app.s` internals |
| App | `src/app/`, `src/main.s` | All layers below | Raw `syscall`, kernel structs, unbounded god-functions |

## Adding a New Module (or Splitting an Existing Large Module)

1. **Choose the narrowest layer** matching the responsibility:
   - Config parser (`duoprc`), checksum/crypto, timers -> `src/core/`
   - Kitty graphics / Sixel encoder -> `src/tui/`
   - Inflate/VFS, `Trash` + Undo log, async worker `TaskQueue`, `ncdu` scanner -> `src/fs/`
   - Dedicated dialog/widget (`FuzzyDialog`, `ProgressDialog`, `ChmodDialog`, `Tabs`) -> separate file `src/ui/<widget>.s` instead of appending to `src/ui/dialogs.s` or `src/ui/file_pane.s`!
2. **Define binary contracts cleanly in `include/`**:
   - Kernel constants/syscall numbers -> `include/linux_sys.inc`
   - Feature constants/keys/flags -> `include/config.inc`
   - POD structs (`Rect`, `Event`, `FileEntry`, `Config`, `TaskItem`) -> `include/types.inc`
   - OOP structs & VTable layouts (`CLASS_BEGIN`, `EXTENDS`, `FIELD`, `VTBL_SLOT`, `WIDGET_VTBL_SLOTS`/`DIALOG_VTBL_SLOTS`) -> `include/classes.inc`
   - Keep natural alignment (8-byte pointers/qwords first, then 4-byte dwords, then 2-byte/bytes, explicit padding fields if needed).
3. **Follow the module template**:
   - Start with `.intel_syntax noprefix` and `.include "classes.inc"` (or narrower `.inc` for `core/`).
   - Place immutable metadata (class name string, vtable via `OBJECT_VTBL_SLOTS` / `WIDGET_VTBL_SLOTS` / `DIALOG_VTBL_SLOTS`) in `.section .rodata`.
   - Keep `.data` empty (`data == 0`); use `mem_alloc` (`NEW_OBJ`) for per-instance state and `.section .bss` only if truly singleton-global.
   - Export only the public API via `.global Class_method`; keep helper labels local (`camel_helper:` / `.Lprefix_label:`).
   - Preserve System V AMD64 ABI callee-saved registers (`rbx, rbp, r12-r15`) and 16-byte stack alignment across `call`.
4. **Register in `Makefile`**:
   - Add `src/<layer>/<name>.s` to `SRCS` in dependency-logical order.
5. **Validate modularity automatically**:
   ```bash
   python3 ./.agents/skills/duop-modular-asm/scripts/check_modularity.py
   ```
   Confirm zero errors and check any file-size warnings before continuing.
