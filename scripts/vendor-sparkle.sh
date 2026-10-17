#!/bin/bash
# Downloads Sparkle (the update framework and its signing tools) into Vendor/Sparkle, checked against a pinned SHA-256.
# Run by the build when Vendor/Sparkle is missing.
set -euo pipefail
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/Sparkle"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --max-time 300 -o "$WORK/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA256  $WORK/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
mkdir -p "$WORK/x"
tar -xf "$WORK/sparkle.tar.xz" -C "$WORK/x"
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$WORK/x/Sparkle.framework" "$WORK/x/bin" "$WORK/x/LICENSE" "$OUT/"
echo "$VERSION" > "$OUT/VERSION"
echo "Vendored Sparkle $VERSION into $OUT"
