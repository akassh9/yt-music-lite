#!/bin/bash
# Builds "build/YT Music.app". Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/YT Music.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# arm64-only, optimized, whole-module: smallest/fastest binary for Apple silicon.
compile() { swiftc -O -wmo -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/YTMusic" Sources/main.swift; }
# An installed Xcode whose license hasn't been accepted fails at link time; the Command Line Tools still work.
if ! compile 2>/dev/null; then
  DEVELOPER_DIR=/Library/Developer/CommandLineTools compile
fi
strip -x "$APP/Contents/MacOS/YTMusic"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/YT Music.app"
  ditto "$APP" "/Applications/YT Music.app"
  echo "Installed to /Applications/YT Music.app"
fi
