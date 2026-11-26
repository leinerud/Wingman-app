#!/bin/bash
# Builds Wingman.app (Dock + menu bar app with its desktop widget) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${TMPDIR:-/tmp}/wingman-dd"
xcodebuild -project Wingman.xcodeproj -scheme Wingman -configuration Release \
  -derivedDataPath "$DD" -allowProvisioningUpdates build | grep -E "error|BUILD" || true
rm -rf build/Wingman.app; mkdir -p build
cp -R "$DD/Build/Products/Release/Wingman.app" build/
echo "Built build/Wingman.app"
