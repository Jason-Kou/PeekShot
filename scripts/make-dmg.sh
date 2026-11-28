#!/bin/bash
# Packages a notarized disk image, SHA256SUMS, and a signed Sparkle appcast in dist/.
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

# Sparkle ships matching release tools alongside its Swift package XCFramework.
UPDATE_ACCOUNT=app.peekshot.PeekShot
TOOLS="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if ! UPDATE_KEY=$("$TOOLS/generate_keys" --account "$UPDATE_ACCOUNT" -p); then
  echo "The Sparkle signing key for '$UPDATE_ACCOUNT' is required in the login keychain." >&2
  exit 1
fi

INFO=dist/PeekShot.app/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
if [ "$UPDATE_KEY" != "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")" ]; then
  echo "The Sparkle signing key does not match the app's public key." >&2
  exit 1
fi
DMG_NAME="PeekShot-v${VERSION}-mac-universal.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
RELEASE="$STAGING/release"
DMG="$RELEASE/$DMG_NAME"
IMAGE="$STAGING/image"

# Stage outside the project so no second PeekShot.app stays behind for macOS to launch by mistake.
mkdir "$IMAGE" "$RELEASE"
ditto dist/PeekShot.app "$IMAGE/PeekShot.app"
ln -s /Applications "$IMAGE/Applications"
lipo "$IMAGE/PeekShot.app/Contents/MacOS/PeekShot" -verify_arch arm64 x86_64

# Sign nested Sparkle helpers before signing the enclosing framework and app.
FRAMEWORK="$IMAGE/PeekShot.app/Contents/Frameworks/Sparkle.framework"
HELPERS="$FRAMEWORK/Versions/Current"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
  "$HELPERS/Autoupdate" "$HELPERS/Updater.app" "$HELPERS/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$DEVELOPER_ID" \
  "$HELPERS/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$FRAMEWORK"
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

# Sparkle signs the final DMG bytes, including the notarization ticket.
GITHUB_RELEASES=https://github.com/Jason-Kou/PeekShot/releases
"$TOOLS/generate_appcast" --account "$UPDATE_ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "$GITHUB_RELEASES/download/v$VERSION/" \
  --full-release-notes-url "$GITHUB_RELEASES/tag/v$VERSION" \
  -o "$RELEASE/appcast.xml" "$RELEASE"
test -s "$RELEASE/appcast.xml"
(cd "$RELEASE" && shasum -a 256 "$DMG_NAME" appcast.xml > SHA256SUMS)
mv "$DMG" "$RELEASE/appcast.xml" "$RELEASE/SHA256SUMS" dist/
echo "Built and notarized dist/$DMG_NAME with a signed appcast.xml"
