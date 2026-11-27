#!/bin/zsh
# Probes each layer between this Mac and the internet, using IP addresses only so it works while DNS is down,
# and names the first layer that fails. Read-only: it changes no setting and needs no sudo.
#
# Usage: ./scripts/probe-network.sh [--name HOST]
# It also asks Conduit's configured upstream proxies and first split-DNS server, and says whether this is the VPN,
# a corporate network or outside. CONDUIT_CONFIG names another config.json.
# Exit status: 0 when names resolve and the network passes traffic, 2 when a layer fails, 64 on a usage error.
emulate -L zsh
setopt pipefail

name=www.apple.com
while (( $# )); do
    case "$1" in
        --name) [[ -n "${2:-}" ]] || { echo "--name needs a host" >&2; exit 64 }; name="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
done

typeset -A result detail
check() { # <id> <label> <ok|fail|skip> <detail>
    result[$1]=$3
    detail[$1]=$4
    printf '%-5s %-34s %s\n' "${(U)3}" "$2" "$4"
}

# Prints the DNS status (NOERROR, NXDOMAIN, SERVFAIL...) or "timeout". Any status but SERVFAIL means the server answered.
dns_status() { # <server> <port> [source address] [name]
    local out source=()
    [[ -n "${3:-}" ]] && source=(-b "$3")
    out="$(dig +time=2 +tries=1 +noall +comments $source -p "$2" "@$1" "${4:-$name}" A 2>&1)"
    [[ "$out" =~ 'status: ([A-Z]+)' ]] && echo "$match[1]" || echo timeout
}

dns_check() { # <id> <label> <server> <port> [source address]
    local answer; answer="$(dns_status "$3" "$4" "$5")"
    local where="@$3"; [[ "$4" == 53 ]] || where="@$3:$4"
    if [[ "$answer" == timeout || "$answer" == SERVFAIL ]]; then
        check "$1" "$2" fail "$where $answer"
    else
        check "$1" "$2" ok "$where $answer"
    fi
}

# The machine's view: the physical interface, its gateway and DHCP DNS, and any VPN tunnel.
nwi="$(scutil --nwi 2>/dev/null)"
interfaces=(${=$(print -r -- "$nwi" | awk '/^Network interfaces:/ { for (i = 3; i <= NF; i++) print $i }')})
physical="" vpn=""
for i in $interfaces; do
    case "$i" in
        utun*|ipsec*|ppp*) [[ -z "$vpn" ]] && vpn="$i" ;;
        *) [[ -z "$physical" ]] && physical="$i" ;;
    esac
done
address="" gateway="" network_dns=""
if [[ -n "$physical" ]]; then
    address="$(ipconfig getifaddr "$physical" 2>/dev/null)"
    gateway="$(ipconfig getoption "$physical" router 2>/dev/null)"
    network_dns="$(ipconfig getoption "$physical" domain_name_server 2>/dev/null)"
fi
default_interface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
on_vpn=false
[[ -n "$vpn" && "$default_interface" == "$vpn" ]] && on_vpn=true

dns_config="$(scutil --dns 2>/dev/null)"
# The default resolver apps use: resolver #1 of the unscoped configuration.
system_dns="$(print -r -- "$dns_config" | awk '/^DNS configuration \(for scoped/ { exit } /^resolver #1/ { r = 1 } r && /nameserver\[0\]/ { print $3; exit }')"
system_port="$(print -r -- "$dns_config" | awk '/^DNS configuration \(for scoped/ { exit } /^resolver #1/ { r = 1 } r && /^ *port/ { print $3; exit } r && /^$/ { exit }')"
vpn_dns=()
if [[ -n "$vpn" ]]; then
    vpn_dns=(${=$(print -r -- "$dns_config" | awk -v ifname="($vpn)" '
        function flush() { if (tunnel) for (i = 1; i <= n; i++) print servers[i]; n = 0; tunnel = 0 }
        /^resolver #/ || /^$/ { flush() }
        /nameserver\[/ { servers[++n] = $3 }
        /if_index/ && index($0, ifname) { tunnel = 1 }
        END { flush() }' | sort -u)})
fi

forwarder_port=5053
upstreams=() split_dns=() health_url=""
config="${CONDUIT_CONFIG:-$HOME/Library/Application Support/Conduit/config.json}"
if [[ -r "$config" ]]; then
    # One line per field: the forwarder port, the health-check URL, then "upstream host:port" and "split domain server" lines.
    settings=("${(@f)$(python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("dnsForwarderPort", ""))
print(c.get("healthCheckURL", ""))
for u in c.get("upstreams", []):
    if u.get("enabled", True) and u.get("host") and u.get("port"):
        print("upstream", "%s:%s" % (u["host"], u["port"]))
for e in c.get("dnsEntries", []):
    if e.get("enabled", True) and e.get("domain") and e.get("servers"):
        print("split", e["domain"], e["servers"][0])
' "$config" 2>/dev/null)}")
    [[ "${settings[1]:-}" == <1-65535> ]] && forwarder_port="${settings[1]}"
    health_url="${settings[2]:-}"
    for line in "${(@)settings[3,-1]}"; do
        case "$line" in
            upstream\ *) upstreams+=("${line#upstream }") ;;
            split\ *) split_dns+=("${line#split }") ;;
        esac
    done
fi

echo "Conduit network probe  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  name=$name"
echo "  network  ${physical:-none}  ip ${address:-none}  gateway ${gateway:-none}  dns ${network_dns:-none}"
echo "  vpn      ${vpn:-none}${vpn:+  default route ${default_interface:-none}}${vpn_dns:+  dns ${(j:,:)vpn_dns}}"
echo "  system   resolver ${system_dns:-none}${system_port:+:$system_port}"
echo

# The physical network. On a full-tunnel VPN the client blocks traffic outside the tunnel, so these say nothing there.
if [[ -z "$address" ]]; then
    check link "Mac has a network address" fail "${physical:-no interface} has no IPv4 address"
elif $on_vpn; then
    check link "Mac has a network address" ok "$physical $address"
    for id label in gateway "gateway answers ping" network_dns "network's DNS answers" internet "direct HTTPS to 1.1.1.1" public_dns "public DNS 1.1.1.1 answers"; do
        check $id "$label" skip "the VPN carries all traffic"
    done
else
    check link "Mac has a network address" ok "$physical $address"
    if [[ -n "$gateway" ]] && ping -c 2 -t 3 -b "$physical" "$gateway" >/dev/null 2>&1; then
        check gateway "gateway answers ping" ok "$gateway"
    else
        check gateway "gateway answers ping" fail "${gateway:-no gateway} (some routers drop ping)"
    fi
    if [[ -n "$network_dns" ]]; then
        dns_check network_dns "network's DNS answers" "${network_dns%% *}" 53 "$address"
    else
        check network_dns "network's DNS answers" skip "DHCP gave no DNS server"
    fi
    code="$(curl --interface "$physical" --noproxy '*' -m 5 -s -o /dev/null -w '%{http_code}' https://1.1.1.1 2>/dev/null)"
    if [[ "$code" == <100-599> ]]; then
        check internet "direct HTTPS to 1.1.1.1" ok "HTTP $code"
    else
        check internet "direct HTTPS to 1.1.1.1" fail "no HTTP response in 5 s"
    fi
    dns_check public_dns "public DNS 1.1.1.1 answers" 1.1.1.1 53 "$address"
fi

if $on_vpn; then
    if (( $#vpn_dns )); then
        dns_check vpn_dns "VPN's DNS answers" "${vpn_dns[1]}" 53
    else
        check vpn_dns "VPN's DNS answers" skip "the VPN pushed no DNS server"
    fi
fi

# The corporate side, from Conduit's configuration. An upstream proxy that answers off the VPN means a corporate network;
# a 407 is an answer. Names here resolve through the system resolver, so on a network with dead DNS these fail too.
if (( $#upstreams )); then
    proxy_answered=""
    for upstream in "${(@)upstreams[1,3]}"; do
        code="$(curl --noproxy '' -x "http://$upstream" -m 4 -s -o /dev/null -w '%{http_code}' "${health_url:-http://www.apple.com/library/test/success.html}" 2>/dev/null)"
        if [[ "$code" == <100-599> ]]; then proxy_answered="$upstream HTTP $code"; break; fi
    done
    if [[ -n "$proxy_answered" ]]; then
        check corp_proxy "corporate proxy answers" ok "$proxy_answered"
    elif ! $on_vpn; then
        check corp_proxy "corporate proxy answers" skip "none answered: expected outside the corporate network"
    else
        check corp_proxy "corporate proxy answers" fail "none of ${(j:, :)${(@)upstreams[1,3]}} answered in 4 s"
    fi
else
    check corp_proxy "corporate proxy answers" skip "no upstream proxy configured"
fi
if (( $#split_dns )); then
    entry=(${=split_dns[1]})
    answer="$(dns_status "${entry[2]}" 53 "" "${entry[1]}")"
    if [[ "$answer" != timeout && "$answer" != SERVFAIL ]]; then
        check corp_dns "internal DNS answers" ok "@${entry[2]} for ${entry[1]} $answer"
    elif ! $on_vpn && [[ "${result[corp_proxy]}" != ok ]]; then
        check corp_dns "internal DNS answers" skip "@${entry[2]} $answer: expected outside the corporate network"
    else
        check corp_dns "internal DNS answers" fail "@${entry[2]} for ${entry[1]} $answer"
    fi
else
    check corp_dns "internal DNS answers" skip "no split-DNS entry configured"
fi

# Conduit's own layers, and the resolver apps actually use.
uses_conduit=false
[[ "$system_dns" == 127.* ]] && uses_conduit=true
conduit_check() { # <id> <label> <port>: not answering is a failure only while the system resolver uses Conduit.
    local answer; answer="$(dns_status 127.0.0.1 "$3")"
    if [[ "$answer" != timeout && "$answer" != SERVFAIL ]]; then
        check "$1" "$2" ok "@127.0.0.1:$3 $answer"
    elif $uses_conduit; then
        check "$1" "$2" fail "@127.0.0.1:$3 $answer"
    else
        check "$1" "$2" skip "@127.0.0.1:$3 $answer (the system resolver does not use Conduit)"
    fi
}
conduit_check forwarder "Conduit DNS forwarder answers" "$forwarder_port"
conduit_check relay "Conduit relay on :53 answers" 53
if [[ -n "$system_dns" ]]; then
    dns_check system "system resolver answers" "$system_dns" "${system_port:-53}"
else
    check system "system resolver answers" fail "no default resolver configured"
fi

echo
failed() { [[ "${result[$1]}" == fail ]] }
answered() { [[ "${result[$1]}" == ok ]] }
if failed link; then
    verdict="No network connection: ${detail[link]}. Join a network first."
elif ! $on_vpn && failed internet && failed public_dns && ! answered network_dns; then
    verdict="This network is not passing traffic: direct connections to 1.1.1.1 and its DNS both fail. Switch networks or restart the hotspot or router. Restarting the Mac or Conduit will not help."
elif $on_vpn && failed vpn_dns && failed system; then
    verdict="The VPN's DNS servers do not answer, so the tunnel is not carrying traffic. Reconnect the VPN, or disconnect it if the network underneath changed."
elif answered system && failed corp_proxy; then
    verdict="Names resolve, but no corporate proxy answers through the VPN, so corporate sites may fail."
elif answered system && failed corp_dns; then
    verdict="Names resolve, but the internal DNS server does not answer, so internal names may fail."
elif answered system; then
    verdict="Names resolve and the network passes traffic."
elif $uses_conduit && failed forwarder; then
    verdict="The system resolver points at Conduit, and Conduit's DNS forwarder is not answering. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
elif $uses_conduit; then
    verdict="The system resolver points at Conduit (${system_dns}${system_port:+:$system_port}) and gets no answer, though the forwarder answers directly. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
elif ! $on_vpn && answered internet && failed network_dns; then
    verdict="The network passes traffic but its DNS server does not answer. Use another DNS server, or let Conduit manage DNS."
else
    verdict="The system resolver ${system_dns:-none} does not answer, though the network passes traffic."
fi
if $on_vpn; then
    location="VPN"
elif answered corp_proxy; then
    location="corporate network (experimental: a corporate proxy answers without the VPN)"
else
    location="outside the corporate network"
fi
echo "Location: $location"
echo "Verdict: $verdict"
[[ "$verdict" == "Names resolve and the network passes traffic." ]] && exit 0 || exit 2
