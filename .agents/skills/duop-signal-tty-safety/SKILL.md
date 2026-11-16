---
name: duop-signal-tty-safety
description: >-
  Enforces complete signal handling, sigaltstack for stack-overflow faults,
  registered-only SIGBUS recovery, and guaranteed terminal restoration on exit/fault.
---

# Duop Signal & TTY Safety (`duop-signal-tty-safety`)

Signal handlers and terminal state transitions must never leave the user's shell in raw mode or mask fatal faults.

## Rules

1. **Terminal restoration:** every exit path and fatal signal handler (`pf_fatal_default` in `pal_fault.s`) must call `os_term_restore` and emit the TTY reset sequence (`?1000l`, `?1002l`, `?1006l`, `?1049l`, `?25h`).
2. **SIGBUS isolation:** only patch `SIGBUS` when `si_addr` falls inside a registered `os_mmap_file_ro` region; any other `SIGBUS` must invoke default signal termination.
3. **`sigaltstack` & signal matrix:** install `SA_ONSTACK` with a dedicated alternate stack so stack-overflow `SIGSEGV` can still restore the terminal; verify with `tools/faultlab/probes.py` and signal matrix checks.
