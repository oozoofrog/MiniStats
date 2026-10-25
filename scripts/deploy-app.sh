#!/bin/sh
set -eu

SOURCE_APP="${1:-}"
INSTALL_DIR="${2:-$HOME/Applications}"
LAUNCH_MODE="${3:-}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -d "$SOURCE_APP" ] || fail "Usage: $0 SOURCE_APP [INSTALL_DIR] [--launch]"
case "$LAUNCH_MODE" in ''|--launch) ;; *) fail "Unknown option: $LAUNCH_MODE" ;; esac

# Validate before stopping the running app or replacing any installed files.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/check-signature.sh" "$SOURCE_APP"

mkdir -p "$INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || fail "Cannot write to $INSTALL_DIR"
TARGET="$INSTALL_DIR/RetroStats.app"
if [ -d "$TARGET" ]; then
    installed_requirement=$(codesign -d -r- "$TARGET" 2>&1 | sed -n 's/^designated => //p; s/^# designated => //p')
    source_requirement=$(codesign -d -r- "$SOURCE_APP" 2>&1 | sed -n 's/^designated => //p')
    case "$installed_requirement" in
        *cdhash*) printf 'NOTE: migrating ad-hoc installation; permissions may need one-time approval.\n' ;;
        '') fail 'Cannot determine installed signing identity; installation unchanged.' ;;
        *) [ "$installed_requirement" = "$source_requirement" ] || fail 'Signing requirement changed; installation unchanged.' ;;
    esac
fi

if pgrep -x RetroStats >/dev/null; then
    pkill -x RetroStats || true
    i=0
    while pgrep -x RetroStats >/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    pgrep -x RetroStats >/dev/null && fail 'RetroStats did not terminate.'
fi

rm -rf "$TARGET"
ditto "$SOURCE_APP" "$TARGET"
"$SCRIPT_DIR/check-signature.sh" "$TARGET"
printf 'Installed: %s\n' "$TARGET"
if [ "$LAUNCH_MODE" = --launch ]; then
    open "$TARGET"
    printf 'Launched: %s\n' "$TARGET"
fi
