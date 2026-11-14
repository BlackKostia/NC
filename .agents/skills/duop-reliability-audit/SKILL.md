---
name: duop-reliability-audit
description: Static and runtime reliability, stack-frame bounds, struct-size, OOP vtable, FD/-EINTR, C11 kernel ABI, ELF hardening, strace leak, and fuzz/fault-injection verification for Duop x86-64 assembly. Use whenever editing src/**/*.s or include/**/*.inc, or auditing filesystem/syscalls/parsers.
---

# Duop Reliability & Fault-Tolerance Audit

This skill provides a multi-layer reliability verification suite (Python + C11 + `readelf` + `strace` + `MEMCHECK=1`) to catch silent memory corruption, undersized stack frames, overlapping buffers, ABI register clobbers, OOP vtable mismatches, FD/-EINTR gaps, and kernel ABI drift in pure x86-64 assembly.

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
