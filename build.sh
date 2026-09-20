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

mkdir -p "$OUTPUT"
xcodebuild -project RetroStats.xcodeproj -scheme RetroStats -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    CONFIGURATION_BUILD_DIR="$OUTPUT" \
    CODE_SIGN_IDENTITY="-" \
    build

APP="$OUTPUT/RetroStats.app"
# File-system synchronized Metal sources do not reliably invalidate Xcode's
# incremental metallib output, so always compile the current shader here.
METAL_AIR=$(mktemp "$OUTPUT/BitmapText.XXXXXX")
trap 'rm -f "$METAL_AIR"' EXIT
xcrun -sdk macosx metal -c RetroStats/PixelUI/BitmapText.metal -o "$METAL_AIR"
xcrun -sdk macosx metallib "$METAL_AIR" -o "$APP/Contents/Resources/default.metallib"
rm -f "$APP/Contents/Resources/Fonts/NeoDunggeunmo.woff" "$APP/Contents/Resources/Fonts/LICENSE.txt"
rmdir "$APP/Contents/Resources/Fonts" 2>/dev/null || true
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/RetroStats" --self-test
printf 'Built: %s\n' "$APP"
