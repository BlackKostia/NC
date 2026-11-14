#!/usr/bin/env bash
set -euo pipefail
REPO="${DUOP_REPO:-ChessPlayerSedoy/duop}"
PREFIX="${PREFIX:-/usr/local}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Installing duop from https://github.com/$REPO ..."
if command -v git >/dev/null 2>&1 && command -v as >/dev/null 2>&1 && command -v ld >/dev/null 2>&1; then
    git clone --depth 1 "https://github.com/$REPO.git" "$TMP/duop"
    make -C "$TMP/duop" release
    install -Dm755 "$TMP/duop/duop" "$PREFIX/bin/duop"
    install -Dm644 -t "$PREFIX/share/duop/layouts" "$TMP"/duop/layouts/*.layout
    install -Dm644 -t "$PREFIX/share/duop/lang" "$TMP"/duop/lang/*.lang
    echo "Installed $PREFIX/bin/duop ($("$PREFIX/bin/duop" --version | head -n1))"
else
    echo "Requires git, binutils (as/ld), and make." >&2
    exit 1
fi
