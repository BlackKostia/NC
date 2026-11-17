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

## In C modules

- `os_*`, `mem_alloc`, `mem_realloc`, `path_join`, `sys_write_all`, `sys_read_retry`, `tmp_open_atomic`, `tmp_commit_atomic` are `[[nodiscard]]` and the build uses `-Werror`: an ignored result does not compile. A deliberate discard is a visible `(void)` cast (cleanup paths: `os_close`, best-effort `unlink` of a temp file).
- Errors are `-errno` (`os_is_err(r)` / `r < 0`); return `intptr_t` where asm callers test `rax`. Blocking calls retry `-EINTR` (`sys_read_retry`, `sys_write_all`).
- A pointer from `mem_alloc` / `*_new` / `nav_strdup` is tested before its first use (`tools/faultlab/audit_null_alloc_c.py`, the PreToolUse C guard and `pre-commit` enforce it; `/* null-ok */` marks a documented exception).
