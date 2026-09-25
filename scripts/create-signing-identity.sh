#!/bin/zsh
# Creates "Conduit Local Signing", a self-signed code-signing identity in the
# login keychain. Run once, as yourself (not sudo). bundle-app.sh signs with
# it when it is present, and install-helper.sh pins its leaf certificate so
# the privileged helper admits only programs signed by it (#46).
#
# The private key never leaves the login keychain after import; the
# temporary files it is made from are removed on exit. The certificate is
# self-signed: it proves "built on this machine by the holder of this key",
# which is what the helper pin needs, and nothing to anyone else.
#
# The key's access list is left empty: each build asks you to let codesign
# use it. Answer "Allow", not "Always Allow". A key codesign may use without
# asking is a key any program running as you can sign itself with, and then
# the helper's pin admits that program too.
#
#   scripts/create-signing-identity.sh              create it (no-op if present)
#   scripts/create-signing-identity.sh --no-trust   skip the user trust setting
#   scripts/create-signing-identity.sh --codesign-without-prompt
#                                                   let codesign use the key silently
#                                                   (convenient; see above for the cost)
set -euo pipefail

NAME="Conduit Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The system LibreSSL, not a Homebrew OpenSSL 3: its PKCS#12 defaults are
# the legacy algorithms `security import` still expects.
OPENSSL=/usr/bin/openssl
DAYS=3650

TRUST=true
IMPORT_ACCESS=()
for arg in "$@"; do
    case "$arg" in
        --no-trust) TRUST=false ;;
        --codesign-without-prompt) IMPORT_ACCESS=(-T /usr/bin/codesign) ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as yourself, not with sudo: the identity belongs in your login keychain."
    exit 1
fi

# Captured first: `grep -q` quitting early under pipefail would read as
# "not found" and make a second identity with the same name.
EXISTING="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
if [[ "$EXISTING" == *"\"$NAME\""* ]]; then
    echo "\"$NAME\" already exists in $KEYCHAIN:"
    print -r -- "$EXISTING" | grep "\"$NAME\""
    echo "Nothing to do. Delete it in Keychain Access first to make a new one"
    echo "(then rebuild with ./bundle-app.sh and rerun sudo ./install-helper.sh)."
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/conduit-signing.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -nodes -days "$DAYS" \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# A one-time password for the transfer file only; it dies with $WORK.
P12_PASS="$("$OPENSSL" rand -hex 24)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASS" "${IMPORT_ACCESS[@]}"
echo "Imported \"$NAME\" into $KEYCHAIN."
if [ ${#IMPORT_ACCESS[@]} -eq 0 ]; then
    echo "Each ./bundle-app.sh run will ask to let codesign use the key: choose Allow, not Always Allow."
else
    echo "codesign may use the key without asking. Any program running as you can now sign as Conduit."
fi

if $TRUST; then
    # A user-level trust setting for code signing only (not SSL, not
    # anything else), so `security find-identity -v` lists it as valid.
    # codesign and the helper's pin do not depend on it — the pin is the
    # certificate's hash, not a chain — but without it Keychain Access shows
    # the certificate as untrusted, which reads like a fault. macOS asks for
    # your password to change trust settings.
    echo "Marking it trusted for code signing (macOS will ask for your password)..."
    if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
        echo "Trust setting not changed. Signing still works; rerun with --no-trust to skip this step."
    fi
fi

echo ""
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\"" || true
echo ""
echo "Next:"
echo "  ./bundle-app.sh --release           # signs with \"$NAME\" and the hardened runtime"
echo "  install the app (./bundle-app.sh --release --install, when Conduit may be restarted)"
echo "  sudo ./install-helper.sh            # pins this certificate for the helper's callers"
