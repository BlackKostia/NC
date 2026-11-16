---
name: duop-destructive-ops-guard
description: >-
  Guards destructive filesystem operations (rename, move, overwrite, O_TRUNC) so
  existing files are never clobbered without RENAME_NOREPLACE, O_EXCL, or user confirmation.
---

# Duop Destructive Operations Guard (`duop-destructive-ops-guard`)

Never silently overwrite an existing destination file.

## Rules

1. **`renameat2` with `RENAME_NOREPLACE`:** use `RENAME_NOREPLACE` when moving/renaming unless the user explicitly confirmed overwriting the target in `ConflictDialog`.
2. **`O_TRUNC` / `O_CREAT` safety:** never open an existing target with `O_TRUNC` without prior conflict resolution and `O_NOFOLLOW` (so a symlink cannot redirect truncation outside the target directory).
3. **Same-inode guard:** always verify `(dev, ino)` of source and destination differ before `O_TRUNC` or `unlink`.
