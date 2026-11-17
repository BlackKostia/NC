---
name: duop-seu-hardening
description: >-
  Guides Single-Event Upset (SEU) hardening: post-copy verification, checksums
  for critical control structures, and campaign.py seu bit-flip testing.
---

# Duop SEU Hardening (`duop-seu-hardening`)

Critical state and data transfers must detect silent corruption.

## Rules

1. **Post-copy & archive verification:** verify critical transfers/extractions with `crc32_update` or `sha256` (`src/core/hash.c`) before committing or deleting sources.
2. **Critical struct invariants:** validate magic numbers, bounds, and state tags before dispatching on `ArcCtx`, `TaskShared`, `DirModel`, or config structures.
3. **SEU testing:** run bit-flip campaigns (`python3 tools/faultlab/campaign.py seu <scenario>`) before releases or after modifying core/fs state machines.
