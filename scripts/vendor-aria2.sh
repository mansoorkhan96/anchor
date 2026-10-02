#!/bin/bash
# Builds a self-contained copy of Homebrew's aria2c (binary + non-system dylibs) into Vendor/aria2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/aria2"
SRC="$(readlink -f "$(brew --prefix)/bin/aria2c")"
rm -rf "$OUT" && mkdir -p "$OUT/libs"
cp "$SRC" "$OUT/aria2c" && chmod u+w "$OUT/aria2c"
dylibbundler -of -b -x "$OUT/aria2c" -d "$OUT/libs" -p "@executable_path/libs/" >/dev/null 2>&1
echo "Vendored aria2c into $OUT"
