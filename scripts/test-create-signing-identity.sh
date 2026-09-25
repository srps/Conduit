#!/bin/bash
# create-signing-identity.sh against stand-in openssl and security binaries:
# no certificate is made and no keychain is touched. What is checked is the
# script's handling of the secret, which is the part a same-uid process could
# attack: the passphrase never on an argv, no unencrypted key in any file,
# no -P to `security import`, and nothing left behind on any exit.
set -euo pipefail

script="${CREATE_SIGNING_IDENTITY_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/create-signing-identity.sh}"
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo."
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/signing-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/bin"
mkdir -p "$stubs"
PASSPHRASE='correct horse battery'

# Records its argv, reads each fd:N passphrase source it is given, and
# writes a key in the form the flags ask for: encrypted unless -nodes.
cat > "$stubs/openssl" <<'STUB'
#!/bin/bash
log="$STUB_LOG"
echo "ARGV openssl $*" >> "$log"
sub="$1"; shift
keyout=""; out=""; inkey=""; nodes=false; passes=()
while [ $# -gt 0 ]; do
    case "$1" in
        -keyout) keyout="$2"; shift ;;
        -out) out="$2"; shift ;;
        -inkey) inkey="$2"; shift ;;
        -nodes) nodes=true ;;
        -passout|-passin) passes+=("$2"); shift ;;
    esac
    shift
done
for source in "${passes[@]}"; do
    case "$source" in
        fd:*) IFS= read -r got <&"${source#fd:}" || true
              if [ "$got" = "$STUB_EXPECTED" ]; then echo "PASS-OK $sub" >> "$log"; else echo "PASS-WRONG $sub" >> "$log"; fi ;;
        *) echo "PASS-NOT-FD $sub" >> "$log" ;;
    esac
done
case "$sub" in
    req)
        if $nodes || [ ${#passes[@]} -eq 0 ]; then key="-----BEGIN PRIVATE KEY-----"; else key="-----BEGIN ENCRYPTED PRIVATE KEY-----"; fi
        printf '%s\nstub\n-----END-----\n' "$key" > "$keyout"
        printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' > "$out"
        ;;
    pkcs12)
        if grep -q "BEGIN ENCRYPTED PRIVATE KEY" "$inkey"; then echo "KEY-IN encrypted" >> "$log"; else echo "KEY-IN plain" >> "$log"; fi
        printf 'stub p12\n' > "$out"
        ;;
esac
STUB

# Looks at every file under the script's TMPDIR at import time: that is
# when the most material exists on disk.
cat > "$stubs/security" <<'STUB'
#!/bin/bash
log="$STUB_LOG"
echo "ARGV security $*" >> "$log"
case "$1" in
    find-identity) echo "     0 identities found" ;;
    import)
        if grep -rlE "BEGIN (RSA )?PRIVATE KEY" "$STUB_TMP" >/dev/null 2>&1; then echo "PLAINTEXT-ON-DISK" >> "$log"; fi
        exit "${STUB_IMPORT_RC:-0}"
        ;;
esac
exit 0
STUB
chmod +x "$stubs/openssl" "$stubs/security"

failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

run() { # <label> <stdin> <import rc> [args...]
    local label="$1" input="$2" import_rc="$3"
    shift 3
    RUN_TMP="$scratch/tmp-$label"
    RUN_LOG="$scratch/log-$label"
    mkdir -p "$RUN_TMP"
    : > "$RUN_LOG"
    RUN_RC=0
    printf '%s' "$input" | TMPDIR="$RUN_TMP" STUB_TMP="$RUN_TMP" STUB_LOG="$RUN_LOG" \
        STUB_EXPECTED="$PASSPHRASE" STUB_IMPORT_RC="$import_rc" \
        CONDUIT_SIGNING_OPENSSL="$stubs/openssl" CONDUIT_SIGNING_SECURITY="$stubs/security" \
        PATH="$stubs:$PATH" zsh "$script" "$@" > "$scratch/out-$label" 2>&1 || RUN_RC=$?
}

# The happy path.
run happy "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' 0 --no-trust
[ "$RUN_RC" -eq 0 ] && ok "creates the identity" || fail "exit $RUN_RC: $(cat "$scratch/out-happy")"
grep "^ARGV" "$RUN_LOG" | grep -qF "$PASSPHRASE" && fail "the passphrase was on an argv" || ok "the passphrase is on no argv"
grep "^ARGV openssl" "$RUN_LOG" | grep -qE -- "(pass|env|file):" && fail "a passphrase source other than a file descriptor was used" || ok "passphrase sources are file descriptors only"
grep "^ARGV openssl" "$RUN_LOG" | grep -q -- "-nodes" && fail "a key was written unencrypted (-nodes)" || ok "no -nodes"
grep -q "PLAINTEXT-ON-DISK" "$RUN_LOG" && fail "an unencrypted key was on disk at import time" || ok "no unencrypted key on disk"
grep -q "KEY-IN encrypted" "$RUN_LOG" && ok "the key reaches pkcs12 encrypted" || fail "the key reached pkcs12 unencrypted: $(cat "$RUN_LOG")"
[ "$(grep -c "PASS-OK" "$RUN_LOG")" -eq 3 ] && ! grep -qE "PASS-(WRONG|NOT-FD)" "$RUN_LOG" \
    && ok "every passphrase arrives through a file descriptor" || fail "passphrase delivery: $(grep PASS- "$RUN_LOG")"
grep "^ARGV security import" "$RUN_LOG" | grep -q -- " -P" && fail "security import was given -P" || ok "security import asks for the passphrase itself"
grep "^ARGV security import" "$RUN_LOG" | grep -q -- "-T" && fail "codesign was granted silent access by default" || ok "no silent codesign access by default"
[ -z "$(ls -A "$RUN_TMP")" ] && ok "nothing left behind" || fail "left behind: $(ls -A "$RUN_TMP")"

# A failed import still cleans up.
run failedimport "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' 1 --no-trust
[ "$RUN_RC" -ne 0 ] && ok "a failed import fails the script" || fail "a failed import exited 0"
[ -z "$(ls -A "$RUN_TMP")" ] && ok "a failed import leaves nothing behind" || fail "left behind after failure: $(ls -A "$RUN_TMP")"

# Passphrases that differ, or are too short, stop before anything is made.
run mismatch "$PASSPHRASE"$'\n'"something else"$'\n' 0 --no-trust
[ "$RUN_RC" -ne 0 ] && ! grep -q "^ARGV openssl" "$RUN_LOG" && ok "differing passphrases stop before openssl" || fail "mismatch (exit $RUN_RC)"
run short $'short\nshort\n' 0 --no-trust
[ "$RUN_RC" -ne 0 ] && ! grep -q "^ARGV openssl" "$RUN_LOG" && ok "a short passphrase stops before openssl" || fail "short (exit $RUN_RC)"

# --codesign-without-prompt is the only way to get -T.
run silent "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' 0 --no-trust --codesign-without-prompt
grep "^ARGV security import" "$RUN_LOG" | grep -q -- "-T /usr/bin/codesign" && ok "--codesign-without-prompt grants codesign" || fail "no -T with --codesign-without-prompt"

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
