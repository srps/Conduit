#!/bin/zsh
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/io.github.srps.Conduit.Helper.plist"
HELPER_DST="/Library/PrivilegedHelperTools/io.github.srps.Conduit.Helper"
SOCKET_PATH="/var/run/io.github.srps.Conduit.Helper.sock"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    echo "Usage: sudo ./uninstall-helper.sh"
    exit 1
fi

echo "Uninstalling privileged helper..."

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
rm -f "$HELPER_DST" "$PLIST_DST" "$SOCKET_PATH"

echo "Privileged helper uninstalled."
echo "Conduit will fall back to standard admin prompts."
