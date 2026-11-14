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
python3 ./.agents/skills/duop-modular-asm/scripts/check_modularity.py --root "$ROOT"
python3 ./.agents/skills/duop-reliability-audit/scripts/audit_stack_abi.py
# Lean gate: whole working tree, or only the staged commit content when run from pre-commit
python3 ./.agents/skills/duop-lean-modules/scripts/check_lean.py --root "$ROOT" ${DUOP_LEAN_STAGED:+--staged}
python3 ./tests/test_lean_gate.py
python3 ./tests/test_lean_split.py
python3 ./tests/test_i18n_hook.py

VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "==> [2/4] Building stripped release binary (v${VER})..."
make -s release

echo "==> [3/4] Auditing ELF sections & --version..."
SIZE_OUT="$(size "$ROOT/duop")"
echo "$SIZE_OUT"
DATA_BYTES="$(printf '%s\n' "$SIZE_OUT" | awk 'NR==2 {print $2}')"
if [[ -z "$DATA_BYTES" || "$DATA_BYTES" -ne 0 ]]; then
    echo "ERROR: ELF .data section must be 0 bytes (got '${DATA_BYTES}')." >&2
    exit 1
fi

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
    echo "==> [Extra] Rebuilding DWARF debug binary & running PTY tests..."
    make -s clean
    make -s
    make -s test
fi

echo "ALL CHECKS PASSED (Duop v${VER}, mode=${MODE})."
