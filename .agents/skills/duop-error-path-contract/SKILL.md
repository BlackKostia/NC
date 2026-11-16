---
name: duop-error-path-contract
description: >-
  Enforces checking every syscall (OS_*) and allocator (mem_alloc, *_new) return
  value in src/ and propagating errors cleanly to the caller and user UI.
---

# Duop Error-Path Contract (`duop-error-path-contract`)

Never ignore return values from syscalls or memory allocations.

## Rules

1. **Every `OS_*` syscall** (`OS_OPENAT`, `OS_READ`, `OS_WRITE`, `OS_CLOSE`, `OS_RENAMEAT`, `OS_UNLINKAT`, `OS_PIPE2`, `OS_FORK`, `OS_MMAP*`) must immediately test `rax`/`eax` (`test rax, rax; js ...` or `cmp rax, -4095; jae ...`) and handle `-EINTR` (`-4`) on blocking calls.
2. **Every `mem_alloc` / `mem_realloc` / `*_new` call** must check `test rax, rax; jz <err_path>` before dereferencing, storing, or passing the pointer.
3. **User visibility**: errors in interactive operations must propagate to `StatusBar_set_message` / `App_set_status` or `TaskShared` so the user is never left with silent failure.
4. Verify statically with `python3 tools/faultlab/audit_null_alloc.py`.
