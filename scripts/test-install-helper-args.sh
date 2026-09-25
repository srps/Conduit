#!/bin/bash
# install-helper.sh checks its arguments before it checks for root, so this
# runs unprivileged: a rejected argument exits with its own message, an
# accepted one gets as far as the sudo refusal.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/install-helper.sh"
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo; it must never reach the install steps."
    exit 1
fi

failures=0
expect() { # <label> <expected output substring> [args...]
    local label="$1" want="$2"
    shift 2
    local out rc=0
    out="$("$script" "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"$want"* ]]; then
        echo "ok    $label"
    else
        echo "FAIL  $label (exit $rc): $out"
        failures=$((failures + 1))
    fi
}

expect "no arguments reach the root check"        "must be run with sudo"
expect "--source with a value reaches the root check" "must be run with sudo" --source release
expect "--source=value reaches the root check"     "must be run with sudo" --source=debug
expect "--source without a value is rejected"      "--source needs a value" --source
expect "an unknown source is rejected"             "Unknown --source 'foo'" --source foo
expect "an empty --source= is rejected"            "Unknown --source ''" --source=
expect "a bare word is rejected"                   "Unknown argument: release" release
expect "a second --source is rejected"             "--source given twice" --source release --source debug
expect "--print-caller-requirement needs a path"   "needs a path" --print-caller-requirement

# The caller pin (#46), derived without root. An Apple-signed binary stands
# in for a certificate-signed app: its leaf certificate is what gets pinned.
pin="$("$script" --print-caller-requirement /usr/bin/true 2>/dev/null)" || pin=""
leaf="$(sed -n 's/^certificate leaf = H"\([0-9a-f]\{40\}\)" and (identifier "io.github.srps.Conduit" or identifier "io.github.srps.Conduit.Daemon")$/\1/p' <<<"$pin")"
if [ -n "$leaf" ] && codesign --verify -R "=certificate leaf = H\"$leaf\"" /usr/bin/true 2>/dev/null; then
    echo "ok    a signed binary yields a pin its own leaf certificate satisfies"
else
    echo "FAIL  pin for /usr/bin/true: '$pin'"
    failures=$((failures + 1))
fi

# Ad-hoc code has no certificate: no pin, exit 2, and the reason says so.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/pin-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cp /usr/bin/true "$scratch/adhoc"
codesign --force --sign - "$scratch/adhoc" 2>/dev/null
rc=0
out="$("$script" --print-caller-requirement "$scratch/adhoc" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"signed ad-hoc"* ]]; then
    echo "ok    ad-hoc code yields no pin"
else
    echo "FAIL  ad-hoc code (exit $rc): $out"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
