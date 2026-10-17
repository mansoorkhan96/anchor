#!/bin/bash
# Builds an ad-hoc signed Anchor DMG: scripts/release.sh <version> [--publish] [--beta]
set -euo pipefail

VERSION="${1:-}"
PUBLISH=""
BETA=""
for arg in "${@:2}"; do
  case "$arg" in
    --publish) PUBLISH="--publish" ;;
    --beta) BETA="--beta" ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh <version> [--publish] [--beta]   e.g. scripts/release.sh 1.0.0" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$PUBLISH" = "--publish" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "Commit the version bump and other changes before publishing." >&2
    exit 1
  fi
  git fetch -q origin
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse @{u})" ]; then
    echo "Push your commits before publishing." >&2
    exit 1
  fi
fi

CURRENT_VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)"
if [ "$CURRENT_VERSION" != "$VERSION" ]; then
  BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
  sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
  echo "Version $VERSION (build $BUILD)"
fi

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Anchor.xcodeproj -scheme Anchor -configuration Release -derivedDataPath build/release build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="build/release/Build/Products/Release/Anchor.app"
codesign --verify --deep --strict "$APP"

DIST="build/dist"
DMG="$DIST/Anchor-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
hdiutil create -volname "Anchor $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
cp "$DMG" "$DIST/Anchor.dmg"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"

# Sparkle: sign the DMG with the EdDSA key in the login keychain (made once with Sparkle's generate_keys) and write
# the appcast that installed copies read from the newest release.
SPARKLE_BIN="Vendor/Sparkle/bin"
BUILD_NUMBER="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"
REPO_URL="https://github.com/mansoorkhan96/anchor"
cat > "$DIST/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Anchor</title>
    <item>
      <title>Anchor $VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/Anchor-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
echo "Wrote $DIST/appcast.xml"

if [ "$PUBLISH" = "--publish" ]; then
  NOTES="$(mktemp)"
  cat > "$NOTES" <<'EOF'
## Installing

Open the DMG and drag Anchor to Applications.

Anchor isn't notarized by Apple, so macOS blocks the first launch. Open Anchor once, then go to **System Settings > Privacy & Security** and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/Anchor.app
```
EOF
  TITLE="Anchor $VERSION"
  FLAGS=(--draft)
  if [ "$BETA" = "--beta" ]; then
    TITLE="$TITLE Beta"
    FLAGS+=(--prerelease)
  fi
  gh release create "v$VERSION" "$DMG" "$DIST/Anchor.dmg" "$DMG.sha256" "$DIST/appcast.xml" \
    --title "$TITLE" --notes-file "$NOTES" --generate-notes "${FLAGS[@]}" --target "$(git rev-parse HEAD)"
  rm -f "$NOTES"
  echo "Created a draft release for v$VERSION. Review and publish it on GitHub."
fi
