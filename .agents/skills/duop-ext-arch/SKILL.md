---
name: duop-ext-arch
description: Enforces Duop architectural philosophy, strict downward layering, zero-libc ABI contracts, and forward-compatible extension boundaries when adding features or plugins.
---

# Duop Extension & Core Architecture Guardrails

Use this skill whenever designing or modifying Duop subsystems, package/plugin contracts, or cross-layer integrations.

## Core Philosophy (Non-Negotiable)
1. **Static zero-`libc` ELF64**: Never introduce external shared library or third-party code dependencies (no `libc`, no `dlopen`, no `.dynamic`). Initialised writable `.data` is allowed; binary size is measured, not gated.
2. **Instant Startup & Lazy Work**: Never scan packages, registries, or large trees during startup unless explicitly requested by CLI flags (`duop pkg ...`) or user action (`Alt+K`, `Alt+U`, `PopupMenu`, `PreviewPane`).
3. **Out-of-Process Extensions**: All third-party tools, previewers, and VFS providers MUST run as isolated child processes (`fork` + `execve` + `pipe` / `wait4`), never via `/bin/sh -c` on untrusted filenames.
4. **Strict Downward Layering**:
   - `include/` -> `src/os/<os>/<arch>/` -> `src/core/` -> `src/tui/` -> `src/fs/` -> `src/ui/` -> `src/app/` -> `src/main.s` / `src/app/main.c`.
   - `src/fs/` (`pkg_*`) MUST NEVER call `ScreenBuffer_*`, `i18n_get`, `App_*`, or UI widgets directly.
   - `src/ui/` reaches the application only through the `App_*` service interface (`include/duop_app.h`), never its internals; `src/fs/` must not reference `main` (`g_envp` lives in core).

## Forward-Compatibility Contracts
- **Manifest Keys (`manifest.ini`)**: Parsers MUST ignore unknown `key = value` lines so newer manifests work on older Duop versions.
- **Zero-copy / Fixed Structs**: Keep `PkgEntry` (`296` B), `PkgAction` (`576` B), and `PkgRegEntry` (`512` B) aligned to 8 bytes with documented offsets in the header / source that owns them (`_Static_assert` in C).
- **Safe Path Hygiene**: Always validate package names and archive entry paths against empty strings, leading `/`, and `..` segments before `path_join`.
- **Lean-Module Discipline**: Any new subsystem goes into a dedicated `src/<layer>/<topic>.c` (`<= 500` lines, functions `<= 80` lines, `<= 16` non-static symbols; assembly only for the PAL).
