#!/bin/sh
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
    '') CONFIG=Release; OUTPUT="$PWD/build" ;;
    --debug) CONFIG=Debug; OUTPUT="$PWD/build/debug" ;;
    *) printf 'Usage: %s [--debug]\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'Too many arguments\n' >&2; exit 2; }

ICONSET="RetroStats/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

FONT_SRC=assets/Fonts/neodgm-webfont/neodgm/neodgm.woff
FONT_LICENSE=assets/Fonts/neodgm-webfont/LICENSE.txt
if [ ! -f "$FONT_SRC" ]; then
    printf 'Font not found: %s\nRun: git submodule update --init --recursive\n' "$FONT_SRC" >&2
    exit 1
fi
mkdir -p RetroStats/Fonts
cp "$FONT_SRC" RetroStats/Fonts/NeoDunggeunmo.woff
cp "$FONT_LICENSE" RetroStats/Fonts/LICENSE.txt

mkdir -p "$OUTPUT"
xcodebuild -project RetroStats.xcodeproj -scheme RetroStats -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    CONFIGURATION_BUILD_DIR="$OUTPUT" \
    CODE_SIGN_IDENTITY="-" \
    build

APP="$OUTPUT/RetroStats.app"
mkdir -p "$APP/Contents/Resources/Fonts"
mv "$APP/Contents/Resources/NeoDunggeunmo.woff" "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
mv "$APP/Contents/Resources/LICENSE.txt" "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/RetroStats" --self-test
/usr/bin/python3 tests/test_deriveddata.py
printf 'Built: %s\n' "$APP"
