#!/bin/sh
set -eu

APP_NAME="RetroStats.app"
SOURCE_APP="${1:-}"
INSTALL_DIR="${2:-$HOME/Applications}"
LAUNCH_MODE="${3:-}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -n "$SOURCE_APP" ] || fail "Usage: $0 SOURCE_APP [INSTALL_DIR] [--launch]"
[ -d "$SOURCE_APP" ] || fail "App bundle not found: $SOURCE_APP"
case "$LAUNCH_MODE" in
    ''|--launch) ;;
    *) fail "Unknown option: $LAUNCH_MODE" ;;
esac
command -v ditto >/dev/null 2>&1 || fail 'ditto is required.'
command -v open >/dev/null 2>&1 || fail 'open is required.'

NEEDS_SUDO=0
if [ -d "$INSTALL_DIR" ]; then
    [ -w "$INSTALL_DIR" ] || NEEDS_SUDO=1
else
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        NEEDS_SUDO=1
    fi
fi

if [ "$NEEDS_SUDO" -eq 1 ]; then
    command -v sudo >/dev/null 2>&1 || fail "Cannot write to $INSTALL_DIR and sudo is unavailable."
    sudo -v
    sudo mkdir -p "$INSTALL_DIR"
fi

as_installer() {
    if [ "$NEEDS_SUDO" -eq 1 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

if pgrep -x RetroStats >/dev/null 2>&1; then
    printf 'Stopping running RetroStats…\n'
    pkill -x RetroStats || true
    i=0
    while pgrep -x RetroStats >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if pgrep -x RetroStats >/dev/null 2>&1; then
        printf 'RetroStats did not terminate; forcing termination…\n'
        pkill -KILL -x RetroStats || true
        i=0
        while pgrep -x RetroStats >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
    fi
    pgrep -x RetroStats >/dev/null 2>&1 && fail 'Failed to stop running RetroStats.'
fi

TARGET="$INSTALL_DIR/$APP_NAME"
TEMP_TARGET="$INSTALL_DIR/.RetroStats.installing.$$"
BACKUP_TARGET="$INSTALL_DIR/.RetroStats.previous.$$"

rollback() {
    as_installer rm -rf "$TEMP_TARGET" >/dev/null 2>&1 || true
    if { [ -e "$BACKUP_TARGET" ] || [ -L "$BACKUP_TARGET" ]; } && \
       ! { [ -e "$TARGET" ] || [ -L "$TARGET" ]; }; then
        as_installer mv "$BACKUP_TARGET" "$TARGET" >/dev/null 2>&1 || true
    fi
    as_installer rm -rf "$BACKUP_TARGET" >/dev/null 2>&1 || true
}
trap rollback EXIT HUP INT TERM

as_installer rm -rf "$TEMP_TARGET" "$BACKUP_TARGET"
as_installer ditto "$SOURCE_APP" "$TEMP_TARGET"

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    as_installer mv "$TARGET" "$BACKUP_TARGET"
fi

if ! as_installer mv "$TEMP_TARGET" "$TARGET"; then
    fail "Could not move the new app into $TARGET"
fi

as_installer rm -rf "$BACKUP_TARGET"
trap - EXIT HUP INT TERM

printf 'Installed: %s\n' "$TARGET"

if [ "$LAUNCH_MODE" = "--launch" ]; then
    open "$TARGET"
    printf 'Launched: %s\n' "$TARGET"
fi
