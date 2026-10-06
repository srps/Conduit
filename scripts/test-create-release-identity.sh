#!/bin/bash
# create-release-identity.sh for real, into a scratch checkout and backup
# directory, with a logging openssl wrapper and a stand-in gh: no GitHub
# repository or keychain is touched. Checks that both backups decrypt with
# the passphrase to the published public halves, that the secrets reach gh
# only on stdin, that no passphrase or key is ever on an argv, and that
# nothing is left in TMPDIR.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/create-release-identity.sh"
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo."
    exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/release-identity-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo" "$scratch/tmp" "$scratch/gh"
PASSPHRASE='correct horse battery staple'
log="$scratch/argv.log"

cat > "$scratch/bin/openssl" <<STUB
#!/bin/bash
echo "ARGV openssl \$*" >> "$log"
exec /usr/bin/openssl "\$@"
STUB
# A stand-in GitHub: records argv, each secret's stdin into a file named
# after it, the environment and ruleset bodies, and DELETEs. The release
# environment starts with a stale branch policy; STUB_RULESET seeds an
# existing ruleset; STUB_GH_FAIL_SECRET names a secret whose upload fails.
cat > "$scratch/bin/gh" <<'STUB'
#!/bin/bash
echo "ARGV gh $*" >> "$STUB_LOG"
dir="$STUB_DIR"
case "$*" in
    "auth status"*) exit 0 ;;
    "api user"*) echo 42 ;;
    "secret set "*)
        if [ "$3" = "${STUB_GH_FAIL_SECRET:-}" ]; then cat > /dev/null; exit 1; fi
        cat > "$dir/$3" ;;
    "api -X PUT repos/"*"/environments/release --input -") cat > "$dir/environment.json" ;;
    "api --paginate repos/"*"/deployment-branch-policies --jq "*) echo "11 branch main" ;;
    "api -X DELETE "*) : ;;
    "api -X POST "*"/deployment-branch-policies"*) : ;;
    "api --paginate repos/"*"/rulesets --jq "*)
        if [ -f "$dir/ruleset.json" ]; then echo "7 Release tags"; fi ;;
    "api -X POST repos/"*"/rulesets --jq .id --input -") cat > "$dir/ruleset.json"; echo 7 ;;
    "api repos/"*"/rulesets/7") cat "$dir/ruleset.json" ;;
    *) echo "unexpected gh call: $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$scratch/bin/openssl" "$scratch/bin/gh"

failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

run() { # <stdin> [args...]
    local input="$1"
    shift
    printf '%s' "$input" | TMPDIR="$scratch/tmp" STUB_LOG="$log" STUB_DIR="$scratch/gh" \
        CONDUIT_RELEASE_REPO_DIR="$scratch/repo" \
        CONDUIT_RELEASE_OPENSSL="$scratch/bin/openssl" \
        CONDUIT_RELEASE_GH="$scratch/bin/gh" \
        "$script" "$@" > "$scratch/out.log" 2>&1
}

rc=0; run "" --backup-dir "$scratch/backup" || rc=$?
if [ "$rc" -ne 0 ] && grep -q "Could not read the passphrase" "$scratch/out.log"; then ok "a closed input stops instead of using an empty passphrase"; else fail "closed input (exit $rc): $(cat "$scratch/out.log")"; fi
rc=0; run $'short\nshort\n' --backup-dir "$scratch/backup" || rc=$?
if [ "$rc" -ne 0 ] && grep -q "at least 16" "$scratch/out.log"; then ok "a short passphrase is refused"; else fail "short passphrase (exit $rc)"; fi
rc=0; run "$PASSPHRASE"$'\nsomething else entirely\n' --backup-dir "$scratch/backup" || rc=$?
if [ "$rc" -ne 0 ] && grep -q "differ" "$scratch/out.log"; then ok "mismatched passphrases are refused"; else fail "mismatch (exit $rc)"; fi
rc=0; run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' || rc=$?
if [ "$rc" -ne 0 ] && grep -q "backup-dir is required" "$scratch/out.log"; then ok "--backup-dir is required"; else fail "no backup dir (exit $rc)"; fi

# An existing ruleset of that name that does not protect v* tags stops the
# upload before any secret is set.
echo '{"name":"Release tags","target":"tag","enforcement":"disabled","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"creation"}]}' > "$scratch/gh/ruleset.json"
rc=0; run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' --backup-dir "$scratch/backup" --upload --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not actively restrict" "$scratch/out.log" && ! ls "$scratch/gh" | grep -q '^CONDUIT\|^SPARKLE'; then
    ok "a ruleset that does not protect v* tags stops the upload before any secret"
else
    fail "ineffective ruleset (exit $rc): $(cat "$scratch/out.log")"
fi
rm -f "$scratch/gh/ruleset.json"
# Nor does one that excludes some v* tags from the restriction.
echo '{"name":"Release tags","target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":["refs/tags/v0*"]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' > "$scratch/gh/ruleset.json"
rm -rf "$scratch/repo/Resources" "$scratch/backup"
rc=0; run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' --backup-dir "$scratch/backup" --upload --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not actively restrict" "$scratch/out.log" && ! ls "$scratch/gh" | grep -q '^CONDUIT\|^SPARKLE'; then
    ok "a ruleset that excludes some v* tags stops the upload"
else
    fail "ruleset with exclusions (exit $rc): $(cat "$scratch/out.log")"
fi
# Nor does one that lets a non-admin bypass it: a bypass may create v* tags.
echo '{"name":"Release tags","target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' > "$scratch/gh/ruleset.json"
rm -rf "$scratch/repo/Resources" "$scratch/backup"
rc=0; run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' --backup-dir "$scratch/backup" --upload --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not actively restrict" "$scratch/out.log" && ! ls "$scratch/gh" | grep -q '^CONDUIT\|^SPARKLE'; then
    ok "a ruleset a non-admin may bypass stops the upload"
else
    fail "bypassable ruleset (exit $rc): $(cat "$scratch/out.log")"
fi
rm -f "$scratch/gh/ruleset.json"
# That run wrote its local outputs before stopping; start the next case clean.
if [ -s "$scratch/repo/Resources/release-signing.pem" ] && [ -s "$scratch/backup/conduit-release-signing.p12" ]; then
    ok "local outputs are written before the upload is attempted"
else
    fail "the stopped upload left no local outputs"
fi
rm -rf "$scratch/repo/Resources" "$scratch/backup"

# The first upload fails at its last secret: every local output must already
# be written, and the retry must finish from the backups.
rc=0; STUB_GH_FAIL_SECRET=SPARKLE_ED_PRIVATE_KEY run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' --backup-dir "$scratch/backup" --upload --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "The upload did not finish" "$scratch/out.log" && grep -q -- "--upload-from-backup" "$scratch/out.log"; then ok "a failed upload says how to retry"; else fail "failed upload (exit $rc): $(cat "$scratch/out.log")"; fi
rc=0; run $'wrong passphrase for this\n' --upload-from-backup "$scratch/backup" --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not open" "$scratch/out.log"; then ok "a retry with the wrong passphrase is refused"; else fail "wrong-passphrase retry (exit $rc): $(cat "$scratch/out.log")"; fi
# A decryptable update key from another pair is refused.
mv "$scratch/backup/sparkle-ed25519.key.enc" "$scratch/ed.good"
other_seed="$(xcrun swift "$(dirname "$script")/ed25519-keygen.swift" | head -1)"
printf '%s' "$other_seed" | /usr/bin/openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 600000 -salt -a \
    -pass fd:3 -out "$scratch/backup/sparkle-ed25519.key.enc" 3< <(printf '%s\n' "$PASSPHRASE")
rc=0; run "$PASSPHRASE"$'\n' --upload-from-backup "$scratch/backup" --repo example/repo || rc=$?
if [ "$rc" -ne 0 ] && grep -q "is not the update key" "$scratch/out.log"; then ok "a restored update key from another pair is refused"; else fail "mismatched update key (exit $rc): $(cat "$scratch/out.log")"; fi
mv "$scratch/ed.good" "$scratch/backup/sparkle-ed25519.key.enc"
rm -f "$scratch/gh/SPARKLE_ED_PRIVATE_KEY"

rc=0; run "$PASSPHRASE"$'\n' --upload-from-backup "$scratch/backup" --repo example/repo || rc=$?
if [ "$rc" -eq 0 ]; then ok "the retry from the backups uploads"; else fail "retry (exit $rc): $(cat "$scratch/out.log")"; fi
if grep -q "api -X DELETE repos/example/repo/environments/release/deployment-branch-policies/11" "$log"; then
    ok "a stale branch policy is removed, so only v* tags deploy"
else
    fail "the stale branch policy was kept"
fi
if python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); assert e["reviewers"]==[{"type":"User","id":42}]' "$scratch/gh/environment.json"; then
    ok "every release deployment waits for the owner's approval"
else
    fail "environment body: $(cat "$scratch/gh/environment.json" 2>/dev/null)"
fi

pem="$scratch/repo/Resources/release-signing.pem"
ed_public="$scratch/repo/Resources/sparkle-public-ed-key"
p12="$scratch/backup/conduit-release-signing.p12"
ed_backup="$scratch/backup/sparkle-ed25519.key.enc"
for file in "$pem" "$ed_public" "$p12" "$ed_backup"; do
    [ -s "$file" ] || fail "missing output $file"
done
if [ "$(stat -f %Lp "$scratch/backup")" = 700 ] && [ "$(stat -f %Lp "$p12")" = 600 ] && [ "$(stat -f %Lp "$ed_backup")" = 600 ]; then
    ok "backups are private to the owner"
else
    fail "backup modes: $(stat -f '%Lp %N' "$scratch/backup" "$p12" "$ed_backup")"
fi

subject="$(/usr/bin/openssl x509 -in "$pem" -noout -subject)"
usage="$(/usr/bin/openssl x509 -in "$pem" -noout -text | grep -A1 'Extended Key Usage' | tail -1)"
if [[ "$subject" == *"Conduit Release Signing"* && "$usage" == *"Code Signing"* ]]; then ok "the certificate is a code-signing certificate"; else fail "certificate: $subject / $usage"; fi

p12_cert="$(/usr/bin/openssl pkcs12 -in "$p12" -nokeys -clcerts -passin fd:3 3< <(printf '%s\n' "$PASSPHRASE") 2>/dev/null | /usr/bin/openssl x509 -outform der | shasum -a 1)"
pem_cert="$(/usr/bin/openssl x509 -in "$pem" -outform der | shasum -a 1)"
key_ok="$(/usr/bin/openssl pkcs12 -in "$p12" -nocerts -nodes -passin fd:3 3< <(printf '%s\n' "$PASSPHRASE") 2>/dev/null | grep -c 'PRIVATE KEY-----' || true)"
if [ "$p12_cert" = "$pem_cert" ] && [ "$key_ok" -ge 1 ]; then ok "the certificate backup decrypts to the published certificate and its key"; else fail "p12 backup does not match"; fi

seed="$(/usr/bin/openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 600000 -a -in "$ed_backup" -pass fd:3 3< <(printf '%s\n' "$PASSPHRASE"))"
cat > "$scratch/public-from-seed.swift" <<'SWIFT'
import CryptoKit
import Foundation
let seed = Data(base64Encoded: readLine()!)!
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
SWIFT
derived="$(printf '%s\n' "$seed" | xcrun swift "$scratch/public-from-seed.swift")"
if [ "${#seed}" -eq 44 ] && [ "$derived" = "$(cat "$ed_public")" ]; then ok "the update-key backup decrypts to the published public key's seed"; else fail "ed25519 backup does not match"; fi

if [ "$(cat "$scratch/gh/CONDUIT_RELEASE_P12_PASSWORD")" = "$PASSPHRASE" ] \
    && [ "$(cat "$scratch/gh/SPARKLE_ED_PRIVATE_KEY")" = "$seed" ] \
    && [ "$(base64 --decode < "$scratch/gh/CONDUIT_RELEASE_P12_BASE64" | shasum -a 1)" = "$(shasum -a 1 < "$p12")" ]; then
    ok "the three secrets reach gh on stdin, matching the backups"
else
    fail "uploaded secrets do not match the backups"
fi
if grep -q -- "--env release" "$log" && grep -q "type=tag" "$log"; then ok "secrets go to the tag-only release environment"; else fail "release environment not configured: $(grep 'ARGV gh' "$log")"; fi
if python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["target"]=="tag" and r["conditions"]["ref_name"]["include"]==["refs/tags/v*"] and {"creation","update","deletion"} <= {x["type"] for x in r["rules"]}' "$scratch/gh/ruleset.json"; then
    ok "only admins may create, move or delete v* tags"
else
    fail "tag ruleset: $(cat "$scratch/gh/ruleset.json" 2>/dev/null)"
fi

if grep -qF "$PASSPHRASE" "$log" || grep -qF "$seed" "$log"; then fail "a secret appeared on an argv"; else ok "no secret on any argv"; fi
if [ -z "$(ls -A "$scratch/tmp")" ]; then ok "nothing left in TMPDIR"; else fail "left behind: $(ls -A "$scratch/tmp")"; fi

rc=0; run "$PASSPHRASE"$'\n'"$PASSPHRASE"$'\n' --backup-dir "$scratch/backup2" || rc=$?
if [ "$rc" -ne 0 ] && grep -q "already exists" "$scratch/out.log"; then ok "a second run refuses to replace the identity"; else fail "second run (exit $rc)"; fi

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
