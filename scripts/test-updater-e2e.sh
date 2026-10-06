#!/bin/zsh
# End-to-end Sparkle update through the nested updater, with a stand-in host:
# a tiny app (its own bundle identifier, never Conduit's) at 1.0.0 with the
# debug ConduitUpdater nested where bundle-app.sh puts it, a feed on
# 127.0.0.1 offering an EdDSA-signed 2.0.0, and a throwaway key. Passes when
# Sparkle quits the running host with a normal quit event, replaces the
# bundle, and relaunches 2.0.0; and when an archive signed with another key
# is refused and leaves 1.0.0 in place.
#
# --signed signs both versions the way a release is signed: a throwaway
# self-signed certificate in a temporary keychain (added to the user search
# list for the run, then removed), the hardened runtime everywhere, and the
# library-validation entitlement on the updater only.
#
# Needs a window server (run it from Terminal, or `open` a shell): the host
# and the updater are launched with `open`. Touches only a scratch directory
# and the stand-in's own defaults domain, which it deletes.
#
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/test-updater-e2e.sh [--signed]
set -euo pipefail

# Name the failing line: under set -e a failed step otherwise ends the run
# with no output at all.
trap 'echo "FAIL  stopped at line $LINENO (exit $?)" >&2' ZERR

SIGNED=false
[ "${1:-}" = "--signed" ] && SIGNED=true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HOST_ID="io.github.srps.Conduit.E2EHost"
TIMEOUT=90

cd "$ROOT_DIR"
xcrun swift build --product ConduitUpdater >/dev/null
BIN="$(xcrun swift build --show-bin-path)"
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -path '*Sparkle/bin/sign_update' -type f -print -quit)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found under .build/artifacts"; exit 1; }

# Canonical (/private/var/…, no "//" from a TMPDIR ending in "/"), so the
# pkill/pgrep patterns below match the stand-ins' real paths.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/updater-e2e.XXXXXX")" && pwd -P)"
SERVER_PID=""
KEYCHAIN=""
ORIGINAL_KEYCHAINS=()
cleanup() {
    # Sparkle's relaunch of the new version can land after the checks, so
    # stop the stand-ins until none is left.
    local attempt
    for attempt in 1 2 3 4 5; do
        pkill -f "$WORK/" 2>/dev/null || true
        sleep 1
    done
    if [ -n "$KEYCHAIN" ]; then
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    defaults delete "$HOST_ID" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# The feed server starts first: a cold Python on a CI runner has taken over
# 30 s to answer, and starting it now overlaps that with the builds below.
# Its output is kept, as the only clue if it never comes up.
mkdir -p "$WORK/feed"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
FEED="http://127.0.0.1:$PORT/appcast.xml"
( cd "$WORK/feed" && exec python3 -u -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/server.log" 2>&1 ) &
SERVER_PID=$!

failures=0
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

# The stand-in host: logs launches and quits to host.log beside its bundle
# (Sparkle relaunches it without arguments), otherwise idles.
mkdir -p "$WORK/src"
cat > "$WORK/src/main.swift" <<'SWIFT'
import AppKit
let log = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("host.log")
func note(_ line: String) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let text = "\(line) \(version) \(ProcessInfo.processInfo.processIdentifier)\n"
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: log) else { return }
    handle.seekToEndOfFile(); handle.write(Data(text.utf8)); handle.closeFile()
}
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { note("launched") }
    func applicationWillTerminate(_ n: Notification) { note("terminated") }
}
let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
SWIFT
xcrun swiftc -O -o "$WORK/src/E2EHost" "$WORK/src/main.swift"
HOST_LOG="$WORK/installed/host.log"

KEYS="$(xcrun swift "$ROOT_DIR/scripts/ed25519-keygen.swift")"
ED_PRIVATE="${KEYS%%$'\n'*}"
ED_PUBLIC="${KEYS#*$'\n'}"
OTHER_KEYS="$(xcrun swift "$ROOT_DIR/scripts/ed25519-keygen.swift")"
OTHER_PRIVATE="${OTHER_KEYS%%$'\n'*}"

IDENTITY="-"
if $SIGNED; then
    KEYCHAIN="$WORK/e2e.keychain-db"
    keychain_password="$(openssl rand -hex 16)"
    ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//;s/"$//')}")
    security create-keychain -p "$keychain_password" "$KEYCHAIN"
    security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Conduit E2E Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$WORK/cert.cnf"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$WORK/cert.cnf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -name "Conduit E2E Signing" -in "$WORK/cert.pem" -inkey "$WORK/key.pem" \
        -passout pass:e2e -out "$WORK/identity.p12"
    rm -f "$WORK/key.pem"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P e2e -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
    IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/Conduit E2E Signing/ { print $2; exit }')"
    echo "Signing with a throwaway certificate ($IDENTITY) and the hardened runtime"
fi


make_host() { # <dir> <version>
    local app="$1/E2EHost.app" version="$2"
    local updater="$app/Contents/Helpers/Conduit Updater.app"
    mkdir -p "$app/Contents/MacOS" "$updater/Contents/MacOS" "$updater/Contents/Frameworks"
    cp "$WORK/src/E2EHost" "$app/Contents/MacOS/E2EHost"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>E2EHost</string>
<key>CFBundleIdentifier</key><string>$HOST_ID</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>SUFeedURL</key><string>$FEED</string>
<key>SUPublicEDKey</key><string>$ED_PUBLIC</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict></plist>
PLIST
    cp "$BIN/ConduitUpdater" "$updater/Contents/MacOS/Conduit Updater"
    ditto "$BIN/Sparkle.framework" "$updater/Contents/Frameworks/Sparkle.framework"
    rm -rf "$updater/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
    cat > "$updater/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Conduit Updater</string>
<key>CFBundleIdentifier</key><string>io.github.srps.Conduit.Updater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
    if $SIGNED; then
        local sparkle="$updater/Contents/Frameworks/Sparkle.framework" options=(--force --timestamp=none --options runtime --sign "$IDENTITY")
        codesign "${options[@]}" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" 2>/dev/null
        codesign "${options[@]}" --identifier io.github.srps.Conduit.Updater \
            --entitlements "$ROOT_DIR/Resources/ConduitUpdater.entitlements" "$updater" 2>/dev/null
        codesign "${options[@]}" "$app" 2>/dev/null
    else
        codesign --force --deep --sign - "$app" 2>/dev/null
    fi
    codesign --verify --strict --deep "$app"
}

make_feed() { # <archive> <signature> <length>
    cat > "$WORK/feed/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>E2E</title>
<item>
  <title>2.0.0</title>
  <sparkle:version>2.0.0</sparkle:version>
  <sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
  <enclosure url="http://127.0.0.1:$PORT/$1" length="$3" type="application/octet-stream" sparkle:edSignature="$2"/>
</item>
</channel></rss>
XML
}

installed_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/installed/E2EHost.app/Contents/Info.plist"
}

host_gone() {
    ! pgrep -f "$WORK/installed/E2EHost.app/Contents/MacOS" >/dev/null
}

updater_gone() {
    ! pgrep -f "$WORK/installed/E2EHost.app/Contents/Helpers" >/dev/null
}

wait_for() { # <seconds> <command...>
    local deadline=$((SECONDS + $1))
    shift
    while [ $SECONDS -lt $deadline ]; do
        "$@" && return 0
        sleep 0.5
    done
    return 1
}

mkdir -p "$WORK/installed" "$WORK/v2" "$WORK/feed"
make_host "$WORK/installed" 1.0.0
make_host "$WORK/v2" 2.0.0
( cd "$WORK/v2" && ditto -c -k --sequesterRsrc --keepParent E2EHost.app "$WORK/feed/E2EHost-2.0.0.zip" )
LENGTH="$(stat -f %z "$WORK/feed/E2EHost-2.0.0.zip")"
if ! wait_for 120 curl -s --noproxy '*' "http://127.0.0.1:$PORT/" -o /dev/null; then
    echo "FAIL  the local feed on 127.0.0.1:$PORT did not answer within 120 s" >&2
    echo "      python3: $(command -v python3) ($(python3 --version 2>&1)); server log:" >&2
    sed 's/^/      /' "$WORK/server.log" >&2
    curl -sv --noproxy '*' "http://127.0.0.1:$PORT/" -o /dev/null 2>&1 | sed 's/^/      curl: /' >&2 || true
    exit 1
fi

run_update() { # [concurrent updater launches, default 1]
    rm -f "$HOST_LOG"
    open -n "$WORK/installed/E2EHost.app"
    wait_for 15 grep -qs "^launched 1.0.0" "$HOST_LOG" || { fail "the 1.0.0 host did not start"; return 1; }
    local i launches=()
    for i in $(seq 1 "${1:-1}"); do
        open -n "$WORK/installed/E2EHost.app/Contents/Helpers/Conduit Updater.app" --args --check --test-auto-install &
        launches+=($!)
    done
    # Only these: a bare `wait` would also wait for the feed server.
    wait "${launches[@]}"
}

# 1. An archive signed with another key is refused; 1.0.0 stays.
BAD_SIGNATURE="$(print -rn -- "$OTHER_PRIVATE" | "$SIGN_UPDATE" --ed-key-file - -p "$WORK/feed/E2EHost-2.0.0.zip")"
make_feed E2EHost-2.0.0.zip "$BAD_SIGNATURE" "$LENGTH"
run_update
if wait_for 30 updater_gone; then
    if [ "$(installed_version)" = 1.0.0 ] && ! grep -qs "^terminated 1.0.0" "$HOST_LOG"; then
        ok "an archive signed with another key is refused and the running host is left alone"
    else
        fail "a wrongly signed archive changed the host: $(installed_version); $(cat "$HOST_LOG")"
    fi
else
    fail "the updater did not exit after refusing the archive"
fi
pkill -f "$WORK/installed/E2EHost.app/Contents/MacOS" || true
wait_for 10 host_gone || { echo "FAIL  the 1.0.0 host did not exit after the first case" >&2; exit 1; }

# 2. A correctly signed archive installs: quit, replace, relaunch. Three
# updaters start at once; their lock must leave exactly one installing.
GOOD_SIGNATURE="$(print -rn -- "$ED_PRIVATE" | "$SIGN_UPDATE" --ed-key-file - -p "$WORK/feed/E2EHost-2.0.0.zip")"
make_feed E2EHost-2.0.0.zip "$GOOD_SIGNATURE" "$LENGTH"
run_update 3
if wait_for "$TIMEOUT" grep -qs "^launched 2.0.0" "$HOST_LOG"; then
    ok "the signed update was installed and 2.0.0 relaunched"
else
    fail "no 2.0.0 relaunch within ${TIMEOUT}s; host log: $(tr '\n' ';' < "$HOST_LOG"); installed $(installed_version)"
fi
host_pid="$(awk '/^launched 1.0.0/ { print $3; exit }' "$HOST_LOG" 2>/dev/null)"
if [ -n "$host_pid" ] && grep -qs "^terminated 1.0.0 $host_pid\$" "$HOST_LOG"; then
    ok "the running 1.0.0 host quit through its normal termination path"
else
    fail "the 1.0.0 host never ran applicationWillTerminate"
fi
[ "$(installed_version)" = 2.0.0 ] && ok "the bundle on disk is 2.0.0" || fail "installed version is $(installed_version)"
if wait_for 30 updater_gone; then
    ok "all three updaters exited after the install"
else
    fail "an updater is still running after the install"
fi
sleep 2
launches="$(grep -c "^launched 2.0.0" "$HOST_LOG" || true)"
if [ "$launches" = 1 ]; then
    ok "three concurrent updaters installed and relaunched once"
else
    fail "concurrent updaters: $(tr '\n' ';' < "$HOST_LOG")"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
