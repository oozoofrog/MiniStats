#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

APP="build/MiniStats.app"
for a in "$@"; do
    if [ "$a" = "--debug" ]; then APP="build/debug/MiniStats.app"; fi
done

# Canonical build (includes self-test); reuse build.sh rather than duplicate it.
./build.sh "$@"

# The app exits(0) when another instance with the same bundle id is already
# running, so stop any running instance first or the fresh build would not start.
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

open "$APP"
printf 'Launched: %s\n' "$APP"
