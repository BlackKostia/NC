---
name: duop-fault-injection
description: >-
  Runs faultlab fault-injection campaigns (tools/faultlab/campaign.py and probes.py)
  after every change to src/fs/, src/core/, or src/os/ to catch OOM, I/O, signal,
  and crash bugs under real syscall failure injection.
---

# Duop Fault Injection (`duop-fault-injection`)

Every change to `src/fs/`, `src/core/`, or `src/os/` must be exercised under real syscall/signal fault injection using `tools/faultlab/`.

## Workflow

1. Build the debug binary (`make`) so `tools/faultlab/audit_stack_depth.py` and `faultlab` have symbols.
2. Run deterministic PTY probes:
   ```bash
   python3 tools/faultlab/probes.py
   ```
3. Run a short campaign on the affected scenario (`copy`, `copy_x`, `delete`, `move`, `move_x`, `tree`, `tree_x`, `ui`):
   ```bash
   python3 tools/faultlab/campaign.py short <scenario>
   ```
4. For release/pre-push verification, run full sweeps (`campaign.py sweep <scenario>`) and enforce the **0 `CRASH_UI` / `HANG` / `DATA_LOSS` / `SILENT_CORRUPTION`** budget.
