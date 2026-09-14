#!/bin/sh
set -eu

REPO="https://github.com/oozoofrog/MiniStats.git"
APP_NAME="MiniStats.app"
INSTALL_DIR="${1:-$HOME/Applications}"
LOG_FILE="${TMPDIR:-/tmp}/ministats-install.log"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail 'macOS is required for AppKit and signing.'
[ "$(uname -m)" = arm64 ] || fail 'Apple Silicon (arm64) is required.'
command -v git >/dev/null 2>&1 || fail 'git is required.'
command -v make >/dev/null 2>&1 || fail 'make is required.'
command -v xcrun >/dev/null 2>&1 || fail 'Xcode or Command Line Tools are required (xcrun not found).'
[ -x /usr/bin/python3 ] || fail 'The app requires /usr/bin/python3.'

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

printf 'Cloning MiniStats into %s\n' "$WORKDIR"
git clone --recurse-submodules --depth 1 "$REPO" "$WORKDIR/MiniStats"

printf 'Building and running self-tests (log: %s)\n' "$LOG_FILE"
if ! ( cd "$WORKDIR/MiniStats" && make verify ) >"$LOG_FILE" 2>&1; then
    printf 'Build failed. Last lines:\n' >&2
    tail -20 "$LOG_FILE" >&2
    printf 'Full log: %s\n' "$LOG_FILE" >&2
    exit 1
fi

APP="$WORKDIR/MiniStats/build/MiniStats.app"
[ -d "$APP" ] || fail "Built app not found: $APP"

mkdir -p "$INSTALL_DIR"
TARGET="$INSTALL_DIR/$APP_NAME"

if pgrep -x MiniStats >/dev/null 2>&1; then
    printf 'Stopping running MiniStats…\n'
    pkill -x MiniStats || true
    i=0
    while pgrep -x MiniStats >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if pgrep -x MiniStats >/dev/null 2>&1; then
        pkill -KILL -x MiniStats || true
        i=0
        while pgrep -x MiniStats >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
    fi
fi

if [ -d "$TARGET" ]; then
    rm -rf "$TARGET"
fi
ditto "$APP" "$TARGET"

printf 'Installed: %s\n' "$TARGET"
printf 'Open with: open "%s"\n' "$TARGET"
