#!/bin/bash
# Runs uninstall-helper.sh unprivileged with scutil, id, launchctl, rm and
# rmdir replaced by stubs on PATH. The scutil stub serves a fixture network
# preferences file through the real scutil; the others only log, so nothing
# on this machine is read for DNS or removed.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/uninstall-helper.sh"
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo; it must never reach the uninstall steps."
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/bin"
mkdir -p "$stubs"
calls="$scratch/calls"

# STUB_SCUTIL_FAIL_ON: a command that makes the scutil session fail.
# STUB_SCUTIL_DIAGNOSE_ON: a command whose session prints a diagnostic and an
# empty dictionary, and still exits 0. STUB_SCUTIL_NOTE_ON: one whose session
# prints a diagnostic before its real output. STUB_SCUTIL_INSIDE_ON: one whose
# session prints an indented diagnostic inside an otherwise empty dictionary.
cat > "$stubs/scutil" <<'STUB'
#!/bin/bash
session="$(cat)"
if [ -n "${STUB_SCUTIL_FAIL_ON:-}" ] && [[ "$session" == *"$STUB_SCUTIL_FAIL_ON"* ]]; then exit 1; fi
if [ -n "${STUB_SCUTIL_DIAGNOSE_ON:-}" ] && [[ "$session" == *"$STUB_SCUTIL_DIAGNOSE_ON"* ]]; then
    printf '  Permission denied\n<dictionary> {\n}\n'
    exit 0
fi
if [ -n "${STUB_SCUTIL_INSIDE_ON:-}" ] && [[ "$session" == *"$STUB_SCUTIL_INSIDE_ON"* ]]; then
    printf '<dictionary> {\n  Permission denied\n}\n'
    exit 0
fi
if [ -n "${STUB_SCUTIL_NOTE_ON:-}" ] && [[ "$session" == *"$STUB_SCUTIL_NOTE_ON"* ]]; then echo "  Permission denied"; fi
printf '%s\n' "$session" | /usr/sbin/scutil --prefs "$STUB_PREFERENCES"
STUB
# STUB_ROOT=1 answers id -u as root.
cat > "$stubs/id" <<'STUB'
#!/bin/bash
if [ "${STUB_ROOT:-0}" = 1 ] && [ "$*" = "-u" ]; then echo 0; else exec /usr/bin/id "$@"; fi
STUB
# STUB_BOOTOUT and STUB_PRINT are the statuses of launchctl bootout and print.
cat > "$stubs/launchctl" <<'STUB'
#!/bin/bash
echo "launchctl $*" >> "$STUB_CALLS"
case "$1" in
    bootout) exit "${STUB_BOOTOUT:-0}" ;;
    print) exit "${STUB_PRINT:-0}" ;;
esac
exit 0
STUB
for name in rm rmdir; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_CALLS"\n' "$name" > "$stubs/$name"
done
chmod +x "$stubs"/*

# Two locations. <office-dns> and <home-dns> are the DNS server arrays, and
# [ethernet-dns] is Ethernet's whole DNS entry, so a fixture can leave it out.
preferences() { # <file> <office-dns> <home-dns> [ethernet-dns]
    local ethernet="${4-<key>DNS</key><dict><key>ServerAddresses</key><array><string>192.0.2.9</string></array></dict>}"
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NetworkServices</key><dict>
  <key>S1</key><dict><key>UserDefinedName</key><string>Wi-Fi</string>
    <key>DNS</key><dict><key>ServerAddresses</key><array>$2</array></dict></dict>
  <key>S2</key><dict><key>UserDefinedName</key><string>Ethernet</string>
    $ethernet</dict>
  <key>S3</key><dict><key>UserDefinedName</key><string>Wi-Fi</string>
    <key>DNS</key><dict><key>ServerAddresses</key><array>$3</array></dict></dict>
</dict>
<key>Sets</key><dict>
  <key>L1</key><dict><key>UserDefinedName</key><string>Office</string><key>Network</key><dict><key>Service</key><dict>
    <key>S1</key><dict><key>__LINK__</key><string>/NetworkServices/S1</string></dict>
    <key>S2</key><dict><key>__LINK__</key><string>/NetworkServices/S2</string></dict>
  </dict></dict></dict>
  <key>L2</key><dict><key>UserDefinedName</key><string>Home</string><key>Network</key><dict><key>Service</key><dict>
    <key>S3</key><dict><key>__LINK__</key><string>/NetworkServices/S3</string></dict>
  </dict></dict></dict>
</dict>
</dict></plist>
PLIST
}
loopback="<string>127.0.0.1</string>"
own="<string>192.0.2.1</string>"
preferences "$scratch/clean.plist" "$own" "$own"
preferences "$scratch/office.plist" "$loopback" "$own"
preferences "$scratch/home.plist" "$own" "$loopback"
preferences "$scratch/mixed.plist" "$loopback<string>192.0.2.1</string>" "$own"
preferences "$scratch/no-dns-key.plist" "$own" "$own" ""
preferences "$scratch/scalar.plist" "$own" "$own" "<key>DNS</key><dict><key>ServerAddresses</key>$loopback</dict>"

failures=0
# <label> <exit> <preferences> <expected substring> <unexpected substring> [VAR=value...] [-- args...]
expect() {
    local label="$1" want_rc="$2" prefs="$3" want="$4" unwanted="$5"
    shift 5
    local env=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do env+=("$1"); shift; done
    if [ "$#" -gt 0 ]; then shift; fi
    local out rc=0
    : > "$calls"
    out="$(env PATH="$stubs:/usr/bin:/bin:/usr/sbin" STUB_PREFERENCES="$prefs" STUB_CALLS="$calls" ${env[@]+"${env[@]}"} \
        zsh "$script" "$@" 2>&1)" || rc=$?
    out+=$'\n'"$(cat "$calls")"
    if [ "$rc" -eq "$want_rc" ] && [[ "$out" == *"$want"* ]] && { [ -z "$unwanted" ] || [[ "$out" != *"$unwanted"* ]]; }; then
        echo "ok    $label"
    else
        echo "FAIL  $label (exit $rc): $out"
        failures=$((failures + 1))
    fi
}

expect "an unknown argument is rejected"              1 "$scratch/clean.plist"  "Unknown argument: --now" "" -- --now
expect "clean settings reach the root check"           1 "$scratch/clean.plist"  "must be run with sudo" "127.0.0.1"
expect "a service on Conduit's resolver is refused"    1 "$scratch/office.plist" "Office: Wi-Fi" "must be run with sudo"
expect "the refusal says what to do first"             1 "$scratch/office.plist" "Restore DNS Settings" ""
expect "the refusal names --force for a resolver of your own" 1 "$scratch/office.plist" "own DNS resolver on 127.0.0.1" ""
expect "an inactive location's service is refused too" 1 "$scratch/home.plist"   "Home: Wi-Fi" "Office: Wi-Fi"
expect "a resolver beside another server is not Conduit's" 1 "$scratch/mixed.plist" "must be run with sudo" "Office: Wi-Fi"
expect "a service with no DNS key is not Conduit's"    1 "$scratch/no-dns-key.plist" "must be run with sudo" "Could not read"
expect "--force warns and reaches the root check"      1 "$scratch/office.plist" "must be run with sudo" "uninstall anyway" -- --force
expect "--force still names what stays"                1 "$scratch/office.plist" "Office: Wi-Fi" "" -- --force
expect "missing preferences are refused"               1 "$scratch/missing.plist" "Could not read the network settings" "must be run with sudo"
expect "a failed location listing is refused"          1 "$scratch/office.plist" "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_FAIL_ON="list /Sets"
expect "a failed read of a service's DNS is refused"   1 "$scratch/office.plist" "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_FAIL_ON="get /NetworkServices/S1/DNS"
expect "a diagnostic beside a service's DNS is refused" 1 "$scratch/office.plist" "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_DIAGNOSE_ON="get /NetworkServices/S1/DNS"
expect "a diagnostic beside a service is refused"      1 "$scratch/clean.plist"  "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_DIAGNOSE_ON="get /NetworkServices/S2"
expect "a diagnostic beside the location listing is refused" 1 "$scratch/office.plist" "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_NOTE_ON="list /Sets"
expect "an indented diagnostic inside a service's DNS is refused" 1 "$scratch/office.plist" "Could not read the network settings" \
    "must be run with sudo" STUB_SCUTIL_INSIDE_ON="get /NetworkServices/S1/DNS"
expect "a scalar ServerAddresses is refused"           1 "$scratch/scalar.plist" "Could not read the network settings" "must be run with sudo"
expect "a failed read of a service is refused"         1 "$scratch/clean.plist"  "Could not read the network settings" "must be run with sudo" \
    STUB_SCUTIL_FAIL_ON="get /NetworkServices/S3"
expect "--force goes on past a failed read"            1 "$scratch/clean.plist"  "must be run with sudo" "" \
    STUB_SCUTIL_FAIL_ON="list /Sets" -- --force
expect "a helper that boots out has its files removed" 0 "$scratch/clean.plist"  "rm -f /Library/PrivilegedHelperTools/" "nothing was removed" \
    STUB_ROOT=1 STUB_BOOTOUT=0
expect "a failed bootout of a job launchd does not know still removes the files" 0 "$scratch/clean.plist" \
    "rm -f /Library/PrivilegedHelperTools/" "nothing was removed" STUB_ROOT=1 STUB_BOOTOUT=5 STUB_PRINT=113
expect "a failed bootout of a loaded job removes nothing" 1 "$scratch/clean.plist" "still loaded, so nothing was removed" "rm -f" \
    STUB_ROOT=1 STUB_BOOTOUT=5 STUB_PRINT=0
expect "a failed bootout launchd cannot be asked about removes nothing" 1 "$scratch/clean.plist" "(exit 5), so nothing was removed" "rm -f" \
    STUB_ROOT=1 STUB_BOOTOUT=5 STUB_PRINT=5

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
