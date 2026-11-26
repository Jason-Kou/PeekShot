#!/bin/bash
# Packages a distributable disk image: dist/PeekShot-v<version>-mac-universal.dmg plus dist/SHA256SUMS.
#
# With a "Developer ID Application" certificate the app is signed for distribution, and when a notarytool
# keychain profile exists (default name: peekshot, override with NOTARY_PROFILE) the image is notarized
# and stapled. Without them the locally signed build is packaged; macOS then asks users to confirm the
# first launch under System Settings > Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-peekshot}"

scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/PeekShot.app/Contents/Info.plist)
DMG="dist/PeekShot-v${VERSION}-mac-universal.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# Stage outside the project so no second PeekShot.app stays behind for macOS to launch by mistake.
ditto dist/PeekShot.app "$STAGING/PeekShot.app"
ln -s /Applications "$STAGING/Applications"

DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$STAGING/PeekShot.app"
  echo "Signed with \"$DEVELOPER_ID\""
else
  echo "No Developer ID Application certificate: packaging the locally signed build"
fi
codesign --verify --strict "$STAGING/PeekShot.app"

rm -f "$DMG"
hdiutil create -volname "PeekShot" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "$DEVELOPER_ID" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled"
else
  echo "NOT notarized: users must allow the first launch in System Settings > Privacy & Security"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS)
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
