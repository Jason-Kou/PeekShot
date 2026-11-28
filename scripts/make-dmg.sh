#!/bin/bash
# Packages a distributable disk image: dist/PeekShot-v<version>-mac-universal.dmg plus dist/SHA256SUMS.
#
# Requires a Developer ID Application certificate and a notarytool keychain profile
# (default: peekshot, override with NOTARY_PROFILE). Use build.sh for local builds.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-peekshot}"
DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
if [ -z "$DEVELOPER_ID" ]; then
  echo "A Developer ID Application signing identity is required to package a release." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
  echo "Unable to access the Apple notary service with profile '$NOTARY_PROFILE'." >&2
  exit 1
fi

scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/PeekShot.app/Contents/Info.plist)
DMG_NAME="PeekShot-v${VERSION}-mac-universal.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
DMG="$STAGING/$DMG_NAME"
IMAGE="$STAGING/image"

# Stage outside the project so no second PeekShot.app stays behind for macOS to launch by mistake.
mkdir "$IMAGE"
ditto dist/PeekShot.app "$IMAGE/PeekShot.app"
ln -s /Applications "$IMAGE/Applications"
lipo "$IMAGE/PeekShot.app/Contents/MacOS/PeekShot" -verify_arch arm64 x86_64
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$IMAGE/PeekShot.app"
codesign --verify --deep --strict "$IMAGE/PeekShot.app"

# Include the app's ticket so it remains available after copying the app out of the DMG.
APP_ZIP="$STAGING/PeekShot.zip"
ditto -c -k --keepParent "$IMAGE/PeekShot.app" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$IMAGE/PeekShot.app"
xcrun stapler validate "$IMAGE/PeekShot.app"

hdiutil create -volname "PeekShot" -srcfolder "$IMAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
codesign --timestamp --identifier app.peekshot.PeekShot.dmg --sign "$DEVELOPER_ID" "$DMG"
codesign --verify --strict "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

(cd "$STAGING" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
mv "$DMG" "$STAGING/SHA256SUMS" dist/
echo "Built and notarized dist/$DMG_NAME"
