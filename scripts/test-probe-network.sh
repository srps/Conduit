#!/bin/bash
# Runs probe-network.sh against stubbed system tools, one network state per case, and checks the verdict and exit status.
set -euo pipefail

probe="$(cd "$(dirname "$0")" && pwd)/probe-network.sh"
stubs="$(mktemp -d "${TMPDIR:-/tmp}/probe-stubs.XXXXXX")"
trap 'rm -rf "$stubs"' EXIT

stub() { printf '#!/bin/bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }
stub scutil 'case "$1" in --nwi) echo "Network interfaces: $FAKE_IFACES" ;; --dns) printf "%b" "$FAKE_DNS_CONFIG" ;; esac'
stub ipconfig 'case "$1:${3:-}" in getifaddr:) echo "$FAKE_IP" ;; getoption:router) echo "$FAKE_GW" ;; getoption:domain_name_server) echo "$FAKE_NETDNS" ;; esac'
stub route 'echo "  interface: $FAKE_DEFAULT_IF"'
stub ping 'exit "$FAKE_PING"'
stub curl '[ -n "$FAKE_HTTP" ] && printf "%s" "$FAKE_HTTP"; exit 0'
# FAKE_DIG lists the servers that answer, as server:port=STATUS separated by spaces; any other server times out.
stub dig 'server="" port=53
while [ $# -gt 0 ]; do case "$1" in @*) server="${1#@}" ;; -p) port="$2"; shift ;; -b) shift ;; esac; shift; done
for entry in $FAKE_DIG; do
    if [ "${entry%%=*}" = "$server:$port" ]; then echo ";; ->>HEADER<<- opcode: QUERY, status: ${entry#*=}, id: 1"; exit 0; fi
done
echo ";; connection timed out; no servers could be reached"; exit 9'

dns_config() { # <default server> [port] [vpn interface] [vpn server]
    local out="DNS configuration\n\nresolver #1\n  nameserver[0] : $1\n"
    [ -n "${2:-}" ] && out+="  port     : $2\n"
    out+="  reach    : 0x00000002 (Reachable)\n\n"
    [ -n "${3:-}" ] && out+="resolver #2\n  domain   : corp.example\n  nameserver[0] : $4\n  if_index : 20 ($3)\n\n"
    printf '%s' "$out"
}

failures=0
run_case() { # <label> <expected exit> <expected verdict substring> then env assignments
    local label="$1" want_rc="$2" want="$3"; shift 3
    local out rc=0
    out="$(env -i PATH="$stubs:/usr/bin:/bin" HOME="$stubs" FAKE_IFACES=en0 FAKE_IP=192.168.1.20 FAKE_GW=192.168.1.1 \
        FAKE_NETDNS=192.168.1.1 FAKE_DEFAULT_IF=en0 FAKE_PING=0 FAKE_HTTP=301 FAKE_DIG= FAKE_DNS_CONFIG= "$@" /bin/zsh "$probe" 2>&1)" || rc=$?
    local verdict; verdict="$(printf '%s\n' "$out" | grep '^Verdict:' || true)"
    if [ "$rc" -eq "$want_rc" ] && [[ "$verdict" == *"$want"* ]]; then
        echo "ok    $label"
    else
        echo "FAIL  $label (exit $rc, wanted $want_rc)"; printf '%s\n' "$out" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
}

all_answer="192.168.1.1:53=NOERROR 1.1.1.1:53=NOERROR"
run_case "a healthy network passes" 0 "Names resolve and the network passes traffic." \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a hotspot with no upstream is named as the network, not the Mac" 2 "This network is not passing traffic" \
    FAKE_PING=1 FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "the hotspot verdict holds while its gateway still answers ping" 2 "This network is not passing traffic" \
    FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's resolver with a silent forwarder names Conduit" 2 "Conduit's DNS forwarder is not answering" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's resolver with a silent relay but a live forwarder names the relay path" 2 "though the forwarder answers directly" \
    FAKE_DIG="$all_answer 127.0.0.1:5053=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "a SERVFAIL from Conduit is not an answer" 2 "Conduit's DNS forwarder is not answering" \
    FAKE_DIG="$all_answer 127.0.0.1:5053=SERVFAIL 127.0.0.1:53=SERVFAIL" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's DNS through the VPN override port passes" 0 "Names resolve" \
    FAKE_DIG="$all_answer 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353)"
run_case "a network whose own DNS is dead says so" 2 "its DNS server does not answer" \
    FAKE_DIG="1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a VPN whose DNS servers are silent names the tunnel" 2 "The VPN's DNS servers do not answer" \
    FAKE_IFACES="en0 utun6" FAKE_DEFAULT_IF=utun6 FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a healthy VPN passes" 0 "Names resolve" \
    FAKE_IFACES="en0 utun6" FAKE_DEFAULT_IF=utun6 FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "no address means no network" 2 "No network connection" \
    FAKE_IP= FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

out="$(/bin/zsh "$probe" --name 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 64 ] && [[ "$out" == *"--name needs a host"* ]]; then echo "ok    --name without a host is rejected"; else echo "FAIL  --name without a host (exit $rc): $out"; failures=$((failures + 1)); fi

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
