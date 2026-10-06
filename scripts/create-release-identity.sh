#!/bin/zsh
# Creates Conduit's two release keys, once per project, run by the owner in
# their own Terminal (not through an agent's shell: what is typed and printed
# here must not land in a transcript):
#
#   "Conduit Release Signing"  a self-signed code-signing certificate. CI signs
#                              every published release with it, so a helper can
#                              pin one certificate that admits every release
#                              and an update keeps the helper's admission (#111).
#   Sparkle Ed25519 key        signs every update archive; the app accepts an
#                              update only with a valid signature (#111).
#
# Outputs, all written and checked before anything is uploaded:
#   Resources/release-signing.pem      public certificate; commit it
#   Resources/sparkle-public-ed-key    public update key; commit it
#   <backup-dir>/conduit-release-signing.p12
#                                      certificate and private key, encrypted
#                                      under your passphrase
#   <backup-dir>/sparkle-ed25519.key.enc
#                                      update key, encrypted under the same
#                                      passphrase (AES-256-CBC, PBKDF2)
# With --upload, then: the GitHub environment "release" (deployments from v*
# tags only), a tag ruleset that lets only repository admins create, move or
# delete v* tags, and the environment secrets CONDUIT_RELEASE_P12_BASE64,
# CONDUIT_RELEASE_P12_PASSWORD and SPARKLE_ED_PRIVATE_KEY.
# --upload-from-backup DIR does only that upload, from an earlier run's
# backups, for example after a failed upload or a deleted environment.
#
# No private key or passphrase is ever on an argv or in an unencrypted file:
# passphrases reach openssl through file descriptors, secrets reach `gh`
# through stdin, and the temporary directory is removed on every exit.
# Keep the backup files and the passphrase apart (for example, the files on
# an encrypted drive and the passphrase in a password manager). Losing them
# means a new identity and one more helper reinstall for every user; see
# docs/release-signing.md.
#
#   scripts/create-release-identity.sh --backup-dir DIR [--upload] [--repo OWNER/NAME]
#   scripts/create-release-identity.sh --upload-from-backup DIR [--repo OWNER/NAME]
set -euo pipefail

NAME="Conduit Release Signing"
ROOT_DIR="${CONDUIT_RELEASE_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_OUT="$ROOT_DIR/Resources/release-signing.pem"
ED_PUBLIC_OUT="$ROOT_DIR/Resources/sparkle-public-ed-key"
P12_NAME="conduit-release-signing.p12"
ED_NAME="sparkle-ed25519.key.enc"
# The system LibreSSL: its PKCS#12 defaults are the legacy algorithms
# `security import` on the release runner expects. `gh` and the key
# generator can be replaced so scripts/test-create-release-identity.sh runs
# this without a GitHub repository.
OPENSSL="${CONDUIT_RELEASE_OPENSSL:-/usr/bin/openssl}"
GH="${CONDUIT_RELEASE_GH:-gh}"
KEYGEN="${CONDUIT_RELEASE_KEYGEN:-}"
# A self-signed certificate is pinned by its hash, not trusted through a
# chain, so its lifetime only has to outlast the project; renewing it means
# a helper reinstall for every user.
DAYS=7300
MIN_PASSPHRASE=16
PBKDF2_ITERATIONS=600000
RULESET_NAME="Release tags"

usage() {
    sed -n '2,39p' "$0"
}

BACKUP_DIR=""
UPLOAD=false
FROM_BACKUP=false
REPO="srps/Conduit"
while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)
            [ $# -ge 2 ] || { echo "--backup-dir needs a directory"; exit 1; }
            BACKUP_DIR="$2"; shift 2 ;;
        --upload) UPLOAD=true; shift ;;
        --upload-from-backup)
            [ $# -ge 2 ] || { echo "--upload-from-backup needs the backup directory"; exit 1; }
            BACKUP_DIR="$2"; UPLOAD=true; FROM_BACKUP=true; shift 2 ;;
        --repo)
            [ $# -ge 2 ] || { echo "--repo needs OWNER/NAME"; exit 1; }
            REPO="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as yourself, not with sudo."
    exit 1
fi
if [ -z "$BACKUP_DIR" ]; then
    echo "--backup-dir is required: the encrypted private keys are written there."
    exit 1
fi
if $FROM_BACKUP; then
    for required in "$BACKUP_DIR/$P12_NAME" "$BACKUP_DIR/$ED_NAME" "$CERT_OUT" "$ED_PUBLIC_OUT"; do
        [ -f "$required" ] || { echo "$required is missing; --upload-from-backup needs an earlier run's outputs."; exit 1; }
    done
else
    for existing in "$CERT_OUT" "$ED_PUBLIC_OUT"; do
        if [ -e "$existing" ]; then
            echo "$existing already exists, so the release identity has been created."
            echo "To upload it again use --upload-from-backup. Rotating it is a deliberate"
            echo "procedure (docs/release-signing.md); remove it first."
            exit 1
        fi
    done
    for name in "$P12_NAME" "$ED_NAME"; do
        if [ -e "$BACKUP_DIR/$name" ]; then
            echo "$BACKUP_DIR/$name already exists; refusing to overwrite a backup."
            exit 1
        fi
    done
fi
if $UPLOAD && ! "$GH" auth status >/dev/null 2>&1; then
    echo "Uploading needs an authenticated gh (gh auth login)."
    exit 1
fi

PASSPHRASE=""
if $FROM_BACKUP; then
    read -rs "PASSPHRASE?Backup passphrase: " || true
    echo ""
else
    echo "Choose a backup passphrase (at least $MIN_PASSPHRASE characters). It encrypts"
    echo "both backup files and is the CI secret that unlocks the certificate."
    CONFIRM=""
    read -rs "PASSPHRASE?Backup passphrase: " || true
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
fi

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/conduit-release.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

leaf_sha1() { # <PEM certificate on stdin>
    "$OPENSSL" x509 -outform der | shasum -a 1 | awk '{ print $1 }'
}

# The backup's certificate, which must be the published one.
p12_leaf() { # <p12>
    "$OPENSSL" pkcs12 -in "$1" -nokeys -clcerts -passin fd:3 3< <(print -r -- "$PASSPHRASE") 2>/dev/null | leaf_sha1
}

# Decrypts the update key backup; fails on a wrong passphrase.
decrypt_ed_backup() { # <file>
    "$OPENSSL" enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter "$PBKDF2_ITERATIONS" -a \
        -in "$1" -pass fd:3 3< <(print -r -- "$PASSPHRASE")
}

upload() { # <p12 file>
    # Called as `upload … || upload_failed`, where set -e does not apply, so
    # every step returns its own failure.
    local p12="$1"
    echo "Creating the GitHub environment \"release\" (deployments from v* tags only)..."
    "$GH" api -X PUT "repos/$REPO/environments/release" \
        -F 'deployment_branch_policy[protected_branches]=false' \
        -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null || return 1
    local policies
    policies="$("$GH" api "repos/$REPO/environments/release/deployment-branch-policies" \
        --jq '.branch_policies[] | select(.type == "tag") | .name')" || return 1
    if ! grep -qx 'v\*' <<<"$policies"; then
        "$GH" api -X POST "repos/$REPO/environments/release/deployment-branch-policies" \
            -f 'name=v*' -f 'type=tag' >/dev/null || return 1
    fi
    # The environment policy only matches the ref; who may create the ref is
    # this ruleset's job. Repository admins (role 5) may bypass it.
    local rulesets
    rulesets="$("$GH" api "repos/$REPO/rulesets" --jq '.[].name')" || return 1
    if ! grep -qxF "$RULESET_NAME" <<<"$rulesets"; then
        echo "Restricting v* tags to repository admins (ruleset \"$RULESET_NAME\")..."
        "$GH" api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<JSON || return 1
{"name": "$RULESET_NAME", "target": "tag", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]}
JSON
    fi
    echo "Uploading the release secrets..."
    base64 -i "$p12" | tr -d '\n' \
        | "$GH" secret set CONDUIT_RELEASE_P12_BASE64 --env release --repo "$REPO" || return 1
    print -rn -- "$PASSPHRASE" | "$GH" secret set CONDUIT_RELEASE_P12_PASSWORD --env release --repo "$REPO" || return 1
    print -rn -- "$ED_PRIVATE" | "$GH" secret set SPARKLE_ED_PRIVATE_KEY --env release --repo "$REPO" || return 1
}

upload_failed() {
    echo "" >&2
    echo "The upload did not finish. Every local output is written and checked;" >&2
    echo "retry with: scripts/create-release-identity.sh --upload-from-backup $BACKUP_DIR --repo $REPO" >&2
    exit 1
}

if $FROM_BACKUP; then
    if [ "$(p12_leaf "$BACKUP_DIR/$P12_NAME")" != "$(leaf_sha1 < "$CERT_OUT")" ]; then
        echo "$BACKUP_DIR/$P12_NAME does not open with that passphrase, or is not the certificate in $CERT_OUT." >&2
        exit 1
    fi
    if ! ED_PRIVATE="$(decrypt_ed_backup "$BACKUP_DIR/$ED_NAME" 2>/dev/null)" || [ "${#ED_PRIVATE}" -ne 44 ]; then
        echo "$BACKUP_DIR/$ED_NAME does not open with that passphrase." >&2
        exit 1
    fi
    upload "$BACKUP_DIR/$P12_NAME" || upload_failed
    unset PASSPHRASE ED_PRIVATE
    echo "GitHub environment \"release\" of $REPO holds the three secrets."
    exit 0
fi

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

# The key leaves `req` encrypted (no -nodes) on stdout and stays in this
# shell; only the public certificate is written. Same pattern as
# create-signing-identity.sh.
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
unset ENCRYPTED_KEY

echo "Generating the Sparkle update key..."
if [ -n "$KEYGEN" ]; then
    KEYS="$("$KEYGEN")"
else
    # The interpreter's compile scratch goes under $WORK, so it is removed too.
    KEYS="$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        TMPDIR="$WORK" xcrun swift "$SCRIPT_DIR/ed25519-keygen.swift")"
fi
ED_PRIVATE="${KEYS%%$'\n'*}"
ED_PUBLIC="${KEYS#*$'\n'}"
unset KEYS
if [ "${#ED_PRIVATE}" -ne 44 ] || [ "${#ED_PUBLIC}" -ne 44 ]; then
    echo "The key generator did not print two base64 Ed25519 keys." >&2
    exit 1
fi
print -rn -- "$ED_PRIVATE" \
    | "$OPENSSL" enc -aes-256-cbc -md sha256 -pbkdf2 -iter "$PBKDF2_ITERATIONS" -salt -a \
        -pass fd:3 -out "$WORK/$ED_NAME" 3< <(print -r -- "$PASSPHRASE")

# Every local output first, each checked by reading it back, so a failure
# from here on (a full backup volume, a failed upload) never leaves keys that
# exist only in GitHub or only in a temporary directory.
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
cp "$WORK/identity.p12" "$BACKUP_DIR/$P12_NAME"
cp "$WORK/$ED_NAME" "$BACKUP_DIR/$ED_NAME"
if [ "$(p12_leaf "$BACKUP_DIR/$P12_NAME")" != "$(leaf_sha1 < "$WORK/cert.pem")" ] \
    || [ "$(decrypt_ed_backup "$BACKUP_DIR/$ED_NAME")" != "$ED_PRIVATE" ]; then
    echo "The backups in $BACKUP_DIR do not read back; nothing was published or uploaded." >&2
    rm -f "$BACKUP_DIR/$P12_NAME" "$BACKUP_DIR/$ED_NAME"
    exit 1
fi
mkdir -p "$(dirname "$CERT_OUT")"
cp "$WORK/cert.pem" "$CERT_OUT"
chmod 644 "$CERT_OUT"
print -r -- "$ED_PUBLIC" > "$ED_PUBLIC_OUT"
chmod 644 "$ED_PUBLIC_OUT"

if $UPLOAD; then
    upload "$BACKUP_DIR/$P12_NAME" || upload_failed
fi
unset PASSPHRASE ED_PRIVATE

LEAF_SHA1="$(leaf_sha1 < "$CERT_OUT")"
LEAF_SHA256="$("$OPENSSL" x509 -in "$CERT_OUT" -outform der | shasum -a 256 | awk '{ print $1 }')"
echo ""
echo "Created \"$NAME\" (leaf SHA-1 $LEAF_SHA1, SHA-256 $LEAF_SHA256)."
echo "Public, commit these:"
echo "  $CERT_OUT"
echo "  $ED_PUBLIC_OUT"
echo "Private, encrypted under your passphrase; store them away from it:"
echo "  $BACKUP_DIR/$P12_NAME"
echo "  $BACKUP_DIR/$ED_NAME"
if $UPLOAD; then
    echo "GitHub environment \"release\" of $REPO holds the three secrets; v* tags are admin-only."
else
    echo "Nothing was uploaded. To upload later: --upload-from-backup $BACKUP_DIR"
fi
