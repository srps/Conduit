#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="io.github.srps.Conduit"
HELPER_DST="/Library/PrivilegedHelperTools/$BUNDLE_ID.Helper"
PLIST_DST="/Library/LaunchDaemons/$BUNDLE_ID.Helper.plist"
SOCKET_PATH="/var/run/$BUNDLE_ID.Helper.sock"

INSTALLED_APP="/Applications/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
LOCAL_APP="$SCRIPT_DIR/Conduit.app/Contents/Library/LaunchServices/$BUNDLE_ID.Helper"
BUILD_DIR_DEBUG="$SCRIPT_DIR/.build/$(uname -m)-apple-macosx/debug"
BUILD_DIR_RELEASE="$SCRIPT_DIR/.build/$(uname -m)-apple-macosx/release"
BUILD_BIN_DEBUG="$BUILD_DIR_DEBUG/ConduitHelper"
BUILD_BIN_RELEASE="$BUILD_DIR_RELEASE/ConduitHelper"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    echo "Usage: sudo ./install-helper.sh"
    exit 1
fi

if [ -f "$INSTALLED_APP" ]; then
    HELPER_SRC="$INSTALLED_APP"
elif [ -f "$LOCAL_APP" ]; then
    HELPER_SRC="$LOCAL_APP"
elif [ -f "$BUILD_BIN_RELEASE" ]; then
    HELPER_SRC="$BUILD_BIN_RELEASE"
elif [ -f "$BUILD_BIN_DEBUG" ]; then
    HELPER_SRC="$BUILD_BIN_DEBUG"
else
    echo "Helper binary not found. Searched:"
    echo "  $INSTALLED_APP"
    echo "  $LOCAL_APP"
    echo "  $BUILD_BIN_RELEASE"
    echo "  $BUILD_BIN_DEBUG"
    echo ""
    echo "Run './bundle-app.sh --install' first."
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
    <key>StandardErrorPath</key>
    <string>/var/log/io.github.srps.Conduit.Helper.log</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

launchctl bootstrap system "$PLIST_DST"

echo ""
echo "Privileged helper installed successfully."
echo "  Binary: $HELPER_DST"
echo "  Plist:  $PLIST_DST"
echo "  Socket: $SOCKET_PATH"
echo ""
echo "Conduit will use the helper automatically."
echo "No more repeated admin password prompts."
