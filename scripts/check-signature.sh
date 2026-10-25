#!/bin/sh
set -eu
APP="${1:?Usage: check-signature.sh APP}"
EXPECTED='identifier "local.jay.RetroStats" and anchor apple generic and certificate leaf[subject.OU] = "HY47J4787Q"'
codesign --verify --strict -R "=$EXPECTED" "$APP"
requirement=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
[ -n "$requirement" ] || { echo 'FAIL: missing designated requirement' >&2; exit 1; }
case "$requirement" in *cdhash*) echo 'FAIL: build-specific signature requirement' >&2; exit 1;; esac
printf 'PASS: certificate signature, team HY47J4787Q, stable app requirement.\n'
printf '%s\n' "$requirement"
