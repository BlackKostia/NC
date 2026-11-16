---
name: duop-oom-safety
description: >-
  Enforces OOM-safe allocation and reallocation: every mem_alloc/mem_realloc/mmap
  is checked for NULL/error, and container state is mutated only after realloc succeeds.
---

# Duop OOM Safety (`duop-oom-safety`)

Out-of-memory conditions must degrade gracefully without crashing or corrupting live data structures.

## Rules

1. **Commit-after-success on `mem_realloc`:** store the result of `mem_realloc` in a temporary register, check `test rax, rax; jz <fail>`, and only then overwrite the struct's pointer and capacity fields.
2. **No unchecked `mem_alloc` / `*_new`:** always branch to cleanup on `NULL` before touching `[rax]` or storing into parent objects.
3. **Arena reclamation:** return empty 256 KiB slab arenas via `OS_MUNMAP` (`memory.s`) and free temporary buffers on every error/fault path (`SCOPED_MEM_*`).
