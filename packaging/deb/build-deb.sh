#!/usr/bin/env bash
# Build a .deb of the stripped static duop binary for the host (or ARCH=x86_64|aarch64) architecture.
set -euo pipefail
umask 022
VER="$(tr -d ' \n' < VERSION)"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=x86_64;  DEB_ARCH=amd64 ;;
    aarch64|arm64) ARCH=aarch64; DEB_ARCH=arm64 ;;
    *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac
if [[ "$ARCH" == aarch64 && "$(uname -m)" == aarch64 ]]; then
    make release ARCH=aarch64 AS=as LD=ld
else
    make release ARCH="$ARCH"
fi
STAGE="build/deb/duop_${VER}_${DEB_ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/duop" "$STAGE/usr/share/doc/duop"
install -m755 duop "$STAGE/usr/bin/duop"
install -m755 scripts/duop-cd.sh "$STAGE/usr/share/duop/duop-cd.sh"
install -Dm644 -t "$STAGE/usr/share/duop/layouts" layouts/*.layout
install -Dm644 -t "$STAGE/usr/share/duop/lang" lang/*.lang
install -m644 LICENSE "$STAGE/usr/share/doc/duop/copyright"
sed -e "s/^Version:.*/Version: ${VER}/" -e "s/^Architecture:.*/Architecture: ${DEB_ARCH}/" \
    packaging/deb/control > "$STAGE/DEBIAN/control"
dpkg-deb --root-owner-group --build "$STAGE"
echo "Built ${STAGE}.deb"
