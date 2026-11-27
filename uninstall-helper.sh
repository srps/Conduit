#!/bin/zsh
set -euo pipefail

BUNDLE_ID="io.github.srps.Conduit"
SERVICE="system/$BUNDLE_ID.Helper"
PLIST_DST="/Library/LaunchDaemons/$BUNDLE_ID.Helper.plist"
HELPER_DST="/Library/PrivilegedHelperTools/$BUNDLE_ID.Helper"
SOCKET_PATH="/var/run/$BUNDLE_ID.Helper.sock"
# launchctl's exit status for a service it has no record of.
LAUNCHCTL_NO_SUCH_SERVICE=113

usage() {
    echo "Usage: sudo ./uninstall-helper.sh [--force]"
}

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg"; usage; exit 1 ;;
    esac
done

# One scutil session over the network preferences. They hold every location
# (set) and its services, where `networksetup` sees only the current location.
# scutil exits 0 whatever it could read, so each reader below fails on a
# "No such key" answer and on output it does not recognise.
prefs() { printf '%s\n' "$@" quit | scutil --prefs; }

# The paths under a key, one per line; none for a key with no children. Every
# line must be a path, so a diagnostic fails it.
paths() {
    local out
    out="$(prefs "list $1")" || return 1
    [ "$out" = "  no paths." ] && return 0
    print -r -- "$out" | awk '
        $0 !~ /^  path \[[0-9]+\] = \/[^ ]*$/ { exit 1 }
        { print $NF }'
}

# Whether d.show printed one dictionary and nothing else: its header, then
# only "key : value" entries indented two spaces per level, "<array> {" and
# "<dictionary> {" values that open a level, and the brace that closes each.
# Any other line, an indented diagnostic included, fails it.
one_dictionary() {
    print -r -- "$1" | awk '
        NR == 1 { bad = $0 != "<dictionary> {"; depth = 1; next }
        bad || depth == 0 { bad = 1; exit }
        {
            indent = 2 * depth
            if ($0 == sprintf("%" (indent - 2) "s}", "")) { depth--; next }
            entry = substr($0, indent + 1)
            if (substr($0, 1, indent) != sprintf("%" indent "s", "") || entry !~ /^[^ ].* : /) { bad = 1; exit }
            if (entry ~ / : <(array|dictionary)> \{$/) depth++
        }
        END { exit bad || depth != 0 }'
}

# A key's dictionary, as d.show prints it.
dictionary() {
    local out
    out="$(prefs "get $1" d.show)" || return 1
    one_dictionary "$out" || return 1
    print -r -- "$out"
}

name_of() {
    local out
    out="$(dictionary "$1")" || return 1
    print -r -- "$out" | sed -n 's/^  UserDefinedName : //p'
}

# A service's DNS servers, one per line. A service with no DNS key has none of
# its own; one that cannot be read at all is a failure, and so is a
# ServerAddresses that is not an array of addresses.
dns_servers() {
    local out
    dictionary "/NetworkServices/$1" >/dev/null || return 1
    out="$(prefs "get /NetworkServices/$1/DNS" d.show)" || return 1
    [ "$out" = $'  No such key\n<dictionary> {\n}' ] && return 0
    one_dictionary "$out" || return 1
    print -r -- "$out" | awk '
        /^  ServerAddresses : / { if ($0 != "  ServerAddresses : <array> {") exit 1; inside = 1; next }
        inside && $0 == "  }" { inside = 0; next }
        inside { if ($0 !~ /^    [0-9]+ : [^ ]+$/) exit 1; sub(/^    [0-9]+ : /, ""); print }
        END { if (inside) exit 1 }'
}

# Each service whose DNS servers are Conduit's resolver alone, as
# "location: service". The helper's relay on 127.0.0.1:53 answers them.
# Fails when any part of the settings cannot be read.
conduit_dns_services() {
    local locations location services link service servers location_name service_name
    locations="$(paths /Sets)" || return 1
    [ -n "$locations" ] || return 1
    for location in ${(f)locations}; do
        services="$(paths "$location/Network/Service")" || return 1
        for link in ${(f)services}; do
            service="${link:t}"
            servers="$(dns_servers "$service")" || return 1
            [ "$servers" = "127.0.0.1" ] || continue
            location_name="$(name_of "$location")" || return 1
            service_name="$(name_of "/NetworkServices/$service")" || return 1
            echo "$location_name: $service_name"
        done
    done
}

if ! remaining="$(conduit_dns_services)"; then
    if [ "$FORCE" -eq 0 ]; then
        echo "Could not read the network settings, so it is not known whether a service still uses Conduit's DNS resolver (127.0.0.1)."
        echo "Nothing was removed. To uninstall anyway: sudo ./uninstall-helper.sh --force"
        exit 1
    fi
    echo "Warning: could not read the network settings; a service may keep 127.0.0.1 as its DNS server after the helper is gone."
    remaining=""
fi
if [ -n "$remaining" ]; then
    if [ "$FORCE" -eq 0 ]; then
        echo "These network services still use Conduit's DNS resolver (127.0.0.1):"
        print -r -- "$remaining" | sed 's/^/  /'
        echo "The helper serves that resolver, so DNS would stop working without it."
        echo "In Conduit, use Restore DNS Settings or turn off Manage system DNS, then run this again."
        echo "Uninstall Helper in Conduit's Settings restores DNS before it removes the helper."
        echo "If you run your own DNS resolver on 127.0.0.1, uninstall anyway: sudo ./uninstall-helper.sh --force"
        exit 1
    fi
    echo "Warning: these services keep 127.0.0.1 as their DNS server after the helper is gone:"
    print -r -- "$remaining" | sed 's/^/  /'
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    usage
    exit 1
fi

echo "Uninstalling privileged helper..."

# A bootout that fails because launchd has no such job is expected. Any other
# failure stops here, before anything is deleted: the job may still be loaded.
if ! launchctl bootout "$SERVICE" 2>/dev/null; then
    print_status=0
    launchctl print "$SERVICE" >/dev/null 2>&1 || print_status=$?
    if [ "$print_status" -eq 0 ]; then
        echo "launchctl bootout failed and the helper is still loaded, so nothing was removed."
        echo "Check it with: sudo launchctl print $SERVICE"
        exit 1
    elif [ "$print_status" -ne "$LAUNCHCTL_NO_SUCH_SERVICE" ]; then
        echo "launchctl bootout failed and launchctl print could not say whether the helper is loaded (exit $print_status), so nothing was removed."
        echo "Check it with: sudo launchctl print $SERVICE"
        exit 1
    fi
fi
rm -f "$HELPER_DST" "$PLIST_DST" "$SOCKET_PATH"
# The caller pin install-helper.sh wrote (HelperConstants.callerRequirementPath).
rm -f "/Library/Application Support/$BUNDLE_ID/helper-callers.req"
rmdir "/Library/Application Support/$BUNDLE_ID" 2>/dev/null || true
# Leftovers from the release that logged to a file (HelperConstants.legacy*).
# (N) = zsh null glob: no archives is not an error under set -e.
rm -f "/etc/newsyslog.d/$BUNDLE_ID.Helper.conf" \
      "/var/log/$BUNDLE_ID.Helper.log" \
      /var/log/io.github.srps.Conduit.Helper.log.*(N)

echo "Privileged helper uninstalled."
echo "Conduit will fall back to standard admin prompts."
