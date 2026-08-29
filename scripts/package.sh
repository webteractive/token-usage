#!/bin/sh
# Packages Token Usage into dist/TokenUsage-<version>.dmg for distribution.
# Builds are currently ad-hoc signed, matching Zetty's release process.
set -eu
cd "$(dirname "$0")/.."

tuist generate --no-open
xcodebuild -workspace TokenUsage.xcworkspace -scheme TokenUsage \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build build

APP=build/Build/Products/Release/TokenUsage.app
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
COMMIT=$(/usr/libexec/PlistBuddy -c "Print :TokenUsageBuildCommit" "$PLIST")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
ditto "$APP" "$STAGE/TokenUsage.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/TokenUsage-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Token Usage $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"

echo "Packaged $DMG + $SHA (version $VERSION, commit $COMMIT)"
