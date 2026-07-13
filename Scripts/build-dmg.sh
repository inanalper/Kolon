#!/bin/bash
# Assembles dist/Kolon-<version>.dmg: the app plus an /Applications drop
# target laid over the temple background (Scripts/dmg/background.tiff) — the
# Applications alias sits in the temple's missing-column gap.
# The caller signs/notarizes the resulting image.
# Usage: ./Scripts/build-dmg.sh <version> <path/to/Kolon.app>
set -euo pipefail

VERSION="${1:?usage: build-dmg.sh <version> <Kolon.app>}"
APP="${2:?usage: build-dmg.sh <version> <Kolon.app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DMG="$DIST/Kolon-$VERSION.dmg"
VOLNAME="Kolon"

# Finder layout constants — keep in sync with Scripts/dmg-background.swift
WINDOW_BOUNDS="{200, 120, 920, 588}"   # 720x468; minus title bar = 720x440 content
APP_POS="{90, 268}"                    # above the ground shadow, left of the temple
APPLICATIONS_POS="{528, 268}"          # the missing-column gap

STAGING="$DIST/dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Kolon.app"
ln -s /Applications "$STAGING/Applications"

# Background rendered fresh (1x + 2x combined for retina) — nothing binary
# lives in the repo
swift "$ROOT/Scripts/dmg-background.swift" "$DIST/dmg-bg.png" 1
swift "$ROOT/Scripts/dmg-background.swift" "$DIST/dmg-bg@2x.png" 2
tiffutil -cathidpicheck "$DIST/dmg-bg.png" "$DIST/dmg-bg@2x.png" \
         -out "$STAGING/.background/background.tiff" > /dev/null 2>&1
rm -f "$DIST/dmg-bg.png" "$DIST/dmg-bg@2x.png"

# Volume icon from the app icon set
ICONSET="$DIST/kolon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SRC="$ROOT/App/Assets.xcassets/AppIcon.appiconset"
cp "$SRC/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$SRC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$SRC/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$SRC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$SRC/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$SRC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$SRC/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$SRC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$SRC/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$SRC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$STAGING/.VolumeIcon.icns"
rm -rf "$ICONSET"

# Writable image first; Finder scripting below bakes the layout into .DS_Store
RW="$DIST/kolon-rw.dmg"
rm -f "$RW"
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ \
               -format UDRW -ov "$RW" > /dev/null

MOUNT="/Volumes/$VOLNAME"
if [[ -d "$MOUNT" ]]; then hdiutil detach "$MOUNT" -force > /dev/null || true; fi
hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse > /dev/null

xcrun SetFile -a C "$MOUNT"   # honor .VolumeIcon.icns

osascript <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to $WINDOW_BOUNDS
        set viewOpts to the icon view options of container window
        set arrangement of viewOpts to not arranged
        set icon size of viewOpts to 100
        set text size of viewOpts to 13
        set background picture of viewOpts to file ".background:background.tiff"
        set position of item "Kolon.app" of container window to $APP_POS
        set position of item "Applications" of container window to $APPLICATIONS_POS
        close
        open
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" > /dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" > /dev/null
rm -f "$RW"
rm -rf "$STAGING"
echo "Created: $DMG"
