---
name: duop-reliability-audit
description: Static and runtime reliability, stack-frame bounds, struct-size, OOP vtable, FD/-EINTR, C11 kernel ABI, ELF hardening, strace leak, fuzz and fault-injection verification for Duop's assembly and freestanding C. Use whenever editing src/**/*.s, src/**/*.c or include/**, or auditing filesystem/syscalls/parsers.
---

# Duop Reliability & Fault-Tolerance Audit

This skill provides a multi-layer reliability verification suite (Python + C11 + `readelf` + `strace` + `MEMCHECK=1`) to catch silent memory corruption, undersized stack frames, overlapping buffers, ABI register clobbers, OOP vtable mismatches, FD/-EINTR gaps, and kernel ABI drift in the x86-64 assembly (and, through the C gates below, the freestanding C that replaces it).

## Core Utilities

1. **`scripts/audit_stack_abi.py`** — Parses all `.struct` & `CLASS_BEGIN` sizes/constants from `include/**/*.inc` (`FileStat._size = 56`, `PATH_MAX = 4096`, etc.) and audits every routine in `src/**/*.s` for undersized frames, overlapping stack slots (including `Routine__step` `+16` offsets), `lea rsp, [rsp - 8]`/`[rsp + 8]` symmetry, and `sub`/`add rsp` mismatches.
2. **`scripts/audit_cfg_stack.py`** — Control-Flow Graph (CFG) stack balance auditor simulating stack depth across branches to verify every reachable `ret` / tail-call exits with balanced `rsp`.
3. **`scripts/audit_syscall_clobber.py`** — Detects live values in `rcx` or `r11` written before and read after `OS_*` / `syscall` (Linux x86-64 `syscall` clobbers `rcx`/`r11`).
4. **`scripts/audit_abi_regs.py`** — Audits exported `.global` System V AMD64 routines (`--all` for private helpers) for callee-saved register preservation (`rbx`, `rbp`, `r12`–`r15`).
5. **`scripts/audit_oop_vtables.py`** — Parses `VTBL_BEGIN`/`VTBL_EXTENDS`/`VTBL_SLOT` from `include/classes.inc` and verifies every `*_vtable:` in `src/**/*.s` has the exact slot count and macro layout.
6. **`scripts/audit_fd_eintr.py`** — Verifies `OS_OPENAT` calls include `O_CLOEXEC` (excluding child `dup2` redirects) and `OS_WAIT4` loops handle `-EINTR`.
7. **`tools/abi_verify.c`** — C11 verifier compiled with `gcc` that checks `include/os/linux/x86_64/pal_target.inc` constants (`KSTAT_*`, `KSTATX_*`, `KDIRENT_*`, `O_*`, `WINSIZE_*`, `POLLFD_*`) against live Linux kernel headers (`sizeof`/`offsetof`).
8. **`scripts/audit_elf_hardening.py`** — Verifies `duop` ELF64 binary via `size`/`readelf`: `.data == 0`, non-executable `PT_GNU_STACK` (no `RWE`), zero `PT_INTERP` and `TEXTREL`.
9. **`scripts/audit_runtime_leaks.py`** — Runs `duop` under `strace` in a real PTY (`F3` viewer, `F5` copy, `F10` quit) and verifies balanced `mmap`/`munmap` and FD cleanup.
10. **`tests/test_reliability_audit.py` & `tests/test_fault_injection.py`** — End-to-end PTY reliability tests (`copy_subdir`, `copy_reg_at` `EEXIST` rename), corrupted/truncated image (`PNG`/`JPEG`/`GIF`/`BMP`/`TGA`/`PNM`) & config/lang fuzzing, `PATH_MAX` (>4096B) tree boundary, and parallel `DU` stress under `MEMCHECK=1`.
11. **C counterparts (hybrid codebase)** — `tools/check_c_syntax.py` (project CFLAGS, x86_64 gcc + aarch64 clang, `-Werror`, `-Wframe-larger-than=4608`), `tools/faultlab/audit_null_alloc_c.py` (allocation result used before a NULL test), `[[nodiscard]]` + `-Werror=unused-result` on `os_*`, `mem_alloc/realloc`, `path_join`, `sys_write_all`, `tmp_*` (ignored errors do not compile), `tests/test_c_stack_align.py` (no aligned SSE stack access: asm callers leave `rsp` 8 off), `audit_elf_hardening.py` (`.data == 0`), `audit_live_regs.py` and `audit_stack_depth.py` (both read the linked ELF, so they cover C too), `tests/test_abi_layouts.py` / `test_abi_cross.py`.
12. **`TRY_BEGIN / TRY_END` & `USING_FD_* / SCOPED_MEM_*` (`include/try_using.inc`, `src/os/linux/x86_64/pal_fault.s`)** — Zero-syscall `ucontext_t` recovery blocks for parsers/image decoders (`SIGSEGV`, `SIGBUS`, `SIGFPE`) and zero-overhead scoped FD/heap cleanup, plus `src/core/tmpfile.s` (`tmp_open_unique`, `tmp_make_path`) for PID/UID-scoped `0700` temp files.
13. **`scripts/audit_live_regs.py`** — Binary-level audit (objdump on `build/duop.sym`, built by `make build/duop.sym`): reports a caller-saved register (`rcx rdx rsi rdi r8–r11`) that is defined before a `call`, clobbered by the callee (transitively; a vtable call clobbers all) and read afterwards - the bug class the other audits cannot see (`ds_append_entry`, `arc_extract_entry`, scrollbar thumb, `handle_mouse__part2`). Routines that deliberately return in such a register (`utf8_decode` -> `rdx`, `parse_uint` -> `rdi`, ...) are listed with a written reason in `scripts/audit_live_regs_baseline.json`; `--update` records new findings as `UNREVIEWED` (the gate fails until the reason is written), stale entries fail too. Fix real hits by spilling to a frame slot / callee-saved register or reloading after the call.

## Running

```bash
make audit-all
python3 .agents/skills/duop-reliability-audit/scripts/audit_runtime_leaks.py
python3 tests/test_reliability_audit.py
python3 tests/test_fault_injection.py
```

## Integration

All fast static + C11 ABI + ELF audits run automatically in:
- `make audit-all`
- `.agents/skills/duop-pty-verify/scripts/verify_build.sh`
- `.githooks/pre-commit`
- `.agents/hooks/duop_lifecycle.py` (when editing `src/*.s` or `include/*.inc`)

## Critical-Defect Suite (`scripts/audit_critical.sh`)

Static and runtime checks for defects that crash Duop, lose data or open security holes; none of
them modify the program. Runtime checks launch Duop the way a shell does (`SIGPIPE` at its default
action: Python children inherit `SIG_IGN`, which hides real deaths) on a snapshot of `./duop`.

| Utility | Kind | Detects |
|---|---|---|
| `audit_tmp_files.py` | static | fixed `/tmp` paths opened with `O_CREAT` without `O_EXCL`/`O_NOFOLLOW`, external downloaders writing them, verify-then-reopen (TOCTOU) |
| `audit_thread_reach.py` | static | call graph from `os_thread_spawn` entries: heap allocator / UI calls and unlocked global stores reachable from worker threads |
| `audit_unchecked_io.py` | static | ignored results of write / rename / unlink / chmod in data-safety modules |
| `audit_depth_caps.py` | static | recursion / capacity caps that truncate results silently instead of reporting |
| `signal_matrix.py` | runtime | helper death (`SIGPIPE`), helper crash vs. UI tty, `SIGTERM`/`SIGINT`, fatal signals restore the terminal, hangup with `SIGHUP` ignored (spinning orphan), `SIGWINCH` storm, idle CPU |
| `security_probe.py` | runtime | package names `.`, `pkg verify` vs. tampering, checksum mismatch, planted `/tmp` symlinks, failed deletes reported as success, archive traversal names, writable/stale temp files |
| `fuzz_parsers.py` | runtime | mutation fuzzing of images (viewer), archives (VFS + inflate), `.lang`, `.layout`, `duoprc`, `manifest.ini`; crashing inputs saved |
| `proc_health.py` | runtime | wraps any command (`-- cmd`) or `--scan`s: duop processes that outlive it, without a tty, spinning; `--kill` cleans them up |
| `rt_common.py`, `asm_index.py` | library | PTY launch / status tracking; routine split, call graph, `.asciz` index |
