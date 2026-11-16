---
name: duop-liveness-timeouts
description: >-
  Prevents UI hangs: forbids unbounded blocking calls in the main UI loop, requires
  timeouts on child/helper processes, and enforces clean exit on stdin EOF.
---

# Duop Liveness & Timeouts (`duop-liveness-timeouts`)

The UI event loop must never hang indefinitely on a pipe, FIFO, child process, or closed terminal.

## Rules

1. **No blocking I/O in UI:** never open unknown paths (e.g. FIFOs) without `O_NONBLOCK` in the UI process; delegate blocking previews to `preview_helper.s` or background workers.
2. **Helper timeouts & non-blocking `wait4`:** bound helper processes (`git_status`, previewers, external tools) with timeouts or non-blocking polling so a wedged child cannot freeze the TUI.
3. **Clean EOF exit:** when `stdin` returns EOF (`read == 0`) or `-EIO` in `input_next_event`, exit the event loop cleanly and restore the terminal.
