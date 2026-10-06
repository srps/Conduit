#!/bin/bash
# Release CI only: puts "Conduit Release Signing" into a throwaway keychain
# so bundle-app.sh --share can sign with it, and refuses an identity whose
# certificate is not the committed Resources/release-signing.pem (a secret
# rotated without the public half, or the reverse, would ship releases the
# pinned helpers refuse).
#
# Reads CONDUIT_RELEASE_P12_BASE64 and CONDUIT_RELEASE_P12_PASSWORD; writes
# CONDUIT_RELEASE_SIGNING_IDENTITY and CONDUIT_RELEASE_KEYCHAIN to
# $GITHUB_ENV. `--remove` deletes the keychain again. The runner is a
# single-use VM, which is why `security import -P` (the only way to hand it
# a passphrase) is acceptable here and nowhere else.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is not set; this script is for the release runner}"
KEYCHAIN="$TEMP_ROOT/conduit-release.keychain-db"
CERT="$ROOT_DIR/Resources/release-signing.pem"

if [ "${1:-}" = "--remove" ]; then
    if [ -e "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN"
        echo "Removed $KEYCHAIN."
    fi
    exit 0
fi

: "${CONDUIT_RELEASE_P12_BASE64:?the release environment secret CONDUIT_RELEASE_P12_BASE64 is missing}"
: "${CONDUIT_RELEASE_P12_PASSWORD:?the release environment secret CONDUIT_RELEASE_P12_PASSWORD is missing}"
: "${GITHUB_ENV:?GITHUB_ENV is not set}"
if [ ! -f "$CERT" ]; then
    echo "$CERT is missing: run scripts/create-release-identity.sh and commit its public outputs." >&2
    exit 1
fi

umask 077
work="$(mktemp -d "$TEMP_ROOT/conduit-identity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
printf '%s' "$CONDUIT_RELEASE_P12_BASE64" | base64 --decode > "$work/identity.p12"

keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
security import "$work/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
    -P "$CONDUIT_RELEASE_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$KEYCHAIN" >/dev/null
# codesign finds identities only through the search list.
existing=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    existing+=("${line%\"}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"

expected="$(openssl x509 -in "$CERT" -outform der | shasum -a 1 | awk '{ print toupper($1) }')"
found="$(security find-identity -p codesigning "$KEYCHAIN" \
    | awk '/"Conduit Release Signing"/ { print $2; exit }')"
if [ -z "$found" ]; then
    echo "The release secret holds no \"Conduit Release Signing\" code-signing identity." >&2
    exit 1
fi
if [ "$found" != "$expected" ]; then
    echo "The release secret's certificate ($found) is not Resources/release-signing.pem ($expected)." >&2
    exit 1
fi

{
    echo "CONDUIT_RELEASE_SIGNING_IDENTITY=$found"
    echo "CONDUIT_RELEASE_KEYCHAIN=$KEYCHAIN"
} >> "$GITHUB_ENV"
echo "Imported \"Conduit Release Signing\" ($found) into $KEYCHAIN."
