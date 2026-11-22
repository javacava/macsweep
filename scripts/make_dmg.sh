#!/bin/bash
# Packs an app into a compressed disk image whose window shows the app, an arrow and the
# Applications folder, so people drag the app across. Uses only tools that ship with macOS:
# hdiutil, and Finder (through AppleScript) to save the window layout.
#
#   scripts/make_dmg.sh dist/MyOpenCleaner.app MyOpenCleaner-1.0.0.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: make_dmg.sh <path/to/App.app> <out.dmg>}"
OUT="${2:?usage: make_dmg.sh <path/to/App.app> <out.dmg>}"
NAME="$(basename "$APP" .app)"
VOLUME="/Volumes/$NAME"

# Window and icon layout, in points. Must match scripts/make_dmg_background.swift.
WIN_W=640; WIN_H=400; TITLE_BAR=32   # the window bounds include the title bar
APP_X=170; APPS_X=470; ICON_Y=196; ICON_SIZE=112

WORK="$(mktemp -d)"
DEVICE=""
cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -force -quiet || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# hdiutil and Finder sometimes fail on busy build machines; try again a few times.
retry() {
    local n
    for n in 1 2 3 4 5; do
        if "$@"; then return 0; fi
        echo "Retrying ($n): $*" >&2
        sleep $((n * 2))
    done
    return 1
}

if [ -e "$VOLUME" ]; then
    echo "$VOLUME is already mounted. Eject it and run this again." >&2
    exit 1
fi

# Background: 1x and 2x joined into one TIFF, so it is sharp on Retina screens.
BG="Resources/dmg-background.tiff"
if [ ! -f "$BG" ]; then
    swift scripts/make_dmg_background.swift "$WORK/bg.png" "$WORK/bg@2x.png"
    tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$BG"
fi

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/background.tiff"

# Room for the volume icon and Finder's layout file; the compressed image does not grow from it.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
retry hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg"
DEVICE="$(retry hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1; exit}')"
[ -d "$VOLUME" ] || { echo "The image did not mount at $VOLUME" >&2; exit 1; }

# Finder saves the window size, background and icon positions in the volume's .DS_Store.
layout() {
    osascript <<EOF
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + TITLE_BAR))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 13
        set label position of opts to bottom
        set shows item info of opts to false
        set shows icon preview of opts to true
        set background picture of opts to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {$APP_X, $ICON_Y}
        set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
}
retry layout

# Wait until Finder has written the layout, then seal the volume.
for _ in $(seq 1 20); do [ -f "$VOLUME/.DS_Store" ] && break; sleep 1; done
[ -f "$VOLUME/.DS_Store" ] || { echo "Finder did not save the window layout" >&2; exit 1; }

# The app's icon on the mounted disk. Added after the layout, because Finder removes it while saving.
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICON" ] && command -v SetFile > /dev/null; then
    cp "$ICON" "$VOLUME/.VolumeIcon.icns"
    SetFile -c icnC "$VOLUME/.VolumeIcon.icns"
    SetFile -a C "$VOLUME"
fi
rm -rf "$VOLUME/.fseventsd" "$VOLUME/.Trashes"
chmod -Rf go-w "$VOLUME" || true
sync
retry hdiutil detach "$DEVICE" -quiet
DEVICE=""

rm -f "$OUT"
retry hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT"
hdiutil verify -quiet "$OUT"
echo "Built: $OUT"
