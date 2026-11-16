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
| `src/**/*.s` | ≤ 500 lines (aim 150–300) | top-level label ≤ 80 lines | ≤ 16 `.global` symbols |
| `include/**/*.inc` | ≤ 400 lines | — | — |
| `tests/*.py` | ≤ 500 lines | `def` ≤ 100 lines | — |

Legacy offenders are frozen in `scripts/lean_baseline.json` as a **ratchet**: they may only
shrink. New files and new routines must meet the budgets. `PostToolUse` in
`.agents/hooks/duop_lifecycle.py` automatically runs `--update` whenever a file shrinks so
the ratchet tightens immediately (it never loosens).

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

## 4. Mechanical splitters (semantics-preserving)

```bash
S=.agents/skills/duop-lean-modules/scripts
python3 $S/split_routine.py src/ui/foo.s            # long routines -> Routine__step helpers
python3 $S/split_module.py --names foo_render,foo_input src/ui/foo.s   # file -> sibling modules
python3 $S/check_lean.py --migrate                   # re-key legacy debt to the moved code
```

- **`split_routine.py`** cuts a routine at its step comments into *frame-sharing steps*
  `Routine__<step>` (`lea rsp,[rsp-8]` … `ret`). A step runs on its caller's stack frame: its
  operands that address the caller's frame carry an explicit `+ 16` (return address + pad),
  slots pushed inside the step keep their offsets. Every step is single-entry/single-exit;
  all control flow between steps stays in the parent. A block is rejected (left inline) if it
  has inbound jumps, unbalanced stack, `ret`/indirect jumps, `rsp` writes, pointers to its own
  stack slots, red-zone access, calls to routines reading stack-passed arguments, or calls to
  other steps (steps never nest). Helpers are placed after a routine that cannot fall through.
- **Hot inner loops stay whole** (`HOT_ROUTINES`: allocator, sorts, UTF-8, SHA-256, screen
  flush, dirent streaming, ...): a step call per iteration costs real time. These and big
  state machines (`input_poll_event`, `StatusBar_render`) need a hand-made redesign
  (proper functions with their own frames / a context struct), not mechanical cuts.
- **`split_module.py`** keeps fall-through chains, `.L`-sharing units and `Parent__step`
  families together, moves data next to its main user, adds `.global` only for cross-part
  symbols, copies the prelude (`.include`/`.equ`/`.struct`/`.macro`) and registers new parts
  in `Makefile` `SRCS`. PAL backends are not split (`PAL_SRCS` must match across arches).
- **`check_lean.py --migrate`** lets a part (header `(split from X.s)`) or a moved routine
  inherit at most its origin's frozen limit; anything that would grow is refused.
- `tests/test_lean_split.py` assembles, runs and splits small programs to prove the result is
  unchanged (frame offsets, fall-through, stack arguments, module split).
