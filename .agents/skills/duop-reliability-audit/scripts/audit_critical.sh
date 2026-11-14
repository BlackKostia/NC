#!/usr/bin/env bash
# Critical-defect audit suite (static + runtime). Does not modify the program.
#   ./audit_critical.sh            all checks, short fuzz (40 mutants per parser)
#   FUZZ_ITERS=200 ./audit_critical.sh
# Runtime checks use a snapshot of ./duop (concurrent rebuilds cannot disturb the run).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
SNAP="$(mktemp -d)"; trap 'rm -rf "$SNAP"' EXIT
cp "$ROOT/duop" "$SNAP/duop"; cp -r "$ROOT/lang" "$ROOT/layouts" "$SNAP/" 2>/dev/null || true
export DUOP_BIN="$SNAP/duop"
FAILED=()
run() { local label="$1"; shift; echo; echo "===== $label"; "$@" || FAILED+=("$label"); }
cd "$HERE"
run "temp files / TOCTOU"   python3 audit_tmp_files.py
run "thread reachability"   python3 audit_thread_reach.py
run "unchecked data I/O"    python3 audit_unchecked_io.py
run "silent caps"           python3 audit_depth_caps.py
run "signal matrix"         python3 signal_matrix.py
run "security probe"        python3 security_probe.py
run "parser fuzz"           python3 fuzz_parsers.py --iters "${FUZZ_ITERS:-40}" --seed "${FUZZ_SEED:-$RANDOM}"
run "leftover processes"    python3 proc_health.py --scan
echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "CRITICAL AUDIT: all checks passed"; exit 0; fi
echo "CRITICAL AUDIT: ${#FAILED[@]} checks report findings: ${FAILED[*]}"; exit 1
