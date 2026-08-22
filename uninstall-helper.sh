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
# Leftovers from the release that logged to a file (HelperConstants.legacy*).
# (N) = zsh null glob: no archives is not an error under set -e.
rm -f "/etc/newsyslog.d/io.github.srps.Conduit.Helper.conf" \
      /var/log/io.github.srps.Conduit.Helper.log \
      /var/log/io.github.srps.Conduit.Helper.log.*(N)

echo "Privileged helper uninstalled."
echo "Conduit will fall back to standard admin prompts."
