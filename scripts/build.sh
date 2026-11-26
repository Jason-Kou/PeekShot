#!/bin/bash
# Builds a Release copy of PeekShot into dist/PeekShot.app.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project PeekShot.xcodeproj -scheme PeekShot -configuration Release \
  -derivedDataPath build build | grep -E "error|warning: unre|BUILD" || true

mkdir -p dist
ditto build/Build/Products/Release/PeekShot.app dist/PeekShot.app
echo "Built dist/PeekShot.app"
