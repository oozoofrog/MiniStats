#!/bin/sh
set -eu

REPO="https://github.com/oozoofrog/MiniStats.git"
INSTALL_DIR="${1:-$HOME/Applications}"
LOG_FILE="${TMPDIR:-/tmp}/retrostats-install.log"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail 'macOS is required for AppKit and signing.'
[ "$(uname -m)" = arm64 ] || fail 'Apple Silicon (arm64) is required.'
command -v git >/dev/null 2>&1 || fail 'git is required.'
command -v make >/dev/null 2>&1 || fail 'make is required.'
command -v xcrun >/dev/null 2>&1 || fail 'Xcode or Command Line Tools are required (xcrun not found).'
[ -x /usr/bin/python3 ] || fail 'The app requires /usr/bin/python3.'

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

printf 'Cloning RetroStats into %s\n' "$WORKDIR"
git clone --depth 1 "$REPO" "$WORKDIR/RetroStats"

printf 'Building and running self-tests (log: %s)\n' "$LOG_FILE"
if ! ( cd "$WORKDIR/RetroStats" && make verify ) >"$LOG_FILE" 2>&1; then
    printf 'Build failed. Last lines:\n' >&2
    tail -20 "$LOG_FILE" >&2
    printf 'Full log: %s\n' "$LOG_FILE" >&2
    exit 1
fi

APP="$WORKDIR/RetroStats/build/RetroStats.app"
[ -d "$APP" ] || fail "Built app not found: $APP"

"$WORKDIR/RetroStats/scripts/deploy-app.sh" "$APP" "$INSTALL_DIR"
printf 'Open with: open "%s/RetroStats.app"\n' "$INSTALL_DIR"
