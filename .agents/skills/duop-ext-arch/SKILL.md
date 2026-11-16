---
name: duop-ext-arch
description: Enforces Duop architectural philosophy, strict downward layering, zero-libc ABI contracts, and forward-compatible extension boundaries when adding features or plugins.
---

# Duop Extension & Core Architecture Guardrails

Use this skill whenever designing or modifying Duop subsystems, package/plugin contracts, or cross-layer integrations.

## Core Philosophy (Non-Negotiable)
1. **Static zero-`libc` ELF64**: Never introduce external shared library dependencies, `dlopen`, or writable `.data` (`ELF .data == 0`).
2. **Instant Startup & Lazy Work**: Never scan packages, registries, or large trees during startup unless explicitly requested by CLI flags (`duop pkg ...`) or user action (`Alt+K`, `Alt+U`, `PopupMenu`, `PreviewPane`).
3. **Out-of-Process Extensions**: All third-party tools, previewers, and VFS providers MUST run as isolated child processes (`fork` + `execve` + `pipe` / `wait4`), never via `/bin/sh -c` on untrusted filenames.
4. **Strict Downward Layering**:
   - `include/` -> `src/os/<os>/<arch>/` -> `src/core/` -> `src/tui/` -> `src/fs/` -> `src/ui/` -> `src/app/` -> `src/main.s`.
   - `src/fs/` (`pkg_*.s`) MUST NEVER call `ScreenBuffer_*`, `i18n_get`, `App_*`, or UI widgets directly.
   - `src/ui/` MUST NOT depend on `src/app/`.

## Forward-Compatibility Contracts
- **Manifest Keys (`manifest.ini`)**: Parsers MUST ignore unknown `key = value` lines so newer manifests work on older Duop versions.
- **Zero-copy / Fixed Structs**: Keep `PkgEntry` (`296` B), `PkgAction` (`576` B), and `PkgRegEntry` (`512` B) aligned to 8 bytes with documented offsets at the top of the `.s` file.
- **Safe Path Hygiene**: Always validate package names and archive entry paths against empty strings, leading `/`, and `..` segments before `path_join`.
- **Lean-Module Discipline**: Any new subsystem goes into a dedicated `src/<layer>/<topic>.s` (`<= 500` lines, routines `<= 80` lines, `<= 16` `.global` symbols).
