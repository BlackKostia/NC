---
name: duop-defect-regression
description: >-
  Requires every discovered bug or faultlab failure to be captured first as a
  failing regression test or probe before implementing the fix in src/.
---

# Duop Defect Regression (`duop-defect-regression`)

Every bugfix follows **Reproduce (Red) -> Fix (Green) -> Verify -> Commit**.

## Rules

1. **Failing test/probe first:** before modifying `src/` or `include/` for a `fix(...)`, add a deterministic test in `tests/test_*.py` or a probe in `tools/faultlab/probes.py` that reproduces the exact failure.
2. **Commit reference:** `fix(...)` commits must reference the reproducing test or probe (e.g., `tests/test_security_fixes.py`, `probes.py`, or `Test: ...` / `Probe: ...` in the commit message).
3. **No regressions:** run both the new test and `verify_build.sh` after the fix.
