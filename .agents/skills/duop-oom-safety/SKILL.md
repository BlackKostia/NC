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
3. **Arena reclamation:** return empty 256 KiB slab arenas via `os_munmap` (`src/core/memory.c`) and free temporary buffers on every error/fault path (`SCOPED_MEM_*`).

## In C modules

- **Allocate first, mutate after**: `char *dup = nav_strdup(s); if (!dup) return;` *then* bump counts / free the slot / store the pointer (the asm `nav_frecency_record` bumped the count first and left a NULL entry or a dangling pointer on OOM).
- `mem_realloc` into a temporary, publish pointer + capacity together; frames above 4608 B (`-Wframe-larger-than`) use `mem_alloc` and report `-ENOMEM`; every early return frees what was allocated (single exit label or helper).
