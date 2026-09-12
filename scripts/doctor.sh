#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'macOS is required for AppKit and signing.'
[ "$(uname -m)" = arm64 ] || fail 'Use a native Apple Silicon shell (arm64).'
for tool in xcrun xcode-select sips iconutil codesign plutil lipo make; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing tool: $tool"
done
[ -x /usr/bin/python3 ] || fail 'The app requires /usr/bin/python3.'
for input in main.swift Storage.swift Dashboard.swift Bridging.h Info.plist deriveddata.py assets/AppIcon.png tests/test_deriveddata.py; do
    [ -f "$input" ] || fail "Missing build input: $input"
done
printf 'Developer directory: %s\n' "$(xcode-select -p)"
xcrun --find swiftc >/dev/null
xcrun --sdk macosx --show-sdk-path
xcrun swiftc --version
/usr/bin/python3 --version
plutil -lint Info.plist
printf 'PASS: local build prerequisites. Run make verify to compile and test.\n'
if git rev-parse --show-toplevel 2>/dev/null; then
    git status --short --branch
else
    printf 'NOTE: no Git repository; Git diff/worktree operations are unavailable.\n'
fi
