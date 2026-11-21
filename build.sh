#!/bin/bash
# Builds MyOpenCleaner.app in ./dist. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/MyOpenCleaner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MyOpenCleaner "$APP/Contents/MacOS/MyOpenCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    swift scripts/make_icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$APP"
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/MyOpenCleaner.app
    cp -R "$APP" /Applications/MyOpenCleaner.app
    echo "Installed to /Applications/MyOpenCleaner.app"
fi
