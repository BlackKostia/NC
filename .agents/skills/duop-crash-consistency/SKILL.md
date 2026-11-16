---
name: duop-crash-consistency
description: >-
  Verifies crash consistency under SIGKILL or power loss at any syscall boundary
  during copy, move, delete, rename, and state-save operations.
---

# Duop Crash Consistency (`duop-crash-consistency`)

A `SIGKILL` or power loss at any point must never leave the user with both source and destination lost, or corrupted config/bookmark files.

## Rules

1. **Atomic state updates:** never truncate a config/bookmark/history file in place; write to a temp file, `fsync`, check `close()`, and `renameat`.
2. **Move ordering:** during cross-device `move`, copy + `fsync` + `close()` check must complete before `unlink` of the source.
3. **Faultlab verification:** test crash points with `tools/faultlab/campaign.py` (`SIGKILL` / `EIO` injection) and verify 0 `DATA_LOSS` and 0 `SILENT_CORRUPTION`.
