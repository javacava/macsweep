#!/bin/bash
# Builds MyOpenCleaner.app in ./dist. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 builds one binary for Apple silicon and Intel (used for releases).
# VERSION=1.2.3 stamps the version into Info.plist.
FLAGS=(-c release)
if [ "${UNIVERSAL:-0}" = "1" ]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"

APP="dist/MyOpenCleaner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MyOpenCleaner" "$APP/Contents/MacOS/MyOpenCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

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
