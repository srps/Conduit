#!/bin/bash
# Runs probe-network.sh against stubbed system tools, one network state per case, and checks the verdict and exit status.
# The stubs follow the tools macOS ships: dig 9.10 (no -r, reads ~/.digrc) and curl 8 (reads ~/.curlrc unless -q is first).
set -euo pipefail

probe="$(cd "$(dirname "$0")" && pwd)/probe-network.sh"
stubs="$(mktemp -d "${TMPDIR:-/tmp}/probe-stubs.XXXXXX")"
trap 'rm -rf "$stubs"' EXIT
log="$stubs/calls.log"

stub() { { echo '#!/bin/bash'; cat; } >"$stubs/$1"; chmod +x "$stubs/$1"; }
stub scutil <<'SH'
case "$1" in
    --nwi) printf 'Network information\n\nIPv4 network interface information\n     en0 : flags      : 0x5 (IPv4,DNS)\n           address    : %s\n           reach      : 0x00000002 (Reachable)\n\n   REACH : flags 0x00000002 (Reachable)\n\nNetwork interfaces: %s\n' "$FAKE_IP" "$FAKE_IFACES" ;;
    --dns) printf '%b' "$FAKE_DNS_CONFIG" ;;
esac
SH
stub ipconfig <<'SH'
case "$1:${3:-}" in
    getifaddr:) echo "$FAKE_IP" ;;
    getoption:router) echo "$FAKE_GW" ;;
    getoption:domain_name_server) echo "$FAKE_NETDNS" ;;
esac
SH
stub route <<'SH'
printf '   route to: default\ndestination: default\n       mask: default\n    gateway: %s\n  interface: %s\n' "$FAKE_GW" "$FAKE_DEFAULT_IF"
SH
stub ping <<'SH'
echo "ping $*" >>"$FAKE_LOG"
exit "$FAKE_PING"
SH
# FAKE_HTTP lists the direct targets that answer, as host=CODE. FAKE_PROXY lists the proxies that answer, as host:port=CODE,
# or host:port=unresolved for a proxy name the system resolver cannot resolve. Any other target or proxy does not answer.
stub curl <<'SH'
echo "curl $*" >>"$FAKE_LOG"
if [ "${1:-}" != -q ] && [ -r "$HOME/.curlrc" ]; then
    while read -r option value; do [ "$option" = --trace-ascii ] && : >"$value"; done <"$HOME/.curlrc"
fi
proxy="" format="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x) proxy="${2#http://}"; shift ;;
        -w) format="$2"; shift ;;
        -o|-m|--interface|--noproxy) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
host="${url#*://}"; host="${host%%/*}"
code=000 connect=000 status=28
if [ -n "$proxy" ]; then
    reply=""
    for entry in $FAKE_PROXY; do [ "${entry%=*}" = "$proxy" ] && reply="${entry##*=}"; done
    case "$reply" in
        "") status=7 ;;
        unresolved) status=5 ;;
        *) if [ "${url%%://*}" = https ]; then
               connect="$reply"
               if [ "$reply" = 200 ]; then code=200 status=0; else status=56; fi
           else
               code="$reply" status=0
           fi ;;
    esac
else
    for entry in $FAKE_HTTP; do [ "${entry%=*}" = "$host" ] && { code="${entry##*=}"; status=0; }; done
fi
out="${format//'%{http_code}'/$code}"
printf '%s' "${out//'%{http_connect}'/$connect}"
exit "$status"
SH
# FAKE_DIG lists the servers that answer, as server:port=STATUS. NOERROR answers one A record, EMPTY is NOERROR with none,
# and any other status has no answer. Any other server times out.
stub dig <<'SH'
echo "dig $*" >>"$FAKE_LOG"
server="" port=53 name="" short=""
[ -r "$HOME/.digrc" ] && grep -q '+short' "$HOME/.digrc" && short=1
while [ $# -gt 0 ]; do
    case "$1" in
        @*) server="${1#@}" ;;
        -p) port="$2"; shift ;;
        -q) name="$2"; shift ;;
        -b|-t) shift ;;
        +short) short=1 ;;
        +*) ;;
        -*) echo "Invalid option: $1"; exit 1 ;;
        *) [ -z "$name" ] && name="$1" ;;
    esac
    shift
done
case "$server" in
    *[!0-9a-fA-F.:%]*) echo "resolve $server" >>"$FAKE_LOG"; echo "dig: couldn't get address for '$server': not found"; exit 10 ;;
esac
echo "query $server:$port $name" >>"$FAKE_LOG"
status=""
for entry in $FAKE_DIG; do [ "${entry%=*}" = "$server:$port" ] && status="${entry##*=}"; done
[ -n "$status" ] || { echo ";; connection timed out; no servers could be reached"; exit 9; }
answers=0
[ "$status" = NOERROR ] && answers=1
[ "$status" = EMPTY ] && status=NOERROR
if [ -n "$short" ]; then [ "$answers" = 1 ] && echo 192.0.2.10; exit 0; fi
printf ';; Got answer:\n;; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n;; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$status" "$answers"
[ "$answers" = 1 ] && printf ';; ANSWER SECTION:\n%s.\t\t60\tIN\tA\t192.0.2.10\n\n' "$name"
exit 0
SH

# Every case runs with these in HOME, so a probe that reads either one changes its answers or writes the trace file.
echo '+short' >"$stubs/.digrc"
echo "--trace-ascii $stubs/curl-trace" >"$stubs/.curlrc"

config() { cat >"$stubs/$1.json"; echo "CONDUIT_CONFIG=$stubs/$1.json"; }
corp="$(config corp <<'JSON'
{"dnsForwarderPort": 5053, "healthCheckURL": "http://health.example/",
 "upstreams": [{"enabled": true, "host": "proxy.corp.example", "port": 8080}],
 "dnsEntries": [{"enabled": true, "domain": "corp.example", "servers": ["10.0.0.53"]}]}
JSON
)"
https_health="$(config https-health <<'JSON'
{"healthCheckURL": "https://health.example/", "upstreams": [{"host": "proxy.corp.example", "port": 8080}]}
JSON
)"
five_proxies="$(config five-proxies <<'JSON'
{"upstreams": [{"host": "p1.corp.example", "port": 8080}, {"host": "p2.corp.example", "port": 8080},
 {"host": "p3.corp.example", "port": 8080}, {"host": "p4.corp.example", "port": 8080}, {"host": "p5.corp.example", "port": 8080}]}
JSON
)"
userinfo="$(config userinfo <<'JSON'
{"upstreams": [{"host": "user@proxy.example", "port": 8080}, {"host": "proxy.corp.example", "port": 8080}]}
JSON
)"
split_name="$(config split-name <<'JSON'
{"dnsEntries": [{"domain": "corp.example", "servers": ["dns.corp.example"]}]}
JSON
)"
broken="$(config broken <<'JSON'
{"upstreams": [{"host": "secretproxy.example", "port": 80
JSON
)"

dns_config() { # <default server, or "" for none> [default port] [vpn interface] [vpn servers] [vpn port]
    local out="DNS configuration\n\nresolver #1\n" vpn="" i=0 server
    [ -n "$1" ] && out+="  nameserver[0] : $1\n"
    [ -n "${2:-}" ] && out+="  port     : $2\n"
    out+="  flags    : Request A records\n  reach    : 0x00000002 (Reachable)\n\n"
    out+="resolver #2\n  domain   : local\n  options  : mdns\n  timeout  : 5\n  flags    : Request A records\n  reach    : 0x00000000 (Not Reachable)\n  order    : 300000\n\n"
    if [ -n "${3:-}" ]; then
        for server in $4; do vpn+="  nameserver[$i] : $server\n"; i=$((i + 1)); done
        [ -n "${5:-}" ] && vpn+="  port     : $5\n"
        vpn+="  if_index : 20 ($3)\n"
        out+="resolver #3\n  domain   : corp.example\n${vpn}  flags    : Supplemental, Request A records\n  reach    : 0x00000003 (Reachable,Transient Connection)\n  order    : 102400\n\n"
    fi
    out+="DNS configuration (for scoped queries)\n\nresolver #1\n  nameserver[0] : 192.168.1.1\n  if_index : 14 (en0)\n  flags    : Scoped, Request A records\n  reach    : 0x00000002 (Reachable)\n"
    [ -n "${3:-}" ] && out+="\nresolver #2\n${vpn}  flags    : Scoped, Request A records\n  reach    : 0x00000003 (Reachable,Transient Connection)\n"
    printf '%s' "$out"
}

# Optional per case: args for the probe, shows (in the output), absent (from stdout and stderr), logged (a stub call).
failures=0 args="" shows="" absent="" logged=""
run_case() { # <label> <expected exit> <expected Location/Verdict substring> then env assignments
    local label="$1" want_rc="$2" want="$3"; shift 3
    local out rc=0 problems=""
    rm -f "$log" "$stubs/curl-trace"; : >"$log"
    out="$(env -i PATH="$stubs:/usr/bin:/bin" HOME="$stubs" FAKE_LOG="$log" FAKE_IFACES=en0 FAKE_IP=192.168.1.20 \
        FAKE_GW=192.168.1.1 FAKE_NETDNS=192.168.1.1 FAKE_DEFAULT_IF=en0 FAKE_PING=0 FAKE_HTTP="1.1.1.1=301 9.9.9.9=404" \
        FAKE_PROXY= FAKE_DIG= FAKE_DNS_CONFIG= "$@" /bin/zsh "$probe" $args 2>&1)" || rc=$?
    local verdict; verdict="$(printf '%s\n' "$out" | grep -E '^(Location|Verdict):' | tr '\n' ' ' || true)"
    [ "$rc" -eq "$want_rc" ] || problems+=" exit $rc, wanted $want_rc;"
    [[ "$verdict" == *"$want"* ]] || problems+=" verdict;"
    [ -z "$shows" ] || [[ "$out" == *"$shows"* ]] || problems+=" output lacks: $shows;"
    [ -z "$absent" ] || [[ "$out" != *"$absent"* ]] || problems+=" output shows: $absent;"
    [ -z "$logged" ] || grep -qxF -- "$logged" "$log" || problems+=" no stub call: $logged;"
    [ ! -e "$stubs/curl-trace" ] || problems+=" curl read ~/.curlrc;"
    ! grep -q '^resolve ' "$log" || problems+=" dig resolved a server name: $(grep '^resolve ' "$log" | head -1);"
    ! grep '^ping ' "$log" | grep -qv ' -n ' || problems+=" ping without -n;"
    if [ -z "$problems" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label:$problems"; printf '%s\n' "$out" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
    args="" shows="" absent="" logged=""
}

all_answer="192.168.1.1:53=NOERROR 1.1.1.1:53=NOERROR"
vpn_up=(FAKE_IFACES="en0 utun6" FAKE_DEFAULT_IF=utun6)
run_case "a healthy network passes, with ~/.digrc and ~/.curlrc ignored" 0 "Names resolve and the network passes traffic." \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a hotspot with no upstream is named as the network, not the Mac" 2 "This network is not passing traffic" \
    FAKE_PING=1 FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "the hotspot verdict holds while its gateway still answers ping" 2 "This network is not passing traffic" \
    FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "a hotspot whose DNS cache still answers is not healthy" 2 "This network is not reaching the internet" \
    FAKE_HTTP= FAKE_DIG="192.168.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "names that resolve without a data path are not healthy" 2 "this network is not passing web traffic" \
    FAKE_HTTP= FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "one blocked address is not a dead network" 0 "Names resolve and the network passes traffic." \
    FAKE_HTTP="9.9.9.9=404" FAKE_NETDNS= FAKE_DIG="10.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
shows="OK    direct HTTPS to 1.1.1.1 or 9.9.9.9 1.1.1.1 HTTP 301"
run_case "the first direct target that answers is enough" 0 "Names resolve and the network passes traffic." \
    FAKE_HTTP="1.1.1.1=301" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "an office that blocks direct traffic passes through its proxy" 0 "Location: corporate network (experimental" \
    "$corp" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=407" FAKE_DIG="192.168.1.1:53=NOERROR 10.0.0.53:53=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

run_case "a resolver that refuses every query does not resolve" 2 "The system resolver 192.168.1.1 answers REFUSED for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=REFUSED 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "NXDOMAIN is not resolution" 2 "answers NXDOMAIN for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=NXDOMAIN 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "NOERROR with no address is not resolution" 2 "answers with no address for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=EMPTY 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
args="--name +time=60" logged="query 1.1.1.1:53 +time=60"
run_case "the query name reaches dig as a name, never as an option" 0 "Names resolve and" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

run_case "Conduit's resolver with a silent forwarder names Conduit" 2 "Conduit's DNS forwarder is not answering" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's resolver with a silent relay but a live forwarder names the relay path" 2 "though the forwarder answers directly" \
    FAKE_DIG="$all_answer 127.0.0.1:5053=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "a SERVFAIL from Conduit names its upstream, not its listener" 2 "reports that its upstream DNS failed (SERVFAIL)" \
    FAKE_DIG="$all_answer 127.0.0.1:5053=SERVFAIL 127.0.0.1:53=SERVFAIL" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's DNS through the VPN override port passes" 0 "Names resolve" \
    FAKE_DIG="$all_answer 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353)"
shows="resolver 127.0.0.1:5300 (local, not Conduit's)"
run_case "a local resolver on another port is not Conduit's" 2 "is a local resolver that is not Conduit's" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 5300)"
run_case "a local resolver on another loopback address is not Conduit's" 2 "127.0.0.2 is a local resolver that is not Conduit's" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.2)"
run_case "a network whose own DNS is dead says so" 2 "its DNS server does not answer" \
    FAKE_DIG="1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a resolver #1 without a server is no default resolver, whatever later blocks hold" 2 "No default resolver is configured" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer 10.53.53.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "" "" utun6 10.53.53.53)"

run_case "a VPN whose DNS servers are silent names the tunnel" 2 "The VPN's DNS servers do not answer" \
    "${vpn_up[@]}" FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a healthy VPN passes" 0 "Location: VPN Verdict: Names resolve and" \
    "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "the tunnel that carries the default route is the VPN" 0 "Location: VPN Verdict: Names resolve and" \
    FAKE_IFACES="en0 utun3 utun6" FAKE_DEFAULT_IF=utun6 FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a tunnel with no resolver and no default route is not a VPN" 0 "Location: unknown (no corporate" \
    FAKE_IFACES="en0 utun3" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a split-tunnel VPN with its own resolver is the VPN" 0 "Location: VPN (split tunnel on utun6) Verdict: Names resolve and" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer 10.53.53.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1 "" utun6 10.53.53.53)"
run_case "a split-tunnel VPN whose DNS is silent says so" 2 "Names resolve, but the VPN's DNS servers do not answer" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1 "" utun6 10.53.53.53)"
shows="OK    VPN's DNS answers                  @10.9.0.2 NOERROR"
run_case "a silent first VPN DNS server does not hide a live second one" 0 "Names resolve and" \
    "${vpn_up[@]}" FAKE_DIG="10.9.0.2:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 "10.53.53.53 10.9.0.2")"
shows="OK    VPN's DNS answers                  @10.9.9.9 NOERROR"
run_case "the VPN's DNS servers are tried in resolver order, not sorted" 0 "Names resolve and" \
    "${vpn_up[@]}" FAKE_DIG="10.9.9.9:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 "10.9.9.9 10.1.0.1 10.1.0.2 10.1.0.3")"
shows="OK    VPN's DNS answers                  @10.53.53.53:5353 NOERROR"
run_case "a VPN's DNS server is asked on its own port" 0 "Names resolve and" \
    "${vpn_up[@]}" FAKE_DIG="10.53.53.53:5353=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53 5353)"
run_case "a corporate proxy answering through the tunnel means the tunnel carries traffic" 2 "Conduit's DNS forwarder is not answering" \
    "$corp" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=407" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "no address means no network" 2 "No network connection" \
    FAKE_IP= FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

run_case "outside the office the corporate checks are expected to fail" 0 "Location: outside the corporate network Verdict: Names resolve and" \
    "$corp" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a corporate proxy answering without the VPN names a corporate network" 0 "Location: corporate network (experimental" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=407" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a CONNECT 407 for an HTTPS health URL is a proxy answering" 0 "Location: corporate network (experimental" \
    "$https_health" FAKE_PROXY="proxy.corp.example:8080=407" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "internal DNS answering directly while no proxy answers is an unknown location" 0 "Location: unknown (the internal DNS server answers directly" \
    "$corp" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "internal DNS answering while proxy names do not resolve is an unknown location" 0 "Location: unknown (the internal DNS server answers directly" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=unresolved" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "on a corporate network a silent internal DNS server says so" 2 "the internal DNS server does not answer" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=407" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "on the VPN a silent corporate proxy says so" 2 "no corporate proxy answers through the VPN" \
    "$corp" "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 10.0.0.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="tried the first 3 of 5"
run_case "only the first 3 of 5 proxies are tried, and it says so" 2 "no corporate proxy answers through the VPN" \
    "$five_proxies" "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a healthy VPN with its proxy and internal DNS passes" 0 "Location: VPN Verdict: Names resolve and" \
    "$corp" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=407" \
    FAKE_DIG="10.53.53.53:53=NOERROR 10.0.0.53:53=NOERROR 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="upstream #1 has an invalid host" absent="user"
run_case "an upstream host carrying a username is reported by number and never printed" 0 "Location: corporate network (experimental" \
    "$userinfo" FAKE_PROXY="user@proxy.example:8080=407 proxy.corp.example:8080=407" FAKE_DIG="$all_answer" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="split-DNS entry #1 has a server that is not an IP address"
run_case "a split-DNS server given as a name is skipped, never resolved" 0 "Names resolve and" \
    "$split_name" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="config   Conduit config unreadable" absent="secretproxy"
run_case "an unreadable config is an unknown location and its content stays out" 0 "Location: unknown (Conduit config unreadable)" \
    "$broken" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

out="$(/bin/zsh "$probe" --name 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 64 ] && [[ "$out" == *"--name needs a host"* ]]; then echo "ok    --name without a host is rejected"; else echo "FAIL  --name without a host (exit $rc): $out"; failures=$((failures + 1)); fi

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
