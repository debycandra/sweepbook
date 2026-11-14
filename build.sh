#!/bin/bash
# Builds Sweepbook.app without Xcode (only the Command Line Tools are needed).
#   ./build.sh            -> build/Sweepbook.app (universal: Apple Silicon + Intel)
#   ./build.sh --install  -> also copies it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Sweepbook.app
BIN="$APP/Contents/MacOS/Sweepbook"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/*.swift -o "build/obj/Sweepbook-$arch"
done
lipo -create build/obj/Sweepbook-arm64 build/obj/Sweepbook-x86_64 -output "$BIN"
cp Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ] || [ assets/icon.svg -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift make-icon.swift build/AppIcon.iconset assets/icon.png && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - "$APP"
echo "Built $APP ($(lipo -archs "$BIN"))"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Sweepbook.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/Sweepbook.app"
fi
