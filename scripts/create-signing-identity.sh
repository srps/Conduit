#!/bin/zsh
# Creates "Conduit Local Signing", a self-signed code-signing identity in the
# login keychain. Run once, as yourself (not sudo). bundle-app.sh signs with
# it when it is present, and install-helper.sh pins its leaf certificate so
# the privileged helper admits only programs signed by it (#46).
#
# The private key is never on disk unencrypted, and its passphrase never on a
# command line. The pin exists to keep out other programs running as you,
# and those can read your temporary files and anyone's `ps`:
#   - you choose a one-time transfer passphrase; it reaches openssl only
#     through file descriptors (`-passout fd:3`), from a shell builtin
#   - the key is generated encrypted and piped straight into the PKCS#12
#     export, so no key file exists at all; the only file holding it is the
#     .p12, encrypted under your passphrase
#   - `security import` asks you for that passphrase in its own dialog
#     (there is no way to hand it one except argv), then the .p12 is removed
# Temporaries are removed on every exit, including errors and Ctrl-C.
# The certificate is self-signed: it proves "built on this machine by the
# holder of this key", which is what the helper pin needs, and nothing more.
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
# the legacy algorithms `security import` still expects. Both tools can be
# replaced only so scripts/test-create-signing-identity.sh can run this
# without creating a certificate or touching a keychain.
OPENSSL="${CONDUIT_SIGNING_OPENSSL:-/usr/bin/openssl}"
SECURITY="${CONDUIT_SIGNING_SECURITY:-/usr/bin/security}"
DAYS=3650
MIN_PASSPHRASE=8

TRUST=true
IMPORT_ACCESS=()
for arg in "$@"; do
    case "$arg" in
        --no-trust) TRUST=false ;;
        --codesign-without-prompt) IMPORT_ACCESS=(-T /usr/bin/codesign) ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as yourself, not with sudo: the identity belongs in your login keychain."
    exit 1
fi

# Captured first: `grep -q` quitting early under pipefail would read as
# "not found" and make a second identity with the same name.
EXISTING="$("$SECURITY" find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
if [[ "$EXISTING" == *"\"$NAME\""* ]]; then
    echo "\"$NAME\" already exists in $KEYCHAIN:"
    print -r -- "$EXISTING" | grep "\"$NAME\""
    echo "Nothing to do. Delete it in Keychain Access first to make a new one"
    echo "(then rebuild with ./bundle-app.sh and rerun sudo ./install-helper.sh)."
    exit 0
fi

echo "Choose a one-time transfer passphrase. It protects the key until it is in"
echo "your keychain; macOS asks for it once more when importing. It is not kept."
PASSPHRASE=""
CONFIRM=""
read -rs "PASSPHRASE?Transfer passphrase: " || true
echo ""
read -rs "CONFIRM?Again: " || true
echo ""
if [ "${#PASSPHRASE}" -lt "$MIN_PASSPHRASE" ]; then
    echo "The passphrase must be at least $MIN_PASSPHRASE characters."
    exit 1
fi
if [ "$PASSPHRASE" != "$CONFIRM" ]; then
    echo "The passphrases differ."
    exit 1
fi
unset CONFIRM

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/conduit-signing.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

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

# `print` is a builtin: the passphrase goes into a pipe, not onto an argv.
# The key leaves `req` encrypted under it (no -nodes) on stdout and is held
# in this shell, never in a file; only the public certificate is written.
# Two steps rather than one pipeline: `pkcs12` reads the certificate file
# after the key, and in a pipeline it could look before `req` wrote it.
ENCRYPTED_KEY="$("$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days "$DAYS" \
    -config "$WORK/cert.cnf" -passout fd:3 -keyout /dev/stdout -out "$WORK/cert.pem" \
    3< <(print -r -- "$PASSPHRASE"))"
if [[ "$ENCRYPTED_KEY" != *"-----BEGIN ENCRYPTED PRIVATE KEY-----"* && "$ENCRYPTED_KEY" != *"Proc-Type: 4,ENCRYPTED"* ]]; then
    echo "openssl did not produce an encrypted key; stopping before anything is exported." >&2
    exit 1
fi
print -r -- "$ENCRYPTED_KEY" \
    | "$OPENSSL" pkcs12 -export -name "$NAME" -in "$WORK/cert.pem" -inkey /dev/stdin \
        -passin fd:3 -passout fd:4 -out "$WORK/identity.p12" \
        3< <(print -r -- "$PASSPHRASE") 4< <(print -r -- "$PASSPHRASE")
unset PASSPHRASE ENCRYPTED_KEY

echo "Importing into $KEYCHAIN. macOS will ask for the transfer passphrase."
"$SECURITY" import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 "${IMPORT_ACCESS[@]}"
rm -f "$WORK/identity.p12"
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
    if ! "$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
        echo "Trust setting not changed. Signing still works; rerun with --no-trust to skip this step."
    fi
fi

echo ""
"$SECURITY" find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\"" || true
echo ""
echo "Next:"
echo "  ./bundle-app.sh --release           # signs with \"$NAME\" and the hardened runtime"
echo "  install the app (./bundle-app.sh --release --install, when Conduit may be restarted)"
echo "  sudo ./install-helper.sh            # pins this certificate for the helper's callers"
