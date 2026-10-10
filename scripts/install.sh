#!/bin/bash
# Builds a Release copy of Anchor and installs it to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Anchor.xcodeproj -scheme Anchor -configuration Release -derivedDataPath build/release build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
osascript -e 'quit app "Anchor"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Anchor.app
cp -R build/release/Build/Products/Release/Anchor.app /Applications/
echo "Installed /Applications/Anchor.app"
