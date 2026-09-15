#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

APP="build/RetroStats.app"
for a in "$@"; do
    if [ "$a" = "--debug" ]; then APP="build/debug/RetroStats.app"; fi
done
INSTALL_DIR="${DIR:-$HOME/Applications}"

./build.sh "$@"

[ -d "$APP" ] || { printf 'FAIL: Built app not found: %s\n' "$APP" >&2; exit 1; }
./scripts/deploy-app.sh "$APP" "$INSTALL_DIR" --launch
