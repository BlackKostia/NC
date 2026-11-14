#!/usr/bin/env bash
set -euo pipefail
VER="$(tr -d ' \n' < VERSION)"
STAGE="build/deb/duop_${VER}_amd64"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/duop" "$STAGE/usr/share/doc/duop"
make release
install -m755 duop "$STAGE/usr/bin/duop"
install -m755 scripts/duop-cd.sh "$STAGE/usr/share/duop/duop-cd.sh"
install -Dm644 -t "$STAGE/usr/share/duop/layouts" layouts/*.layout
install -m644 LICENSE "$STAGE/usr/share/doc/duop/copyright"
sed "s/^Version:.*/Version: ${VER}/" packaging/deb/control > "$STAGE/DEBIAN/control"
dpkg-deb --build "$STAGE"
echo "Built ${STAGE}.deb"
