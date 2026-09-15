#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    '') mode=release; app=build/RetroStats.app ;;
    --debug) mode=debug; app=build/debug/RetroStats.app ;;
    *) printf 'Usage: %s [--debug]\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'Too many arguments\n' >&2; exit 2; }
mkdir -p build/logs
log=$(mktemp "$PWD/build/logs/verify-$mode-$(date '+%Y%m%d-%H%M%S').XXXXXX")
printf 'Verification log: %s\n' "$log"

set +e
(
    set -eu
    printf 'Mode: %s\n' "$mode"
    ./scripts/doctor.sh
    /bin/sh -n build.sh scripts/doctor.sh scripts/verify.sh
    ./build.sh "$@"
    plutil -lint "$app/Contents/Info.plist"
    codesign --verify --strict "$app"
    lipo -verify_arch arm64 "$app/Contents/MacOS/RetroStats"
    cmp RetroStats/deriveddata.py "$app/Contents/Resources/deriveddata.py"
    printf 'PASS: build, Swift self-tests, Python regression tests, bundle/signature/architecture checks.\n'
) >"$log" 2>&1
status=$?
set -e
tail -n 18 "$log"
if [ "$status" -ne 0 ]; then
    printf 'FAIL (exit %s). Full log: %s\n' "$status" "$log" >&2
fi
exit "$status"
