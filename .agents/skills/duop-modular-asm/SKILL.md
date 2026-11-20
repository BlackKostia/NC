---
name: duop-modular-asm
description: >-
  Guides modular Duop development under the hybrid architecture: new code is freestanding C23 (src/**/*.c, C_SRCS,
  include/duop_*.h); assembly is for the per-OS/ISA PAL, SIMD and not-yet-migrated modules (src/**/*.s, SRCS). Use when
  creating, splitting or refactoring modules, adding OOP classes/vtables, syscalls, structs, or registering objects in Makefile.
---

# Duop Modular Workflow (C23 + assembly PAL)

Keep every Duop subsystem small, decoupled, zero-libc, single-purpose. **All application modules (`core/tui/fs/ui/app`) are freestanding C23**; assembly lives exclusively in `src/os/<os>/<arch>/` (syscalls, signals, SIMD, thread/pty/uring, `_start`) and `Makefile` `SRCS` is empty (`docs/HYBRID_PORTABILITY_PLAN.md`).

## Layer Ownership & Dependency Matrix

| Layer | Directory | Allowed dependencies | Forbidden |
| :--- | :--- | :--- | :--- |
| Contracts | `include/` | other headers | code / writable data; kernel structs outside `include/os/` |
| OS PAL | `src/os/<os>/<arch>/` | `include/pal.inc`, `include/os/<os>/<arch>/*` | `tui/*`, `fs/*`, `ui/*`, `app/*` |
| Core | `src/core/` | headers, PAL (`os_*`), other `core/*` | raw `syscall`, kernel structs, upper layers |
| TUI | `src/tui/` | + `core/*` | `fs/*`, `ui/*`, `app/*` |
| FS | `src/fs/` | + `core/*`, `i18n_get` | `ScreenBuffer_*`, `Input_*`, `theme_*`, `ui/*`, `app/*` |
| UI | `src/ui/` | + `tui/*`, `fs/*`, the `App_*` service interface (`include/duop_app.h`) | raw `syscall`, app internals |
| App | `src/app/` (`main.c`, `app*.c`) | all layers below | raw `syscall`, god-functions |

## Adding a module (C, the default)

1. Pick the narrowest layer (config/hash/timers -> `core`; terminal/i18n/input -> `tui`; listing/IO/VFS/trash/tasks -> `fs`;
   one widget or dialog per file -> `ui`, never growing `dialogs`/`file_pane`; controller -> `app`).
2. **Contracts**: C structs/prototypes in `include/duop_<layer>.h` (fixed-width fields, `_Static_assert(sizeof/offsetof)`);
   layouts shared with assembly mirror `include/types.inc`/`classes.inc` and are compared by `tests/test_abi_layouts.py`.
   Kernel constants -> `include/duop_pal.h` + `include/os/<os>/<arch>/pal_target.inc` (+ `tools/abi_entries.def`).
3. **Module rules**: only compiler headers (`<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<stdarg.h>`) and `duop_*.h`; kernel only
   through `os_*`; failures are `-errno` (`os_is_err`); file-scope data may be initialised (`.data` is allowed; `const` -> `.rodata` and zero -> `.bss` preferred); functions
   <= 80 lines, <= 16 non-static, file <= 500 lines; unaligned parser reads via `load_le16/32/64`; no VLA/alloca/float/`__int128`.
4. **Register** the file in `Makefile` `C_SRCS` (and its test in the `test:` list); add a `PATH_TEST_RULES` entry in
   `tests/run_smart_tests.py`.
5. **Validate**: `check_modularity.py`, `check_lean.py`, `tools/check_c_syntax.py`, `make audit-all`, `make symbols`.

## Adding assembly (PAL / SIMD only)

`.intel_syntax noprefix` (x86-64) or GNU ARM syntax (AArch64), immutable data in `.rodata`, mutable in `.bss` (or initialised `.data`), System V /
AAPCS64 registers and alignment, `.global` only for the public API, registered in `PAL_SRCS` (or `PAL_START_SRCS`) for **every** `ARCH` with the
same symbols. Never add new non-PAL `.s` modules (`SRCS` must remain empty); after editing PAL assembly run `audit_stack_abi/cfg_stack/syscall_clobber/
abi_regs/oop_vtables/fd_eintr` (`make audit-all`).
