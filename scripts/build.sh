#!/bin/bash
# Builds a Release copy of PeekShot into dist/PeekShot.app.
set -euo pipefail
cd "$(dirname "$0")/.."

# A stable identity keeps the macOS screen recording grant valid across rebuilds.
# Create it once per machine with scripts/setup-signing.sh.
IDENTITY="PeekShot Local Signing"

xcodegen generate
xcodebuild -project PeekShot.xcodeproj -scheme PeekShot -configuration Release \
  -derivedDataPath build build | grep -E "error|warning: unre|BUILD" || true

# Keep exactly one Release copy on disk: a second, unsigned copy with the same bundle id can get
# launched by macOS ("Quit & Reopen") instead of the signed one and would lack the permission grant.
rm -rf dist/PeekShot.app
mkdir -p dist
mv build/Build/Products/Release/PeekShot.app dist/PeekShot.app

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" dist/PeekShot.app
  echo "Signed with \"$IDENTITY\""
else
  echo "No \"$IDENTITY\" identity found: keeping the ad-hoc signature (run scripts/setup-signing.sh)"
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f dist/PeekShot.app
echo "Built dist/PeekShot.app"
