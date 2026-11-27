#!/bin/bash
# Runs probe-network.sh against stubbed system tools, one network state per case, and checks the verdict and exit status.
# The stubs follow the tools macOS ships: dig 9.10 (no -r, reads ~/.digrc, retries over TCP after a truncated reply unless
# +ignore is given) and curl 8 (reads ~/.curlrc unless -q is first, expands {a,b} in a URL into one transfer each unless -g
# is given, reads options from stdin with -K -, writes TLS keys to $SSLKEYLOGFILE).
set -euo pipefail

probe="$(cd "$(dirname "$0")" && pwd)/probe-network.sh"
stubs="$(mktemp -d "${TMPDIR:-/tmp}/probe-stubs.XXXXXX")"
trap 'rm -rf "$stubs"' EXIT
log="$stubs/calls.log"

stub() { { echo '#!/bin/bash'; cat; } >"$stubs/$1"; chmod +x "$stubs/$1"; }
# FAKE_IPV6 names an interface to list in the IPv6 section, as on a network with IPv6.
stub scutil <<'SH'
case "$1" in
    --nwi) printf 'Network information\n\nIPv4 network interface information\n'
           [ -n "$FAKE_IP" ] && printf '     en0 : flags      : 0x5 (IPv4,DNS)\n           address    : %s\n           reach      : 0x00000002 (Reachable)\n' "$FAKE_IP"
           printf '\n   REACH : flags 0x00000002 (Reachable)\n\nIPv6 network interface information\n'
           if [ -n "${FAKE_IPV6:-}" ]; then
               printf '     %s : flags      : 0x6 (IPv6,DNS)\n           address    : 2001:db8::20\n           reach      : 0x00000002 (Reachable)\n' "$FAKE_IPV6"
           else
               printf '   No IPv6 states found\n'
           fi
           printf '\n   REACH : flags 0x00000000 (Not Reachable)\n\nNetwork interfaces: %s\n' "$FAKE_IFACES" ;;
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
# Each stub logs its arguments one per bracket, so a value that a shell split or joined shows up.
stub ping <<'SH'
{ printf 'ping'; printf ' [%s]' "$@"; echo; } >>"$FAKE_LOG"
exit "$FAKE_PING"
SH
# FAKE_HTTP lists the direct targets that answer, as host=CODE, or host=CODE/EXIT for a reply curl reports with that exit
# status, such as 200/18 for a body cut off. FAKE_PROXY lists the proxies that answer, as
# host:port=CONNECT/FINAL/EXIT: curl's %{http_connect}, %{http_code} and exit status, which real curl reports apart.
# An HTTP URL through a proxy has CONNECT 000. host:port=unresolved is a proxy name the system resolver cannot resolve.
# Any other target or proxy does not answer.
stub curl <<'SH'
{ printf 'curl'; printf ' [%s]' "$@"; echo; } >>"$FAKE_LOG"
[ -z "${SSLKEYLOGFILE:-}" ] || echo "CLIENT_RANDOM 00 00" >>"$SSLKEYLOGFILE"
if [ "${1:-}" != -q ] && [ -r "$HOME/.curlrc" ]; then
    while read -r option value; do [ "$option" = --trace-ascii ] && : >"$value"; done <"$HOME/.curlrc"
fi
proxy="" format="" url="" globoff=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x) proxy="${2#http://}"; shift ;;
        -w) format="$2"; shift ;;
        --url) url="$2"; shift ;;
        -K) if [ "$2" = - ]; then
                # A quoted value ends at the first unescaped quote; a backslash takes the next character as it is.
                while IFS= read -r line; do
                    [[ "$line" =~ ^url\ =\ \"(.*)$ ]] || continue
                    rest="${BASH_REMATCH[1]}" url=""
                    while [ -n "$rest" ]; do
                        c="${rest:0:1}" rest="${rest:1}"
                        [ "$c" = '"' ] && break
                        [ "$c" = '\' ] && { c="${rest:0:1}" rest="${rest:1}"; }
                        url+="$c"
                    done
                done
            fi
            shift ;;
        -g) globoff=1 ;;
        -o|-m|--interface|--noproxy) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
urls=("$url")
case "$url" in
    *{*,*}*) if [ -z "$globoff" ]; then
                 prefix="${url%%\{*}" rest="${url#*\{}"; inner="${rest%%\}*}" suffix="${rest#*\}}"
                 IFS=, read -ra alternatives <<<"$inner"; urls=()
                 for alternative in "${alternatives[@]}"; do urls+=("$prefix$alternative$suffix"); done
             fi ;;
esac
for one in "${urls[@]}"; do
    echo "transfer $one" >>"$FAKE_LOG"
    host="${one#*://}"; host="${host%%/*}"
    code=000 connect=000 status=28
    if [ -n "$proxy" ]; then
        reply=""
        for entry in $FAKE_PROXY; do [ "${entry%=*}" = "$proxy" ] && reply="${entry##*=}"; done
        case "$reply" in
            "") status=7 ;;
            unresolved) status=5 ;;
            *) IFS=/ read -r connect code status <<<"$reply" ;;
        esac
    else
        for entry in $FAKE_HTTP; do
            [ "${entry%=*}" = "$host" ] || continue
            IFS=/ read -r code status <<<"${entry##*=}"; status="${status:-0}"
        done
    fi
    out="${format//'%{http_code}'/$code}"
    printf '%s' "${out//'%{http_connect}'/$connect}"
done
exit "$status"
SH
# FAKE_DIG lists the servers that answer, as server:port=STATUS. NOERROR answers one A record, EMPTY is NOERROR with none,
# TRUNC is a truncated NOERROR over UDP from a server that drops DNS over TCP, and any other status has no answer.
# Any other server times out. Like dig, it prints a space in a name as \032.
stub dig <<'SH'
{ printf 'dig'; printf ' [%s]' "$@"; echo; } >>"$FAKE_LOG"
server="" port=53 name="" short="" ignore=""
[ -r "$HOME/.digrc" ] && grep -q '+short' "$HOME/.digrc" && short=1
while [ $# -gt 0 ]; do
    case "$1" in
        @*) server="${1#@}" ;;
        -p) port="$2"; shift ;;
        -q) name="$2"; shift ;;
        -b|-t) shift ;;
        +short) short=1 ;;
        +ignore) ignore=1 ;;
        +*) ;;
        -*) echo "Invalid option: $1"; exit 1 ;;
        *) [ -z "$name" ] && name="$1" ;;
    esac
    shift
done
case "$server" in
    *[!0-9a-fA-F.:%]*) echo "resolve $server" >>"$FAKE_LOG"; echo "dig: couldn't get address for '$server': not found"; exit 10 ;;
esac
echo "query $server:$port [$name]" >>"$FAKE_LOG"
status=""
for entry in $FAKE_DIG; do [ "${entry%=*}" = "$server:$port" ] && status="${entry##*=}"; done
if [ "$status" = TRUNC ]; then
    [ -n "$ignore" ] || { echo "tcp retry $server:$port" >>"$FAKE_LOG"; status=""; }
fi
[ -n "$status" ] || { echo ";; connection timed out; no servers could be reached"; exit 9; }
answers=0
[ "$status" = TRUNC ] && status=NOERROR
[ "$status" = NOERROR ] && answers=1
[ "$status" = EMPTY ] && status=NOERROR
if [ -n "$short" ]; then [ "$answers" = 1 ] && echo 192.0.2.10; exit 0; fi
printf ';; Got answer:\n;; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n;; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$status" "$answers"
[ "$answers" = 1 ] && printf ';; ANSWER SECTION:\n%s.\t\t60\tIN\tA\t192.0.2.10\n\n' "${name// /\\032}"
exit 0
SH
# Logs whether the config reader asks for isolation and no bytecode. The Python that macOS ships skips bytecode under -I on
# its own, and others do not, so this reads the options the probe passes rather than what this interpreter does.
stub python3 <<'SH'
isolated=0 nobytecode=0
for a in "$@"; do
    case "$a" in -c) break ;; -*I*) isolated=1 ;; esac
    case "$a" in -*B*) nobytecode=1 ;; esac
done
echo "python isolated=$isolated nobytecode=$nobytecode" >>"$FAKE_LOG"
exec /usr/bin/python3 "$@"
SH

# Every case runs with these in HOME, so a probe that reads either one changes its answers or writes the trace file.
echo '+short' >"$stubs/.digrc"
echo "--trace-ascii $stubs/curl-trace" >"$stubs/.curlrc"

# Each config gets its own directory, as Conduit keeps platform.json beside config.json.
config() { mkdir -p "$stubs/$1"; cat >"$stubs/$1/config.json"; echo "CONDUIT_CONFIG=$stubs/$1/config.json"; }
platform() { echo "{\"manageSystemDNS\": $2}" >"$stubs/$1/platform.json"; }
corp="$(config corp <<'JSON'
{"dnsForwarderPort": 5053, "healthCheckURL": "http://health.example/",
 "upstreams": [{"enabled": true, "host": "proxy.corp.example", "port": 8080, "priority": 0}],
 "dnsEntries": [{"enabled": true, "domain": "corp.example", "servers": ["10.0.0.53"]}]}
JSON
)"
platform corp true
conduit_dns="$(config conduit-dns <<<'{}')"
platform conduit-dns true
legacy_dns="$(config legacy-dns <<<'{"manageSystemDNS": true}')"
sidecar_off="$(config sidecar-off <<<'{"manageSystemDNS": true}')"
platform sidecar-off false
https_health="$(config https-health <<'JSON'
{"healthCheckURL": "https://health.example/", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
glob_health="$(config glob-health <<'JSON'
{"healthCheckURL": "http://health.example/{a,b}", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
userinfo_health="$(config userinfo-health <<'JSON'
{"healthCheckURL": "http://urlsentinel:pw@health.example/", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
ftp_health="$(config ftp-health <<'JSON'
{"healthCheckURL": "ftp://health.example/", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
option_health="$(config option-health <<'JSON'
{"healthCheckURL": "--config=/optsentinel", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
token_health="$(config token-health <<'JSON'
{"healthCheckURL": "http://health.example/check?token=argvsentinel", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
quoted_health="$(config quoted-health <<'JSON'
{"healthCheckURL": "http://health.example/a\"b\\c", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
scoped_health="$(config scoped-health <<'JSON'
{"healthCheckURL": "http://[fe80::1%25scopesentinel]/", "upstreams": [{"host": "proxy.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
split_only="$(config split-only <<'JSON'
{"dnsEntries": [{"domain": "corp.example", "servers": ["10.0.0.53"]}]}
JSON
)"
five_proxies="$(config five-proxies <<'JSON'
{"upstreams": [{"host": "p1.corp.example", "port": 8080, "priority": 0}, {"host": "p2.corp.example", "port": 8080, "priority": 1},
 {"host": "p3.corp.example", "port": 8080, "priority": 2}, {"host": "p4.corp.example", "port": 8080, "priority": 3},
 {"host": "p5.corp.example", "port": 8080, "priority": 4}]}
JSON
)"
by_priority="$(config by-priority <<'JSON'
{"upstreams": [{"host": "p1.corp.example", "port": 8080, "priority": 3}, {"host": "p2.corp.example", "port": 8080, "priority": 2},
 {"host": "p3.corp.example", "port": 8080, "priority": 1}, {"host": "p4.corp.example", "port": 8080, "priority": 0}]}
JSON
)"
challenge_first="$(config challenge-first <<'JSON'
{"upstreams": [{"host": "p1.corp.example", "port": 8080, "priority": 0}, {"host": "p2.corp.example", "port": 8080, "priority": 1},
 {"host": "p3.corp.example", "port": 8080, "priority": 2}]}
JSON
)"
userinfo="$(config userinfo <<'JSON'
{"upstreams": [{"host": "user@proxy.example", "port": 8080, "priority": 0}, {"host": "proxy.corp.example", "port": 8080, "priority": 1}]}
JSON
)"
scoped_upstream="$(config scoped-upstream <<'JSON'
{"upstreams": [{"host": "fe80::1%scopesentinel", "port": 8080, "priority": 0}]}
JSON
)"
scoped_split="$(config scoped-split <<'JSON'
{"dnsEntries": [{"domain": "corp.example", "servers": ["fe80::53%scopesentinel"]}]}
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
mkdir -p "$stubs/fifo" "$stubs/fed-fifo"; mkfifo "$stubs/fifo/config.json" "$stubs/fed-fifo/config.json"
fifo="CONDUIT_CONFIG=$stubs/fifo/config.json" fed_fifo="CONDUIT_CONFIG=$stubs/fed-fifo/config.json"

dns_config() { # <default servers, or "" for none> [default port] [vpn interface] [vpn servers] [vpn port]
    local out="DNS configuration\n\nresolver #1\n" vpn="" i=0 server
    for server in $1; do out+="  nameserver[$i] : $server\n"; i=$((i + 1)); done
    i=0
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

# Optional per case: args (an array) for the probe, shows (in the output), absent (from stdout and stderr), logged (a stub call).
# A probe that hangs is stopped after 30 s and fails its case.
failures=0 args=() shows="" absent="" logged=""
run_case() { # <label> <expected exit> <expected Location/Verdict substring> then env assignments
    local label="$1" want_rc="$2" want="$3"; shift 3
    local out rc=0 problems=""
    rm -f "$log" "$stubs/curl-trace" "$stubs/keylog"; : >"$log"
    out="$(/usr/bin/perl -e 'alarm 30; exec @ARGV or die' env -i PATH="$stubs:/usr/bin:/bin" HOME="$stubs" FAKE_LOG="$log" \
        FAKE_IFACES=en0 FAKE_IP=192.168.1.20 FAKE_GW=192.168.1.1 FAKE_NETDNS=192.168.1.1 FAKE_DEFAULT_IF=en0 FAKE_PING=0 \
        FAKE_HTTP="1.1.1.1=301 9.9.9.9=404" FAKE_PROXY= FAKE_DIG= FAKE_DNS_CONFIG= SSLKEYLOGFILE="$stubs/keylog" "$@" \
        /bin/zsh "$probe" ${args[@]+"${args[@]}"} 2>&1)" || rc=$?
    local verdict; verdict="$(printf '%s\n' "$out" | grep -E '^(Location|Verdict):' | tr '\n' ' ' || true)"
    [ "$rc" -eq "$want_rc" ] || problems+=" exit $rc, wanted $want_rc;"
    [[ "$verdict" == *"$want"* ]] || problems+=" verdict;"
    [ -z "$shows" ] || [[ "$out" == *"$shows"* ]] || problems+=" output lacks: $shows;"
    [ -z "$absent" ] || [[ "$out" != *"$absent"* ]] || problems+=" output shows: $absent;"
    [ -z "$logged" ] || grep -qxF -- "$logged" "$log" || problems+=" no stub call: $logged;"
    [ ! -e "$stubs/curl-trace" ] || problems+=" curl read ~/.curlrc;"
    [ ! -e "$stubs/keylog" ] || problems+=" curl wrote \$SSLKEYLOGFILE;"
    ! grep '^curl ' "$log" | grep -qE 'health\.example|/library/test/' || problems+=" the health URL is on curl's argv;"
    ! grep '^python ' "$log" | grep -qvx 'python isolated=1 nobytecode=1' || problems+=" $(grep '^python ' "$log" | head -1);"
    ! grep -q '^resolve ' "$log" || problems+=" dig resolved a server name: $(grep '^resolve ' "$log" | head -1);"
    ! grep '^ping ' "$log" | grep -qvF ' [-n] ' || problems+=" ping without -n;"
    if [ -z "$problems" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label:$problems"; printf '%s\n' "$out" | sed 's/^/      /'
        failures=$((failures + 1))
    fi
    args=() shows="" absent="" logged=""
}

healthy="Names resolve and the network passes traffic."
unverified_tunnel="Names resolve, but web traffic through the tunnel is unverified"
reaches_proxy="Names resolve and the network reaches the corporate proxy, but no request through it completed"
all_answer="192.168.1.1:53=NOERROR 1.1.1.1:53=NOERROR"
vpn_up=(FAKE_IFACES="en0 utun6" FAKE_DEFAULT_IF=utun6)
run_case "a healthy network passes, with ~/.digrc and ~/.curlrc ignored" 0 "$healthy" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a hotspot with no upstream is named as the network, not the Mac" 2 "This network is not passing traffic" \
    FAKE_PING=1 FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "the hotspot verdict holds while its gateway still answers ping" 2 "This network is not passing traffic" \
    FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "a hotspot whose DNS cache still answers is not healthy" 2 "This network is not reaching the internet" \
    FAKE_HTTP= FAKE_DIG="192.168.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a resolver past the network that resolves makes a dead-looking network inconclusive" 2 "Inconclusive: names resolve through 10.1.1.1" \
    FAKE_HTTP= FAKE_NETDNS= FAKE_DIG="10.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
run_case "the network's DNS answering while another resolver resolves is inconclusive" 2 "Inconclusive: names resolve through 10.1.1.1" \
    FAKE_HTTP= FAKE_DIG="192.168.1.1:53=NOERROR 10.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
run_case "names that resolve without a data path are not healthy" 2 "no web request got through: direct HTTPS to 1.1.1.1 and 9.9.9.9 fails." \
    FAKE_HTTP= FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "one blocked address is not a dead network" 0 "$healthy" \
    FAKE_HTTP="9.9.9.9=404" FAKE_NETDNS= FAKE_DIG="10.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
shows="OK    direct HTTPS to 1.1.1.1 or 9.9.9.9 1.1.1.1 HTTP 301"
run_case "the first direct target that answers is enough" 0 "$healthy" \
    FAKE_HTTP="1.1.1.1=301" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="no complete HTTP response from either in 5 s"
run_case "a direct response cut off before it completes is not a working network" 2 "no web request got through" \
    FAKE_HTTP="1.1.1.1=200/18 9.9.9.9=200/18" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="OK    direct HTTPS to 1.1.1.1 or 9.9.9.9 9.9.9.9 HTTP 404"
run_case "a cut-off first target does not hide a complete second one" 0 "$healthy" \
    FAKE_HTTP="1.1.1.1=200/18 9.9.9.9=404" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "an office proxy's 407 shows only that the network reaches it" 1 "Location: corporate network (experimental" \
    "$corp" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=000/407/0" FAKE_DIG="192.168.1.1:53=NOERROR 10.0.0.53:53=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "an office proxy's 407 is not called passing traffic" 1 "$reaches_proxy" \
    "$corp" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=000/407/0" FAKE_DIG="192.168.1.1:53=NOERROR 10.0.0.53:53=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a request that completes through the office proxy passes" 0 "$healthy" \
    "$corp" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="192.168.1.1:53=NOERROR 10.0.0.53:53=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a proxy's own 502 for an HTTP URL is not a completed request" 1 "$reaches_proxy" \
    "$corp" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=000/502/0" FAKE_DIG="192.168.1.1:53=NOERROR 10.0.0.53:53=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="proxy.corp.example:8080 CONNECT 200, no request through it completed (curl exit 35)"
run_case "CONNECT 200 then a failed TLS handshake shows only that the proxy answered" 1 "$reaches_proxy" \
    "$https_health" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=200/000/35" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a response cut off before it completes is not a completed request" 1 "$reaches_proxy" \
    "$https_health" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=200/200/18" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "CONNECT 200 then a final status from the destination passes" 0 "$healthy" \
    "$https_health" FAKE_HTTP= FAKE_PROXY="proxy.corp.example:8080=200/404/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a CONNECT 407 for an HTTPS health URL is a proxy answering" 0 "Location: corporate network (experimental" \
    "$https_health" FAKE_PROXY="proxy.corp.example:8080=407/000/56" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

run_case "a resolver that refuses every query does not resolve" 2 "The system resolver 192.168.1.1 answered with REFUSED for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=REFUSED 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "NXDOMAIN is not resolution" 2 "answered with NXDOMAIN for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=NXDOMAIN 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "NOERROR with no address is not resolution" 2 "answers with no address for www.apple.com." \
    FAKE_DIG="192.168.1.1:53=EMPTY 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="OK    network's DNS answers              @192.168.1.1 NOERROR"
run_case "a truncated UDP reply is an answer, with no retry over TCP" 0 "$healthy" \
    FAKE_DIG="192.168.1.1:53=TRUNC 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
args=(--name +time=60) logged="query 1.1.1.1:53 [+time=60]"
run_case "the query name reaches dig as a name, never as an option" 0 "Names resolve and" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
args=(--name "two words") logged="query 1.1.1.1:53 [two words]"
run_case "the query name reaches dig as one argument" 0 "Names resolve and" \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

absent="inconclusive"
run_case "Conduit's resolver with a silent forwarder names Conduit" 2 "Conduit's DNS forwarder is not answering" \
    "$conduit_dns" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
absent="will not help"
run_case "a silent Conduit resolver is named first, with public reachability inconclusive" 2 "Conduit's DNS forwarder is not answering. Use Restore DNS Settings in Conduit, or turn off Manage system DNS. Whether this network reaches the internet is inconclusive" \
    "$conduit_dns" FAKE_HTTP= FAKE_DIG="192.168.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "manageSystemDNS in an older config.json without platform.json still makes it Conduit's" 2 "Conduit's DNS forwarder is not answering" \
    "$legacy_dns" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
shows="resolver 127.0.0.1 (local)" absent="Restore DNS Settings"
run_case "127.0.0.1:53 with no Conduit config is local, with no Conduit advice" 2 "127.0.0.1 is a local resolver, and it does not answer." \
    FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
shows="resolver 127.0.0.1 (local)" absent="Restore DNS Settings"
run_case "platform.json with Manage system DNS off overrides config.json" 2 "127.0.0.1 is a local resolver" \
    "$sidecar_off" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's resolver with a silent relay but a live forwarder names the relay path" 2 "though the forwarder answers directly" \
    "$conduit_dns" FAKE_DIG="$all_answer 127.0.0.1:5053=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
absent="does not answer directly"
run_case "a SERVFAIL from Conduit is an answer, not silence" 2 "which answered with SERVFAIL, so it or a DNS server it forwards to failed" \
    "$conduit_dns" FAKE_DIG="$all_answer 127.0.0.1:5053=SERVFAIL 127.0.0.1:53=SERVFAIL" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "a relay answering SERVFAIL is not called silent when the forwarder is" 2 "which answered with SERVFAIL, so it or a DNS server it forwards to failed. See the network's and the VPN's DNS checks above. Conduit's DNS forwarder on :5053 does not answer directly." \
    "$conduit_dns" FAKE_DIG="$all_answer 127.0.0.1:53=SERVFAIL" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's relay answering NXDOMAIN is reported as its answer, whatever the forwarder does" 2 "The system resolver 127.0.0.1 answered with NXDOMAIN" \
    "$conduit_dns" FAKE_DIG="$all_answer 127.0.0.1:53=NXDOMAIN" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1)"
run_case "Conduit's DNS through the VPN override port passes" 0 "Names resolve" \
    "$conduit_dns" FAKE_DIG="$all_answer 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353)"
shows="resolver 127.0.0.1:5300 (local)"
run_case "a local resolver on another port is not Conduit's" 2 "is a local resolver, and it does not answer" \
    "$conduit_dns" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 5300)"
run_case "a local resolver on another loopback address is not Conduit's" 2 "127.0.0.2 is a local resolver" \
    "$conduit_dns" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 127.0.0.2)"
run_case "a network whose own DNS is dead says so" 2 "its DNS server does not answer" \
    FAKE_DIG="1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a silent DHCP server is not blamed for another resolver's NXDOMAIN" 2 "The system resolver 10.1.1.1 answered with NXDOMAIN for www.apple.com." \
    FAKE_DIG="10.1.1.1:53=NXDOMAIN 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
run_case "a silent DHCP server is not blamed for another resolver's silence" 2 "The system resolver 10.1.1.1 does not answer." \
    FAKE_DIG="1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.1.1.1)"
shows="OK    system resolver resolves the name  @10.1.1.2 NOERROR"
run_case "a silent first default nameserver does not hide a live second one" 0 "$healthy" \
    FAKE_DIG="10.1.1.2:53=NOERROR 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "10.1.1.1 10.1.1.2")"
shows="system   resolver 127.0.0.1:15353,127.0.0.2:15353"
run_case "every default nameserver is asked on the resolver's port" 0 "$healthy" \
    FAKE_DIG="$all_answer 127.0.0.2:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config "127.0.0.1 127.0.0.2" 15353)"
shows="FAIL  system resolver resolves the name  @10.1.1.1, @10.1.1.2, @10.1.1.3 timeout"
run_case "only the first 3 default nameservers are tried" 2 "The system resolver 10.1.1.1, 10.1.1.2, 10.1.1.3 does not answer." \
    FAKE_DIG="10.1.1.4:53=NOERROR 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "10.1.1.1 10.1.1.2 10.1.1.3 10.1.1.4")"
run_case "the first default nameserver that answers gives the resolver's answer" 2 "The system resolver 10.1.1.1 answered with NXDOMAIN" \
    FAKE_DIG="10.1.1.1:53=NXDOMAIN 10.1.1.2:53=NOERROR 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "10.1.1.1 10.1.1.2")"
shows="resolver 127.0.0.1,10.1.1.1 (local)" absent="local resolver"
run_case "the answer of a second nameserver is not blamed on a silent local first one" 2 "The system resolver 10.1.1.1 answered with NXDOMAIN" \
    FAKE_DIG="10.1.1.1:53=NXDOMAIN 1.1.1.1:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "127.0.0.1 10.1.1.1")"
run_case "a resolver #1 without a server is no default resolver, whatever later blocks hold" 2 "No default resolver is configured" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer 10.53.53.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config "" "" utun6 10.53.53.53)"

vpn_dns_timeout="The VPN's DNS servers do not answer (none of the 1 tried), and the system resolver 127.0.0.1:15353 does not answer."
absent="may not be carrying"
run_case "silent VPN DNS on a full tunnel is a DNS timeout, with the tunnel unverified" 2 "$vpn_dns_timeout Whether the tunnel carries traffic is unverified" \
    "${vpn_up[@]}" FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
absent="may not be carrying"
run_case "a proxy name that silent VPN DNS cannot resolve leaves the tunnel unverified" 2 "$vpn_dns_timeout Whether the tunnel carries traffic is unverified" \
    "$https_health" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=unresolved" FAKE_DIG= \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a silent proxy beside silent VPN DNS says the tunnel may not carry traffic" 2 "$vpn_dns_timeout No corporate endpoint answers through the tunnel either" \
    "$https_health" "${vpn_up[@]}" FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a silent internal DNS server beside silent VPN DNS says the tunnel may not carry traffic" 2 "$vpn_dns_timeout No corporate endpoint answers through the tunnel either" \
    "$split_only" "${vpn_up[@]}" FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
absent="not carrying traffic"
run_case "internal DNS answering through the tunnel is not a dead tunnel" 2 "Verdict: The system resolver 10.53.53.53 does not answer." \
    "$split_only" "${vpn_up[@]}" FAKE_DIG="10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 10.53.53.53 "" utun6 10.53.53.53)"
run_case "a full tunnel with no proxy to test through leaves web traffic unverified" 1 "Location: VPN Verdict: $unverified_tunnel" \
    "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "the tunnel that carries the default route is the VPN" 1 "Location: VPN Verdict: Names resolve" \
    FAKE_IFACES="en0 utun3 utun6" FAKE_DEFAULT_IF=utun6 FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a tunnel with no resolver and no default route is not a VPN" 0 "Location: unknown (no corporate" \
    FAKE_IFACES="en0 utun3" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a split-tunnel VPN with its own resolver is the VPN" 0 "Location: VPN (split tunnel on utun6) Verdict: Names resolve and" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer 10.53.53.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1 "" utun6 10.53.53.53)"
run_case "a split-tunnel VPN whose DNS is silent says so" 2 "Names resolve, but the VPN's DNS servers do not answer" \
    FAKE_IFACES="en0 utun6" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1 "" utun6 10.53.53.53)"
shows="OK    VPN's DNS answers                  @10.9.0.2 NOERROR"
run_case "a silent first VPN DNS server does not hide a live second one" 1 "$unverified_tunnel" \
    "${vpn_up[@]}" FAKE_DIG="10.9.0.2:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 "10.53.53.53 10.9.0.2")"
shows="OK    VPN's DNS answers                  @10.9.9.9 NOERROR"
run_case "the VPN's DNS servers are tried in resolver order, not sorted" 1 "$unverified_tunnel" \
    "${vpn_up[@]}" FAKE_DIG="10.9.9.9:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 "10.9.9.9 10.1.0.1 10.1.0.2 10.1.0.3")"
shows="OK    VPN's DNS answers                  @10.53.53.53:5353 NOERROR"
run_case "a VPN's DNS server is asked on its own port" 1 "$unverified_tunnel" \
    "${vpn_up[@]}" FAKE_DIG="10.53.53.53:5353=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53 5353)"
run_case "a corporate proxy answering through the tunnel means the tunnel carries traffic" 2 "Verdict: The system resolver 10.53.53.53 does not answer." \
    "$https_health" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=000/407/0" FAKE_DNS_CONFIG="$(dns_config 10.53.53.53 "" utun6 10.53.53.53)"
run_case "a tunnel where no VPN DNS server or proxy answers needs reconnecting" 2 "neither the VPN's DNS servers nor a corporate proxy answer through the tunnel (none of the 1 tried)" \
    "$corp" "${vpn_up[@]}" FAKE_DIG="127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "internal DNS answering through the tunnel keeps it from being called dead" 2 "Names resolve, but no corporate proxy answers through the VPN (none of the 1 tried)" \
    "$corp" "${vpn_up[@]}" FAKE_DIG="127.0.0.1:15353=NOERROR 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="Mac has a network address          en0 has IPv6 only, and this probe diagnoses IPv4" absent="No network connection"
run_case "a network with only IPv6 is not called no network" 1 "Verdict: IPv4 diagnostics unavailable" \
    FAKE_IP= FAKE_IPV6=en0 FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "no address means no network" 2 "No network connection" \
    FAKE_IP= FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"

run_case "outside the office the corporate checks are expected to fail" 0 "Location: outside the corporate network (experimental" \
    "$corp" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a dead network with corporate endpoints configured is an unknown location" 2 "Location: unknown (no corporate endpoint answers, but direct internet traffic does not get through either)" \
    "$corp" FAKE_HTTP= FAKE_DIG= FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "a corporate proxy answering without the VPN names a corporate network" 0 "Location: corporate network (experimental" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=000/407/0" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "internal DNS answering directly while no proxy answers is an unknown location" 0 "Location: unknown (the internal DNS server answers directly" \
    "$corp" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "internal DNS answering while proxy names do not resolve is an unknown location" 0 "Location: unknown (the internal DNS server answers directly" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=unresolved" FAKE_DIG="$all_answer 10.0.0.53:53=NOERROR" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "on a corporate network a silent internal DNS server says so" 2 "the internal DNS server does not answer" \
    "$corp" FAKE_PROXY="proxy.corp.example:8080=000/407/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
run_case "on the VPN a silent corporate proxy says so" 2 "no corporate proxy answers through the VPN" \
    "$corp" "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 10.0.0.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="tried the first 3 by priority of 5"
run_case "only the first 3 of 5 proxies are tried, and the verdict says so" 2 "no corporate proxy answers through the VPN (none of the 3 tried)" \
    "$five_proxies" "${vpn_up[@]}" FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="OK    corporate proxy answers            p4.corp.example:8080 HTTP 200"
run_case "proxies are tried in Conduit's priority order, not file order" 0 "$healthy" \
    "$by_priority" "${vpn_up[@]}" FAKE_PROXY="p4.corp.example:8080=000/200/0" FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" \
    FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="OK    corporate proxy answers            p2.corp.example:8080 HTTP 200, a request through it completed"
run_case "a proxy's 407 does not stop a later proxy from completing a request" 0 "Location: VPN Verdict: $healthy" \
    "$challenge_first" "${vpn_up[@]}" FAKE_PROXY="p1.corp.example:8080=000/407/0 p2.corp.example:8080=000/200/0" \
    FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
shows="OK    corporate proxy answers            p1.corp.example:8080 HTTP 407, no request through it completed"
run_case "proxies that only answer, around a silent one, still count as answered" 1 "Location: VPN Verdict: $reaches_proxy" \
    "$challenge_first" "${vpn_up[@]}" FAKE_PROXY="p1.corp.example:8080=000/407/0 p3.corp.example:8080=000/502/0" \
    FAKE_DIG="10.53.53.53:53=NOERROR 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a full tunnel whose proxy only challenges leaves web traffic unverified" 1 "Location: VPN Verdict: $reaches_proxy" \
    "$corp" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=000/407/0" \
    FAKE_DIG="10.53.53.53:53=NOERROR 10.0.0.53:53=NOERROR 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"
run_case "a healthy VPN with a request through its proxy and internal DNS passes" 0 "Location: VPN Verdict: $healthy" \
    "$corp" "${vpn_up[@]}" FAKE_PROXY="proxy.corp.example:8080=000/200/0" \
    FAKE_DIG="10.53.53.53:53=NOERROR 10.0.0.53:53=NOERROR 127.0.0.1:15353=NOERROR" FAKE_DNS_CONFIG="$(dns_config 127.0.0.1 15353 utun6 10.53.53.53)"

logged="transfer http://health.example/{a,b}"
run_case "a health URL with {a,b} is one transfer, not a glob" 0 "Location: corporate network (experimental" \
    "$glob_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
absent="argvsentinel" logged="transfer http://health.example/check?token=argvsentinel"
run_case "a health URL with a token reaches curl over stdin, never its argv" 0 "Location: corporate network (experimental" \
    "$token_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
logged='transfer http://health.example/a"b\c'
run_case "a health URL with a quote and a backslash reaches curl intact" 0 "Location: corporate network (experimental" \
    "$quoted_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="health-check URL is not a plain http(s) URL" absent="scopesentinel" logged="transfer http://www.apple.com/library/test/success.html"
run_case "a health URL with a scoped IPv6 host is refused and never printed" 0 "$healthy" \
    "$scoped_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="health-check URL is not a plain http(s) URL" absent="urlsentinel" logged="transfer http://www.apple.com/library/test/success.html"
run_case "a health URL carrying credentials is refused and never printed" 0 "$healthy" \
    "$userinfo_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="health-check URL is not a plain http(s) URL" logged="transfer http://www.apple.com/library/test/success.html"
run_case "a health URL that is not http or https is refused" 0 "$healthy" \
    "$ftp_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="health-check URL is not a plain http(s) URL" absent="optsentinel" logged="transfer http://www.apple.com/library/test/success.html"
run_case "a health URL that starts with - is refused" 0 "$healthy" \
    "$option_health" FAKE_PROXY="proxy.corp.example:8080=000/200/0" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="upstream #1 has an invalid host" absent="user"
run_case "an upstream host carrying a username is reported by number and never printed" 0 "Location: corporate network (experimental" \
    "$userinfo" FAKE_PROXY="user@proxy.example:8080=000/407/0 proxy.corp.example:8080=000/407/0" FAKE_DIG="$all_answer" \
    FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="upstream #1 has an invalid host" absent="scopesentinel"
run_case "an IPv6 upstream with scope text is reported by number and never printed" 0 "$healthy" \
    "$scoped_upstream" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="split-DNS entry #1 has a server that is not an IP address" absent="scopesentinel"
run_case "an IPv6 split-DNS server with scope text is reported by number and never printed" 0 "$healthy" \
    "$scoped_split" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="split-DNS entry #1 has a server that is not an IP address"
run_case "a split-DNS server given as a name is skipped, never resolved" 0 "Names resolve and" \
    "$split_name" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="config   Conduit config unreadable" absent="secretproxy"
run_case "an unreadable config is an unknown location and its content stays out" 0 "Location: unknown (Conduit config unreadable)" \
    "$broken" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
shows="config   Conduit config unreadable"
run_case "a FIFO as the config is refused without waiting on it" 0 "Location: unknown (Conduit config unreadable)" \
    "$fifo" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
exec 3<>"$stubs/fed-fifo/config.json"; printf '{}' >&3
shows="config   Conduit config unreadable"
run_case "a FIFO with a config waiting in it is still refused" 0 "Location: unknown (Conduit config unreadable)" \
    "$fed_fifo" FAKE_DIG="$all_answer" FAKE_DNS_CONFIG="$(dns_config 192.168.1.1)"
exec 3>&-

out="$(/bin/zsh "$probe" --name 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 64 ] && [[ "$out" == *"--name needs a host"* ]]; then echo "ok    --name without a host is rejected"; else echo "FAIL  --name without a host (exit $rc): $out"; failures=$((failures + 1)); fi

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
