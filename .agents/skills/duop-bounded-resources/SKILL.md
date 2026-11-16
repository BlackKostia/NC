---
name: duop-bounded-resources
description: >-
  Enforces bounded stack depth, forbids unbounded recursion on arbitrary directory
  trees, and requires explicit user-facing limits when caps are reached.
---

# Duop Bounded Resources (`duop-bounded-resources`)

Directory trees and untrusted inputs can be arbitrarily deep or large; Duop must never blow the stack or silently drop data.

## Rules

1. **No unbounded recursion:** directory traversal (`copy`, `delete`, `du`, `search`, `fuzzy`) must use explicit heap-allocated work stacks or bounded recursion with a hard depth limit.
2. **Stack depth budget:** keep per-frame stack usage small and verify worst-case call-graph stack depth with `python3 tools/faultlab/audit_stack_depth.py` (against debug `duop`).
3. **Explicit limit warnings:** whenever a hard limit (`ARC_MAX_FILE`, `ARC_MAX_ENTRIES`, `PATH_MAX`, depth cap) is hit, report a clear localized `StatusBar` message rather than silently truncating.
