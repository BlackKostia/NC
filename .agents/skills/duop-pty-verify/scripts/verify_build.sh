#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

MODE="full"
if [[ "${1:-}" == "--release-only" ]]; then
    MODE="release-only"
elif [[ "${1:-}" == "--smart" ]]; then
    MODE="smart"
elif [[ "${1:-}" == "--full" || -z "${1:-}" ]]; then
    MODE="full"
else
    echo "Usage: $0 [--full|--release-only|--smart]" >&2
    exit 2
fi

echo "==> [1/4] Checking Duop modularity, stack/ABI reliability & i18n contracts..."
# The pre-commit hook has just run the same gates on the staged tree (DUOP_CHECKS_DONE=1): do not repeat them
if [[ "${DUOP_CHECKS_DONE:-0}" != "1" ]]; then
    python3 ./.agents/skills/duop-modular-asm/scripts/check_modularity.py --root "$ROOT"
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_cfg_stack.py
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_syscall_clobber.py
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_abi_regs.py
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_oop_vtables.py
    python3 ./.agents/skills/duop-reliability-audit/scripts/audit_fd_eintr.py
    if command -v gcc >/dev/null 2>&1; then
        mkdir -p "$ROOT/build"
        gcc -O2 -Wall -Wextra "$ROOT/tools/abi_verify.c" -o "$ROOT/build/abi_verify"
        "$ROOT/build/abi_verify" "$ROOT/include/os/linux/x86_64/pal_target.inc"
    fi
    # Lean gate: whole working tree, or only the staged commit content when run from pre-commit
    python3 ./.agents/skills/duop-lean-modules/scripts/check_lean.py --root "$ROOT" ${DUOP_LEAN_STAGED:+--staged}
fi
# Whole tree, always: a changed header can break modules that were not staged (check_c_syntax compiles in parallel)
python3 ./tools/check_c_syntax.py $(git ls-files --cached --others --exclude-standard 'src/*.c')
python3 ./tools/faultlab/audit_null_alloc_c.py
python3 ./tests/test_lean_gate.py
python3 ./tests/test_lean_split.py
python3 ./tests/test_i18n_hook.py

VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "==> [2/4] Building stripped release binary (v${VER})..."
make -s release

echo "==> [3/4] Auditing ELF sections & --version..."
SIZE_OUT="$(size "$ROOT/duop")"
echo "$SIZE_OUT"
# .data and total size are reported, not gated: the ELF must only stay static and free of libc/third-party libraries
python3 ./.agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py "$ROOT/duop"
# Binary-level audit: caller-saved registers live across a call that clobbers them (needs the symbol table)
make -s build/duop.sym
python3 ./.agents/skills/duop-reliability-audit/scripts/audit_live_regs.py "$ROOT/build/duop.sym"

VER_OUT="$("$ROOT/duop" --version)"
if [[ "$VER_OUT" != *"v${VER}"* ]]; then
    echo "ERROR: './duop --version' output '${VER_OUT}' does not match VERSION '${VER}'." >&2
    exit 1
fi
echo "Verified binary version: $VER_OUT"

if [[ "$MODE" == "smart" ]]; then
    echo "==> [4/5] Running selective smart PTY tests..."
    python3 ./tests/run_smart_tests.py ${DUOP_LEAN_STAGED:+--staged}
else
    echo "==> [4/5] Running end-to-end PTY test suite (release)..."
    make -s test
fi

if [[ "$MODE" != "smart" || "${DUOP_SMART_MEMCHECK:-0}" == "1" ]]; then
    echo "==> [5/5] Running assembly memcheck leak/bad-free suite..."
    make -s memcheck
fi

if [[ "$MODE" == "full" ]]; then
    echo "==> [Extra] Rebuilding DWARF debug binary & running binary/PTY tests..."
    make -s clean
    make -s -j"$(nproc 2>/dev/null || echo 4)"
    python3 ./tests/run_tests.py --binary-only
fi

echo "ALL CHECKS PASSED (Duop v${VER}, mode=${MODE})."
