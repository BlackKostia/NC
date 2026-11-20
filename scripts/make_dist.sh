#!/usr/bin/env bash
# Build the release assets of both architectures into dist/release/:
#   duop-linux-<arch>            stripped static binary
#   duop-linux-<arch>.tar.gz     duop-<ver>-linux-<arch>/{duop,lang/,layouts/,duop-cd.sh,LICENSE,README.md}
#   SHA256SUMS
# ARCHES="x86_64 aarch64" (default) selects the targets; AARCH64_NATIVE=1 uses as/ld instead of the aarch64-linux-gnu- cross tools.
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."
VER="$(tr -d ' \n' < VERSION)"
OUT="dist/release"
ARCHES="${ARCHES:-x86_64 aarch64}"
rm -rf "$OUT"
mkdir -p "$OUT"

for arch in $ARCHES; do
    extra=()
    [[ $arch == aarch64 && "${AARCH64_NATIVE:-0}" == 1 ]] && extra=(AS=as LD=ld)
    make --no-print-directory release ARCH="$arch" "${extra[@]}" >/dev/null
    python3 .agents/skills/duop-reliability-audit/scripts/audit_elf_hardening.py duop >/dev/null
    cp duop "$OUT/duop-linux-$arch"
    dir="duop-$VER-linux-$arch"
    stage="$OUT/$dir"
    mkdir -p "$stage/lang" "$stage/layouts"
    cp duop LICENSE README.md "$stage/"
    cp scripts/duop-cd.sh "$stage/"
    cp lang/*.lang "$stage/lang/"
    cp layouts/*.layout "$stage/layouts/"
    tar --owner=0 --group=0 --sort=name --mtime="@0" -C "$OUT" -czf "$OUT/duop-linux-$arch.tar.gz" "$dir"
    rm -rf "$stage"
    echo "$arch: $(stat -c %s "$OUT/duop-linux-$arch") bytes"
done

# Leave the host binary in ./duop, as `make release` would
make --no-print-directory release >/dev/null
(cd "$OUT" && sha256sum duop-linux-* > SHA256SUMS)
cat "$OUT/SHA256SUMS"
