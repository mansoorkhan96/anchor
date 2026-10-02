#!/bin/bash
# Xcode post-build phase: copies the vendored aria2c into Drift.app/Contents/Helpers and signs it.
set -euo pipefail
VENDOR="${PROJECT_DIR}/Vendor/aria2"
if [ ! -x "$VENDOR/aria2c" ]; then
  export PATH="/opt/homebrew/bin:$PATH"
  "${PROJECT_DIR}/scripts/vendor-aria2.sh"
fi
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
rm -rf "$DEST" && mkdir -p "$DEST"
cp -R "$VENDOR/aria2c" "$VENDOR/libs" "$DEST/"
for f in "$DEST"/libs/*.dylib "$DEST/aria2c"; do
  codesign --force --sign - "$f" >/dev/null 2>&1
done
