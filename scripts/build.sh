#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/cache dist/FretFlow.app/Contents/MacOS dist/FretFlow.app/Contents/Resources
if [[ ! -f Resources/FretFlow.icns || scripts/make-icon.swift -nt Resources/FretFlow.icns ]]; then
  swift -module-cache-path "$ROOT/.build/cache" scripts/make-icon.swift
  iconutil --convert icns --output Resources/FretFlow.icns .build/FretFlow.iconset
fi
swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$ROOT/.build/cache" Sources/FretFlow/*.swift -o .build/FretFlow
cp .build/FretFlow dist/FretFlow.app/Contents/MacOS/FretFlow
cp Resources/Info.plist dist/FretFlow.app/Contents/Info.plist
rsync -a --exclude Info.plist --exclude FretFlow.entitlements Resources/ dist/FretFlow.app/Contents/Resources/
codesign --force --sign - --entitlements Resources/FretFlow.entitlements dist/FretFlow.app
codesign --verify --deep --strict dist/FretFlow.app
print "Built: $ROOT/dist/FretFlow.app"
