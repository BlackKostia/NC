---
name: duop-reliability-audit
description: Static and runtime reliability, stack-frame bounds, struct-size, and System V AMD64 ABI verification for Duop x86-64 assembly. Use whenever editing src/**/*.s or include/**/*.inc, or auditing filesystem/syscalls for buffer overflows, overlapping stack slots, and register clobbers.
---

# Duop Reliability & Fault-Tolerance Audit

This skill provides deterministic static and runtime utilities to catch silent memory corruption, undersized stack frames, overlapping stack buffers, and ABI register clobbers in pure x86-64 assembly (`ELF .data == 0`, zero libc).

## Core Utilities

1. **`scripts/audit_stack_abi.py`** — Parses `.struct` sizes and constants from `include/*.inc` (e.g. `FileStat._size = 56`, `PATH_MAX = 4096`) and audits every routine in `src/**/*.s` for:
   - Undersized `sub rsp, N` frames relative to `FileStat` or other struct offsets.
   - Overlapping stack slots (`[rsp + off1]` vs `[rsp + off2]`, including `Routine__step` `+16` frame-sharing offsets).
   - Mismatched `sub rsp, N` / `add rsp, M` cleanup paths.
   - 16-byte stack alignment (`(8 + pushes*8 + frame) % 16 == 0`) before `call`.

2. **`scripts/audit_abi_regs.py`** — Audits System V AMD64 callee-saved registers (`rbx`, `rbp`, `r12`, `r13`, `r14`, `r15`) across `src/**/*.s`:
   - Detects callee-saved registers clobbered without `push`/`pop` preservation.
   - Detects asymmetric `push`/`pop` ordering across prologue and epilogue paths.
   - Validates `Routine__step` (`__` local step helpers) frame-sharing invariants.

3. **`tests/test_reliability_audit.py`** — End-to-end reliability & fault-injection suite:
   - Runs both static auditors as hard gates across `src/`.
   - Exercises deep nested directory copy (`F5` / `copy_subdir`) and `EEXIST`/same-inode/rename conflict handling (`copy_reg_at`) under real PTY/FS & `MEMCHECK=1`.

## Running Manually

```bash
python3 .agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py
python3 .agents/skills/duop-reliability-audit/scripts/audit_abi_regs.py
python3 tests/test_reliability_audit.py
```

## Integration

Both static auditors run automatically in:
- `.agents/skills/duop-pty-verify/scripts/verify_build.sh`
- `.githooks/pre-commit`
- `.agents/hooks/duop_lifecycle.py` (when verifying edited assembly modules)
