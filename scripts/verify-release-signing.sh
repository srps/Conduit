#!/bin/bash
# Checks a release-signed Conduit.app the way a pinned helper will see it:
# every binary signed by Resources/release-signing.pem with the hardened
# runtime, the app's bundled installer derives a pin that admits the app,
# that pin refuses the nested helper, pm-dns and the updater, and the app
# trusts the committed update key.
#
#   scripts/verify-release-signing.sh <Conduit.app> [release-signing.pem]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: verify-release-signing.sh <Conduit.app> [release-signing.pem]}"
PEM="${2:-$ROOT_DIR/Resources/release-signing.pem}"
BUNDLE_ID="io.github.srps.Conduit"
HELPER="$APP/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
PM_DNS="$APP/Contents/MacOS/pm-dns"
UPDATER="$APP/Contents/Helpers/Conduit Updater.app"
SPARKLE="$UPDATER/Contents/Frameworks/Sparkle.framework"
FEED_URL="https://github.com/srps/Conduit/releases/latest/download/appcast.xml"

failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/verify-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
expected="$(/usr/bin/openssl x509 -in "$PEM" -outform der | shasum -a 1 | awk '{ print $1 }')"

check_code() { # <label> <path> <identifier, or empty to skip that check>
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
    elif [ -n "$identifier" ] && [[ "$details" != *"Identifier=$identifier"$'\n'* ]]; then
        fail "$label: identifier is not $identifier ($(grep '^Identifier=' <<<"$details"))"
    else
        ok "$label: release certificate, hardened runtime${identifier:+, $identifier}"
    fi
}

check_code "app" "$APP" "$BUNDLE_ID"
check_code "helper" "$HELPER" "$BUNDLE_ID.Helper"
check_code "pm-dns" "$PM_DNS" "$BUNDLE_ID.pm-dns"
check_code "updater" "$UPDATER" "$BUNDLE_ID.Updater"
check_code "Sparkle.framework" "$SPARKLE" "org.sparkle-project.Sparkle"
# Sparkle names Autoupdate with a hash suffix; its identifier is not ours to pin.
check_code "Sparkle Autoupdate" "$SPARKLE/Versions/B/Autoupdate" ""
check_code "Sparkle Updater.app" "$SPARKLE/Versions/B/Updater.app" "org.sparkle-project.Sparkle.Updater"

# Library validation is off for the updater only (#111): it must load
# Sparkle, and the helper's pin refuses it. Conduit itself keeps it on.
if codesign -d --entitlements - "$UPDATER" 2>/dev/null | grep -q disable-library-validation; then
    ok "updater: library validation off, so it can load Sparkle"
else
    fail "updater: no disable-library-validation entitlement; it cannot load Sparkle"
fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q disable-library-validation; then
    fail "app: library validation is off in the process the helper admits"
else
    ok "app: library validation stays on"
fi

# The update feed and key the app trusts.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
expected_key="$(tr -d '[:space:]' < "$ROOT_DIR/Resources/sparkle-public-ed-key" 2>/dev/null || true)"
if [ -n "$expected_key" ] && [ "$(plist_value SUPublicEDKey)" = "$expected_key" ] && [ "$(plist_value SUFeedURL)" = "$FEED_URL" ]; then
    ok "update feed and public key"
else
    fail "update feed/key: SUFeedURL='$(plist_value SUFeedURL)' SUPublicEDKey='$(plist_value SUPublicEDKey)', expected the committed Resources/sparkle-public-ed-key"
fi
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
for code in "$HELPER" "$PM_DNS" "$UPDATER"; do
    if [ -n "$pin" ] && codesign --verify -R "=$pin" "$code" 2>/dev/null; then
        fail "the pin admits $(basename "$code"), which must never call the helper"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
