---
name: duop-lean-modules
description: >-
  Keeps Duop modules short, single-purpose and well structured. Use before creating or
  growing any src/*.s, include/*.inc or tests/*.py file, when a lean-gate (LEAN:) error or
  hook denial appears, or when splitting/refactoring large modules and long routines.
---

# Duop Lean Modules (`duop-lean-modules`)

Small modules are the project's main readability and review tool: one file = one cohesive
responsibility, one routine = one job, a narrow public API.

## 1. Budgets (enforced)

| Kind | Module | Routine | Public API |
| :--- | :--- | :--- | :--- |
| `src/**/*.s` | ≤ 600 lines (aim 200–400) | top-level label ≤ 120 lines | ≤ 24 `.global` symbols |
| `include/**/*.inc` | ≤ 400 lines | — | — |
| `tests/*.py` | ≤ 700 lines | `def` ≤ 150 lines | — |

Legacy offenders are frozen in `scripts/lean_baseline.json` as a **ratchet**: they may only
shrink. New files and new routines must meet the budgets. After shrinking legacy code run
`--update` to tighten the ratchet (it never loosens).

## 2. Where it is enforced

- **Agent hooks** (`.agents/hooks/duop_lifecycle.py`, Claude adapter): a `Write` that would
  exceed a budget is denied; after an `Edit` the file is re-checked and violations are fed
  back immediately.
- **`verify_build.sh`** step 1 runs the full gate on the working tree; **`.githooks/pre-commit`**
  checks the staged content of the files being committed (`--staged`).
- `tests/test_lean_gate.py` checks the checker itself.

```bash
python3 .agents/skills/duop-lean-modules/scripts/check_lean.py            # full gate
python3 .agents/skills/duop-lean-modules/scripts/check_lean.py --report   # biggest offenders
python3 .agents/skills/duop-lean-modules/scripts/check_lean.py --update   # tighten ratchet
```

## 3. How to stay lean

1. **Before adding code, pick the home**: if the target module is above ~450 lines or the
   feature is a separate concern, create `src/<layer>/<topic>.s` (register in `Makefile`
   `SRCS`/`PAL_SRCS`, keep layer rules from `duop-modular-asm`).
2. **Split by responsibility, not by size**: widget rendering vs. input handling vs. layout
   (`file_pane_render.s`, `file_pane_input.s`), model loading vs. sorting vs. caching
   (`dir_model.s`, `dir_sort.s`, `dir_cache.s`), parser vs. applier.
3. **Long routine → named helpers**: extract each commented block (`# Row 3: progress bar`)
   into a local routine (`pd_draw_bar:`); keep the parent as a short sequence of calls.
4. **Narrow API**: export only what other modules call; helpers stay unexported labels.
5. **Data out of code**: tables (`.rodata`), constants (`config.inc`), structs (`types.inc`)
   instead of repeated instruction sequences.
6. **Tests mirror modules**: one focused suite per subsystem (`tests/test_<topic>.py`),
   shared helpers imported from `test_pty.py`.
7. After a split: `verify_build.sh`, then `check_lean.py --update`, commit as `refactor(...)`.
