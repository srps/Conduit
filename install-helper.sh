#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="io.github.srps.Conduit"
HELPER_DST="/Library/PrivilegedHelperTools/$BUNDLE_ID.Helper"
PLIST_DST="/Library/LaunchDaemons/$BUNDLE_ID.Helper.plist"
SOCKET_PATH="/var/run/$BUNDLE_ID.Helper.sock"
# The caller pin (#46). Mirrors HelperConstants.callerRequirementPath.
CALLER_DIR="/Library/Application Support/$BUNDLE_ID"
CALLER_REQ="$CALLER_DIR/helper-callers.req"
# The app the pin is derived from: the one that calls the helper.
PIN_APP="/Applications/Conduit.app"

# Candidate helpers. `.build/debug` and `.build/release` are the symlinks
# SwiftPM maintains to the current products directory under either build
# system (the `<arch>-apple-macosx/<config>` directories are the old build
# system's only). This script runs as root and does not invoke SwiftPM.
typeset -A CANDIDATES
CANDIDATES[installed]="/Applications/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
CANDIDATES[local]="$SCRIPT_DIR/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
CANDIDATES[release]="$SCRIPT_DIR/.build/release/ConduitHelper"
CANDIDATES[debug]="$SCRIPT_DIR/.build/debug/ConduitHelper"

usage() {
    echo "Usage: sudo ./install-helper.sh [--source installed|local|release|debug]"
    echo "       ./install-helper.sh --print-caller-requirement <signed app or binary>"
}

# The helper's callers, as a code-signing requirement: the leaf certificate
# that signed <path>, and the identifiers of the programs that call the
# helper — the app, and ConduitDaemon when it is signed with
# `--identifier $BUNDLE_ID.Daemon`. pm-proxy and pmctl never call it.
# Pinning the certificate rather than a code hash is what lets an app update
# signed by the same identity keep working without reinstalling the helper.
#
# Sets CALLER_REQUIREMENT, or CALLER_REQUIREMENT_ERROR and returns 1 for
# code that is unsigned, ad-hoc or broken: such code has no certificate to
# pin, and pinning its hash would break on the next build.
derive_caller_requirement() {
    local target="$1" certs leaf flags
    CALLER_REQUIREMENT=""
    CALLER_REQUIREMENT_ERROR=""
    if [ ! -e "$target" ]; then
        CALLER_REQUIREMENT_ERROR="$target does not exist"
        return 1
    fi
    if ! codesign --verify --strict "$target" 2>/dev/null; then
        CALLER_REQUIREMENT_ERROR="$target has no valid code signature"
        return 1
    fi
    flags="$(codesign -dv "$target" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
    if [[ "$flags" == *adhoc* ]]; then
        CALLER_REQUIREMENT_ERROR="$target is signed ad-hoc, so there is no certificate to pin (run scripts/create-signing-identity.sh, then ./bundle-app.sh)"
        return 1
    fi
    certs="$(mktemp -d "${TMPDIR:-/tmp}/conduit-pin.XXXXXX")"
    codesign -d --extract-certificates="$certs/cert" "$target" >/dev/null 2>&1 || true
    if [ ! -s "$certs/cert0" ]; then
        rm -rf "$certs"
        CALLER_REQUIREMENT_ERROR="no certificate could be extracted from $target"
        return 1
    fi
    leaf="$(shasum -a 1 "$certs/cert0" | awk '{ print $1 }')"
    rm -rf "$certs"
    CALLER_REQUIREMENT="certificate leaf = H\"$leaf\" and (identifier \"$BUNDLE_ID\" or identifier \"$BUNDLE_ID.Daemon\")"
    if [[ "$flags" != *runtime* ]]; then
        # Not a reason to withhold the pin, only a warning: the helper will
        # refuse this build until it is re-signed with the hardened runtime.
        echo "warning: $target is not signed with the hardened runtime; the helper will refuse it until ./bundle-app.sh re-signs it" >&2
    fi
    return 0
}

# Arguments are checked before the root check so a typo fails without sudo.
SOURCE=""
PRINT_REQUIREMENT_FOR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --print-caller-requirement)
            if [ $# -lt 2 ]; then
                echo "--print-caller-requirement needs a path"
                usage
                exit 1
            fi
            PRINT_REQUIREMENT_FOR="$2"
            shift 2
            continue
            ;;
        --source=*) value="${1#--source=}" ;;
        --source)
            if [ $# -lt 2 ]; then
                echo "--source needs a value: installed, local, release or debug"
                usage
                exit 1
            fi
            shift
            value="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
    case "$value" in
        installed|local|release|debug) ;;
        *) echo "Unknown --source '$value': expected installed, local, release or debug"; usage; exit 1 ;;
    esac
    if [ -n "$SOURCE" ]; then
        echo "--source given twice"
        usage
        exit 1
    fi
    SOURCE="$value"
    shift
done

# Read-only preview of the pin, no root needed: what would be written for
# this app. Exit 2 when there is nothing to pin.
if [ -n "$PRINT_REQUIREMENT_FOR" ]; then
    if derive_caller_requirement "$PRINT_REQUIREMENT_FOR"; then
        echo "$CALLER_REQUIREMENT"
        exit 0
    fi
    echo "$CALLER_REQUIREMENT_ERROR" >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    usage
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

# Decide the caller pin before anything is torn down, so a broken app
# signature stops the install with the old helper still running.
PIN_ACTION="none"
if [ -d "$PIN_APP" ]; then
    if derive_caller_requirement "$PIN_APP"; then
        if ! codesign --verify -R "=$CALLER_REQUIREMENT" "$PIN_APP" 2>/dev/null; then
            echo "The derived caller requirement does not accept $PIN_APP itself; refusing to install a pin that would lock it out:"
            echo "  $CALLER_REQUIREMENT"
            exit 1
        fi
        PIN_ACTION="write"
    else
        PIN_ACTION="remove"
    fi
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

# The pin is read once when the helper starts, so it is written before the
# bootstrap below. Root-owned and writable only by root, down to its
# directory: the helper refuses every caller if either is not.
case "$PIN_ACTION" in
    write)
        [ -L "$CALLER_DIR" ] && rm -f "$CALLER_DIR"
        mkdir -p "$CALLER_DIR"
        chown root:wheel "$CALLER_DIR"
        chmod 755 "$CALLER_DIR"
        pin_tmp="$(mktemp "$CALLER_DIR/.helper-callers.XXXXXX")"
        printf '%s\n' "$CALLER_REQUIREMENT" > "$pin_tmp"
        chown root:wheel "$pin_tmp"
        chmod 644 "$pin_tmp"
        mv -f "$pin_tmp" "$CALLER_REQ"
        CALLER_STATUS="ENFORCED: only programs signed like $PIN_APP ($CALLER_REQ)"
        ;;
    remove)
        rm -f "$CALLER_REQ"
        CALLER_STATUS="UNENFORCED: $CALLER_REQUIREMENT_ERROR"
        echo ""
        echo "WARNING: $CALLER_REQUIREMENT_ERROR."
        echo "WARNING: Caller identity is NOT enforced: any process running as the console user may use the helper."
        ;;
    none)
        CALLER_STATUS="unchanged: no app at $PIN_APP to derive a pin from"
        if [ -f "$CALLER_REQ" ]; then
            CALLER_STATUS="$CALLER_STATUS; the existing pin in $CALLER_REQ stays"
        fi
        echo ""
        echo "Note: no app at $PIN_APP, so the caller pin was left as it was."
        ;;
esac

launchctl bootstrap system "$PLIST_DST"

echo ""
echo "Privileged helper installed successfully."
echo "  Binary: $HELPER_DST"
echo "  Plist:  $PLIST_DST"
echo "  Socket: $SOCKET_PATH"
echo "  Callers: $CALLER_STATUS"
echo "  Log:    /usr/bin/log show --predicate 'subsystem == \"$BUNDLE_ID\"' --info --last 1d"
echo ""
echo "Conduit will use the helper automatically."
echo "No more repeated admin password prompts."
