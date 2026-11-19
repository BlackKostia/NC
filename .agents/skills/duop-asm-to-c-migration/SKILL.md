---
name: duop-asm-to-c-migration
description: >-
  Method for moving one Duop assembly module to freestanding C23 without behaviour change: freeze the .s as an oracle,
  write the C with the same ABI contract, prove equality with a differential harness plus mutation checks, run the
  gates and commit. Use whenever a src/**/*.s module is replaced by src/**/*.c (docs/HYBRID_PORTABILITY_PLAN.md).
---

# Duop asm → C migration (`duop-asm-to-c-migration`)

One module (or one tightly coupled cluster) per commit. The C replaces the `.s` **symbol for symbol**; the unchanged asm
callers keep working because the C honours the exact System V contract of the old routine.

## 1. Steps

1. **Read the asm** and write down every exported symbol, its register contract and its quirks (what it returns in
   `rax`/`eax`/`rdx`, which struct offsets it touches, what happens on error / OOM / overlong input).
2. **Freeze the oracle**: `git mv src/<l>/<m>.s tests/harness/<m>_reference.s`, prepend
   `# Frozen reference oracle: the hand-written asm that <new files> replaced (tests/test_c_<topic>.py diffs against it)`.
   Remove it from `Makefile` `SRCS`, add the new `.c` to `C_SRCS` and the new test to the `test:` list.
3. **Test first** (`duop-tdd-first`): `tests/harness/<topic>_cli.c` (freestanding, `duop_main`, links the oracle renamed with
   `c_harness.rename_defined_globals(objs, "ref_")` next to the C module; scripted via stdin, **one implementation per
   process** when state is global; real files in two identically built trees compared with a tree snapshot — never read a
   FIFO) and `tests/test_c_<topic>.py` (random + boundary + real-filesystem cases; assert the generator really reaches
   interesting branches).
   - For **`src/ui/` & `src/app/`** migrations (`src/core`, `src/tui`, `src/fs` are 100% C23): reuse `tests/harness/ui_render.h`
     (synthetic 29-colour theme + cell-by-cell dump), `tests/harness/ui_event.h` (scripted key/mouse/resize events),
     `tests/harness/ui_app_stub.h` (zeroed `App`, mutable English `i18n_get`, call logger), `build/duop_classes.h`,
     `include/duop_ui.h` (`WIDGET_VTBL`/`DIALOG_VTBL`/`DUOP_NEW`/`WIDGET_CALL`/`DIALOG_CALL`/`DUOP_TRY_BEGIN`),
     `include/duop_app.h`, and `c_harness.perf_gate` for hot render paths. Copy `tests/test_c_status_bar.py` or `tests/test_c_ui_leaf1.py`.
   - `tests/c_harness.py` caches compiled PAL and repo C objects in `/dev/shm/duop_obj_cache_<uid>` (atomic writes; bypass via `DUOP_NO_TEST_CACHE=1`),
     so mutation checks only recompile the mutated/harness unit.
4. **Write the C** under the layer rules (`AGENTS.md` §1) with prototypes in `include/duop_<layer>.h`; no libc headers.
5. **Mutation check**: apply 6–10 one-line mutations (limits ±1, flags dropped, comparison flipped, lock removed) with `sed`
   and require the test to fail for each; add a targeted case for every survivor unless the mutant is behaviourally
   equivalent (document it).
6. **Gates**: `make -j8`, `make symbols`, `check_lean.py --update`, `check_modularity.py`, `make audit-all`,
   `tests/test_c_stack_align.py`, `tools/check_c_syntax.py <files>` (x86_64 + aarch64), `tools/faultlab/audit_null_alloc_c.py`,
   `size duop` (reported only; no `.data`/size gate, but no `libc`/dynamic/W+X: `audit_elf_hardening.py`), plus the PTY suites that exercise the module (`tests/run_smart_tests.py --files ...`).
7. **Fix what the tests reference**: grep `tests/*.py`, `run_smart_tests.py` and `.agents/skills/*/scripts` for the old
   `.s` file name (e.g. `test_medium_fixes` M4 reads sources); map the new C files in `PATH_TEST_RULES`.
8. **Commit** `refactor(<layer>): <what> moves to C23 (vX.Y.Z)` with a body that states: the contract kept, defects found
   in the asm and fixed, what the tests cover, and `Test:` lines (mandatory for `fix(...)`). The hook is tiered: a
   module-local commit runs the smart tests; the full `make test` runs in `pre-push`.

## 2. Contract rules (what broke before)

- **Width of results**: asm callers test `rax` or `eax`. Return `intptr_t` for `-errno`, `int` only where every caller uses
  `eax`; a `void` C function silently broke a caller that tested the sign. Pair results (`rax:rdx`) are a struct of two
  `uint64_t`. Never rely on a caller-saved register surviving a call in either direction (`audit_live_regs.py`).
- **Stack**: asm callers often leave `rsp` 8 bytes off the 16-byte call alignment, so C must not use aligned SSE stack
  stores (`tests/test_c_stack_align.py`). A frame above 4608 B (`-Wframe-larger-than`) moves to `mem_alloc`. Recursion is
  bounded and its frames small (worker-thread stacks are 64 KiB).
- **Data**: initialised writable globals (`static int wd[2] = {-1,-1}`) are allowed and land in `.data`; keep `const`
  tables in `.rodata` and zero state in `.bss` where that is natural. Struct layouts mirror `include/types.inc` / `classes.inc`
  (`#pragma pack(4)` for `DirModel`), checked by `tests/test_abi_layouts.py`.
- **Errors**: every `os_*`, `mem_alloc`, `path_join`, `tmp_*`, `sys_write_all` result is checked ([[nodiscard]] +
  `-Werror`); allocate before mutating a container; keep the asm's limits (`PATH_MAX`, caps) and report instead of
  truncating. A deliberate behaviour fix is allowed only when the asm was wrong — say so in the commit.
- **Portability**: kernel details only through `os_*` / `duop_pal.h` constants (new constants also go to
  `tools/abi_entries.def` with the kernel header in `tools/abi_verify.c`); unaligned reads via `load_le*`; no `asm("syscall")`.
- **Threads/fork**: qemu-user rejects `clone()` without `CLONE_SYSVSEM`, so aarch64 runs thread scenarios serially.

## 3. Work while the hook runs

The pre-commit hook tests the working tree: do not edit tracked files during a commit. Draft the next module in the
scratchpad (new untracked files are safe) and apply it afterwards.
