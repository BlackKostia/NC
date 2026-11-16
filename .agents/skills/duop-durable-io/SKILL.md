---
name: duop-durable-io
description: >-
  Enforces durable file writes (temp file + fsync + close check + atomic rename)
  and source verification before deleting the original during move/save operations.
---

# Duop Durable I/O (`duop-durable-io`)

Any operation that writes or replaces persistent user data (config, bookmarks, hex-edit saves, file copies/moves) must be crash-safe.

## Rules

1. **Write-to-temp + `fsync` + `rename`:** write new contents to a unique sibling temp file (`O_CREAT | O_EXCL | O_NOFOLLOW`), flush with `fsync`, check `OS_CLOSE` return value (do not ignore `-EIO`/`-ENOSPC` on close), then atomically replace via `renameat`.
2. **Verify before delete:** on cross-filesystem `move`, verify full byte count written and `close()` success on the destination before unlinking the source file.
3. **Partial writes:** always loop `OS_WRITE` until all bytes are written or a non-`-EINTR` error occurs (`arc_write_all` pattern).
