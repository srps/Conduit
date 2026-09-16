#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="io.github.srps.Conduit"
HELPER_DST="/Library/PrivilegedHelperTools/$BUNDLE_ID.Helper"
PLIST_DST="/Library/LaunchDaemons/$BUNDLE_ID.Helper.plist"
SOCKET_PATH="/var/run/$BUNDLE_ID.Helper.sock"

# Candidate helpers. `.build/debug` and `.build/release` are the symlinks
# SwiftPM maintains to the current products directory under either build
# system (the `<arch>-apple-macosx/<config>` directories are the old build
# system's only). This script runs as root and does not invoke SwiftPM.
typeset -A CANDIDATES
CANDIDATES[installed]="/Applications/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
CANDIDATES[local]="$SCRIPT_DIR/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
CANDIDATES[release]="$SCRIPT_DIR/.build/release/ConduitHelper"
CANDIDATES[debug]="$SCRIPT_DIR/.build/debug/ConduitHelper"

SOURCE=""
for arg in "$@"; do
    case "$arg" in
        --source=*) SOURCE="${arg#--source=}" ;;
        --source) ;;  # value follows
        installed|local|release|debug) SOURCE="$arg" ;;
        *) echo "Unknown argument: $arg"; echo "Usage: sudo ./install-helper.sh [--source installed|local|release|debug]"; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    echo "Usage: sudo ./install-helper.sh [--source installed|local|release|debug]"
    exit 1
fi

# Build products first: a helper-only change is built, not bundled or
# installed, and the reinstall must pick that build up. Between the two
# products the newer wins, which is reliable because both are written by
# the compiler. App bundles come after: copying a bundle refreshes its
# helper's timestamp without changing its code, so a bundle's mtime says
# nothing about freshness. `--source installed|local` selects a bundle
# explicitly.
HELPER_SRC=""
for name in installed local release debug; do
    candidate="${CANDIDATES[$name]}"
    [ -f "$candidate" ] && echo "  candidate $name: $(date -r "$(stat -f %m "$candidate")" '+%Y-%m-%d %H:%M:%S')  $candidate"
done
if [ -n "$SOURCE" ]; then
    HELPER_SRC="${CANDIDATES[$SOURCE]:-}"
    if [ -z "$HELPER_SRC" ] || [ ! -f "$HELPER_SRC" ]; then
        echo "No helper at the requested source '$SOURCE': ${CANDIDATES[$SOURCE]:-unknown}"
        exit 1
    fi
else
    NEWEST=0
    for name in release debug; do
        candidate="${CANDIDATES[$name]}"
        [ -f "$candidate" ] || continue
        mtime=$(stat -f %m "$candidate")
        if [ "$mtime" -gt "$NEWEST" ]; then
            NEWEST=$mtime
            HELPER_SRC="$candidate"
        fi
    done
    if [ -z "$HELPER_SRC" ]; then
        for name in local installed; do
            candidate="${CANDIDATES[$name]}"
            if [ -f "$candidate" ]; then HELPER_SRC="$candidate"; break; fi
        done
    fi
fi

if [ -z "$HELPER_SRC" ]; then
    echo "Helper binary not found. Searched:"
    for name in installed local release debug; do echo "  ${CANDIDATES[$name]}"; done
    echo ""
    echo "Run 'swift build' or './bundle-app.sh' first."
    exit 1
fi

echo "Installing privileged helper..."
echo "Source: $HELPER_SRC"

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
rm -f "$SOCKET_PATH"

mkdir -p /Library/PrivilegedHelperTools
cp "$HELPER_SRC" "$HELPER_DST"
chown root:wheel "$HELPER_DST"
chmod 755 "$HELPER_DST"

cat > "$PLIST_DST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.srps.Conduit.Helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/io.github.srps.Conduit.Helper</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

# The helper logs to the unified log (subsystem $BUNDLE_ID). One release
# rotated a /var/log file via newsyslog(8); drop that rule if it is still here.
# Mirrors HelperConstants.legacyNewsyslogConfPath.
rm -f "/etc/newsyslog.d/$BUNDLE_ID.Helper.conf"

launchctl bootstrap system "$PLIST_DST"

echo ""
echo "Privileged helper installed successfully."
echo "  Binary: $HELPER_DST"
echo "  Plist:  $PLIST_DST"
echo "  Socket: $SOCKET_PATH"
echo "  Log:    /usr/bin/log show --predicate 'subsystem == \"$BUNDLE_ID\"' --info --last 1d"
echo ""
echo "Conduit will use the helper automatically."
echo "No more repeated admin password prompts."
