#!/bin/bash
# Builds a Release copy of Drift and installs it to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Drift.xcodeproj -scheme Drift -configuration Release -derivedDataPath build/release build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
osascript -e 'quit app "Drift"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Drift.app
cp -R build/release/Build/Products/Release/Drift.app /Applications/
echo "Installed /Applications/Drift.app"
