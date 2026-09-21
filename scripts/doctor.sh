#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'macOS is required for AppKit and signing.'
[ "$(uname -m)" = arm64 ] || fail 'Use a native Apple Silicon shell (arm64).'
for tool in xcodebuild xcrun sips codesign plutil lipo make; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing tool: $tool"
done
for input in RetroStats/App/main.swift RetroStats/PixelUI/RetroTheme.swift RetroStats/App/AppDelegate.swift RetroStats/Storage/StorageController.swift RetroStats/Dashboard/DashboardView.swift RetroStats/Bridging.h RetroStats/Info.plist RetroStats.xcodeproj/project.pbxproj assets/AppIcon.png; do
    [ -f "$input" ] || fail "Missing build input: $input"
done
printf 'Developer directory: %s\n' "$(xcode-select -p)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
case "$SDK_MAJOR" in
    ''|*[!0-9]*) fail "Could not parse macOS SDK version: $SDK_VERSION" ;;
esac
[ "$SDK_MAJOR" -ge 26 ] || fail "macOS 26 SDK or newer is required (found $SDK_VERSION)."
printf 'macOS SDK: %s\n' "$SDK_VERSION"
xcodebuild -version
plutil -lint RetroStats/Info.plist
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw -o - RetroStats/Info.plist)"
[ "$MIN_OS" = 26.0 ] || fail "Info.plist LSMinimumSystemVersion must be 26.0 (found $MIN_OS)."
printf 'Deployment target: macOS %s\n' "$MIN_OS"
printf 'PASS: local build prerequisites. Run make verify to compile and test.\n'
if git rev-parse --show-toplevel 2>/dev/null; then
    git status --short --branch
else
    printf 'NOTE: no Git repository; Git diff/worktree operations are unavailable.\n'
fi
