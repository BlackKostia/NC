---
name: duop-docs-sync
description: Keeps Duop user and developer documentation (docs/, README*.md, ROADMAP.md) synchronized whenever new features, CLI commands, hotkeys, or extension APIs are added.
---

# Duop Documentation Synchronization

Use this skill whenever implementing a new feature, CLI subcommand, hotkey, configuration option, or extension capability.

## Documentation Map
- `docs/USER_GUIDE.md` — end-user workflows, dialogs, package manager UI (`Alt+K`), and CLI usage.
- `docs/HOTKEYS.md` — all keyboard shortcuts (`Alt+K`, `Alt+U`, `F9`, etc.).
- `docs/EXTENSIONS_GUIDE.md` — package structure, `manifest.ini` keys, placeholders, registry, and VFS protocol.
- `docs/SYMBOLS.md` — auto-generated framework & architecture symbol catalog (structs, `CLASS_BEGIN` OOP classes, `VTBL_*` contracts, and `.global` APIs per layer).
- `ROADMAP.md` — milestone & feature status tracking.
- `README.md` / `README.uk.md` — high-level overview & quick start.

## Mandatory Sync Checklist
When adding or changing:
1. **New hotkey or UI action** -> update `docs/HOTKEYS.md` and `docs/USER_GUIDE.md`.
2. **New `manifest.ini` field, placeholder, or `duop pkg` subcommand** -> update `docs/EXTENSIONS_GUIDE.md`.
3. **New architectural phase or milestone** -> update `ROADMAP.md` (and `docs/EXTENSIONS_AUDIT_AND_PLAN.md` if extension-related).
4. **Keep EN/UA parity** when editing localized user-facing docs (`README.md` / `README.uk.md`).
5. **Any new struct, OOP class, vtable slot, or `.global` symbol** -> regenerate `docs/SYMBOLS.md` via `make symbols` (verified automatically by `make symbols-check` and `.githooks/pre-commit`).

6. **Hybrid migration** (`docs/HYBRID_PORTABILITY_PLAN.md`): after every migrated module update the execution log table (stage rows, module and file counts, defects found) and `docs/SYMBOLS.md` (`make symbols`; the pre-commit hook checks it).
