#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

APP_NAME="MiniStats.app"
INSTALL_DIR="${DIR:-$HOME/Applications}"

case "${1:-}" in
    '')
        APP="build/$APP_NAME"
        ;;
    --debug)
        APP="build/debug/$APP_NAME"
        ;;
    *)
        printf 'Usage: %s [--debug]\n' "$0" >&2
        exit 2
        ;;
esac

[ "$#" -le 1 ] || {
    printf 'Too many arguments\n' >&2
    exit 2
}

# Canonical build. build.sh also performs the existing self-tests.
./build.sh "$@"

[ -d "$APP" ] || {
    printf 'Built app not found: %s\n' "$APP" >&2
    exit 1
}

# Stop the previously installed/running instance before replacing it.
if pgrep -x MiniStats >/dev/null 2>&1; then
    printf 'Stopping running MiniStats…\n'
    pkill -x MiniStats || true

    i=0
    while pgrep -x MiniStats >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if pgrep -x MiniStats >/dev/null 2>&1; then
        printf 'MiniStats did not terminate; forcing termination…\n'
        pkill -KILL -x MiniStats || true

        i=0
        while pgrep -x MiniStats >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
    fi

    if pgrep -x MiniStats >/dev/null 2>&1; then
        printf 'Failed to stop running MiniStats.\n' >&2
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"

TARGET="$INSTALL_DIR/$APP_NAME"

printf 'Installing: %s\n' "$TARGET"

# Copy into a temporary sibling first so a failed copy never leaves a
# partially-installed application bundle.
TEMP_TARGET="$INSTALL_DIR/.MiniStats.installing.$$"
rm -rf "$TEMP_TARGET"

cleanup() {
    rm -rf "$TEMP_TARGET"
}
trap cleanup EXIT HUP INT TERM

ditto "$APP" "$TEMP_TARGET"

rm -rf "$TARGET"
mv "$TEMP_TARGET" "$TARGET"

trap - EXIT HUP INT TERM

printf 'Installed: %s\n' "$TARGET"

open "$TARGET"

printf 'Launched: %s\n' "$TARGET"
