#!/bin/sh
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
    '') OUTPUT="$PWD/build"; MODE=release ;;
    --debug) OUTPUT="$PWD/build/debug"; MODE=debug ;;
    *) printf 'Usage: %s [--debug]\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'Too many arguments\n' >&2; exit 2; }
if [ "$MODE" = debug ]; then
    set -- -Onone -g
else
    set -- -O -whole-module-optimization
fi
APP="$OUTPUT/MiniStats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Resources/Fonts"
ICONSET="$OUTPUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc "$@" -target arm64-apple-macos26.0 -import-objc-header Bridging.h main.swift Popover.swift Storage.swift Dashboard.swift -o "$APP/Contents/MacOS/MiniStats" -framework AppKit -framework IOKit -framework ServiceManagement -framework UserNotifications
cp Info.plist "$APP/Contents/Info.plist"
cp deriveddata.py "$APP/Contents/Resources/deriveddata.py"
FONT_SRC=assets/Fonts/neodgm-webfont/neodgm/neodgm.woff
FONT_LICENSE=assets/Fonts/neodgm-webfont/LICENSE.txt
if [ ! -f "$FONT_SRC" ]; then
    printf 'Font not found: %s\nRun: git submodule update --init --recursive\n' "$FONT_SRC" >&2
    exit 1
fi
rm -f "$APP/Contents/Resources/Fonts/"*.woff "$APP/Contents/Resources/Fonts/LICENSE.txt"
cp "$FONT_SRC" "$APP/Contents/Resources/Fonts/NeoDunggeunmo.woff"
cp "$FONT_LICENSE" "$APP/Contents/Resources/Fonts/LICENSE.txt"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/MiniStats" --self-test
/usr/bin/python3 tests/test_deriveddata.py
printf 'Built: %s\n' "$APP"
