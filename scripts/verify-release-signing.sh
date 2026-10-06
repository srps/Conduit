#!/bin/bash
# Checks a release-signed Conduit.app the way a pinned helper will see it:
# every binary signed by Resources/release-signing.pem with the hardened
# runtime, the app's bundled installer derives a pin that admits the app,
# and that pin refuses the nested helper and pm-dns.
#
#   scripts/verify-release-signing.sh <Conduit.app> [release-signing.pem]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: verify-release-signing.sh <Conduit.app> [release-signing.pem]}"
PEM="${2:-$ROOT_DIR/Resources/release-signing.pem}"
BUNDLE_ID="io.github.srps.Conduit"
HELPER="$APP/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
PM_DNS="$APP/Contents/MacOS/pm-dns"

failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/verify-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
expected="$(/usr/bin/openssl x509 -in "$PEM" -outform der | shasum -a 1 | awk '{ print $1 }')"

check_code() { # <label> <path> <identifier>
    local label="$1" code="$2" identifier="$3" details leaf
    if ! codesign --verify --strict "$code" 2>/dev/null; then
        fail "$label: invalid signature"
        return
    fi
    details="$(codesign -dv "$code" 2>&1)"
    rm -f "$scratch"/cert*
    codesign -d --extract-certificates="$scratch/cert" "$code" >/dev/null 2>&1 || true
    leaf="$([ -s "$scratch/cert0" ] && shasum -a 1 "$scratch/cert0" | awk '{ print $1 }')"
    if [ "$leaf" != "$expected" ]; then
        fail "$label: signed by ${leaf:-no certificate}, not the release certificate $expected"
    elif [[ "$details" != *"flags="*"runtime"* ]]; then
        fail "$label: no hardened runtime"
    elif [[ "$details" != *"Identifier=$identifier"$'\n'* ]]; then
        fail "$label: identifier is not $identifier ($(grep '^Identifier=' <<<"$details"))"
    else
        ok "$label: release certificate, hardened runtime, $identifier"
    fi
}

check_code "app" "$APP" "$BUNDLE_ID"
check_code "helper" "$HELPER" "$BUNDLE_ID.Helper"
check_code "pm-dns" "$PM_DNS" "$BUNDLE_ID.pm-dns"
codesign --verify --strict --deep "$APP" 2>/dev/null && ok "bundle seal" || fail "bundle seal: codesign --verify --deep failed"

if cmp -s "$PEM" "$APP/Contents/Resources/release-signing.pem"; then
    ok "bundled release certificate"
else
    fail "the app does not bundle $PEM"
fi
pin="$("$APP/Contents/Resources/install-helper.sh" --print-caller-requirement "$APP" 2>&1)" || pin=""
if [ -n "$pin" ] && codesign --verify -R "=$pin" "$APP" 2>/dev/null; then
    ok "the bundled installer's pin admits the app"
else
    fail "the bundled installer's pin does not admit the app: $pin"
fi
for code in "$HELPER" "$PM_DNS"; do
    if [ -n "$pin" ] && codesign --verify -R "=$pin" "$code" 2>/dev/null; then
        fail "the pin admits $(basename "$code"), which must never call the helper"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
