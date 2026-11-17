---
name: duop-durable-io
description: >-
  Enforces durable file writes (temp file + fsync + close check + atomic rename)
  and source verification before deleting the original during move/save operations.
---

# Duop Durable I/O (`duop-durable-io`)

Any operation that writes or replaces persistent user data (config, bookmarks, hex-edit saves, file copies/moves) must be crash-safe.

## Rules

1. **Write-to-temp + `fsync` + `rename`:** write new contents to a unique sibling temp file (`O_CREAT | O_EXCL | O_NOFOLLOW`), flush with `fsync`, check the `os_close` / `OS_CLOSE` return value (do not ignore `-EIO`/`-ENOSPC` on close), then atomically replace via `renameat`.
2. **Verify before delete:** on cross-filesystem `move`, verify full byte count written and `close()` success on the destination before unlinking the source file.
3. **Partial writes:** always loop the write until all bytes are written or a non-`-EINTR` error occurs (`sys_write_all`; a short write is `-EIO`, never success).

C helpers: `tmp_open_atomic(final, tmp_buf, mode)` + `sys_write_all` + `tmp_commit_atomic(fd, tmp, final, write_rc)` (fsync, close check, rename, directory fsync; a negative `write_rc` aborts and unlinks the temp) implement rules 1–3; `fs_write_file`, `nav_persist.c` and `trash_info.c` are the reference users.
