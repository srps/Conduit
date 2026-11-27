#!/bin/zsh
# Probes each layer between this Mac and the internet, using IP addresses only so it works while DNS is down,
# and names the first layer that fails. Read-only: it changes no setting and needs no sudo. It diagnoses IPv4.
#
# Usage: ./scripts/probe-network.sh [--name HOST]
# It also asks Conduit's configured upstream proxies and first split-DNS server, and says whether this is the VPN,
# a corporate network or outside, or that it cannot tell. CONDUIT_CONFIG names another config.json.
# The system check queries the default resolver directly with dig, which gives up after 2 s, not through the macOS resolver.
# Exit status: 0 when names resolve and the network passes traffic, 2 when a layer fails, 64 on a usage error.
emulate -L zsh
setopt pipefail

name=www.apple.com
while (( $# )); do
    case "$1" in
        --name) [[ -n "${2:-}" ]] || { echo "--name needs a host" >&2; exit 64 }; name="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
done

typeset -A result detail rcodes
check() { # <id> <label> <ok|fail|skip> <detail>
    result[$1]=$3
    detail[$1]=$4
    printf '%-5s %-34s %s\n' "${(U)3}" "$2" "$4"
}

# Sets rcode to the DNS status (NOERROR, NXDOMAIN, SERVFAIL...) or "timeout", and addresses to the A records answered.
dns_query() { # <server> <port> <name> [source address]
    local out source=()
    [[ -n "${4:-}" ]] && source=(-b "$4")
    # An empty HOME keeps ~/.digrc out, since the dig macOS ships has no -r.
    out="$(HOME=/var/empty dig +time=2 +tries=1 +noall +comments +answer $source -p "$2" "@$1" -q "$3" -t A 2>&1)"
    rcode=timeout
    [[ "$out" =~ 'status: ([A-Z]+)' ]] && rcode="$match[1]"
    addresses="$(print -r -- "$out" | awk '!/^;/ && $4 == "A" { n++ } END { print n + 0 }')"
}

shown() { [[ "$2" == 53 ]] && print -r -- "$1" || print -r -- "$1:$2" } # <server> <port>

# A server answers when it returns any DNS status. Whether the name resolves is the system check's question.
dns_check() { # <id> <label> <server> <port> [source address]
    dns_query "$3" "$4" "$name" "${5:-}"
    rcodes[$1]=$rcode
    if [[ "$rcode" == timeout ]]; then
        check "$1" "$2" fail "@$(shown "$3" "$4") timeout"
    else
        check "$1" "$2" ok "@$(shown "$3" "$4") $rcode"
    fi
}

is_tunnel() { case "$1" in utun*|ipsec*|ppp*) return 0 ;; esac; return 1 }

# The machine's view: the physical interface, its gateway and DHCP DNS, and any VPN tunnel.
nwi="$(scutil --nwi 2>/dev/null)"
interfaces=(${=$(print -r -- "$nwi" | awk '/^Network interfaces:/ { for (i = 3; i <= NF; i++) print $i }')})
dns_config="$(scutil --dns 2>/dev/null)"
resolver_interfaces=(${=$(print -r -- "$dns_config" | awk '$1 == "if_index" { gsub(/[()]/, "", $4); print $4 }')})
default_interface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
physical="" vpn="" vpn_full=false
for i in $interfaces; do
    is_tunnel "$i" || { physical="$i"; break }
done
if is_tunnel "$default_interface"; then
    vpn="$default_interface" vpn_full=true
else
    # macOS keeps tunnels of its own up. A VPN is a tunnel that brings its own resolver.
    for i in $interfaces; do
        if is_tunnel "$i" && (( ${resolver_interfaces[(Ie)$i]} )); then vpn="$i"; break; fi
    done
fi
address="" gateway="" network_dns=""
if [[ -n "$physical" ]]; then
    address="$(ipconfig getifaddr "$physical" 2>/dev/null)"
    gateway="$(ipconfig getoption "$physical" router 2>/dev/null)"
    network_dns="$(ipconfig getoption "$physical" domain_name_server 2>/dev/null)"
fi

# The default resolver apps use: resolver #1 of the unscoped configuration, which scutil prints first.
resolver1=("${(@s:|:)$(print -r -- "$dns_config" | awk '
    /^resolver #1$/ { r = 1; next }
    r && /^$/ { exit }
    r && $1 == "nameserver[0]" { server = $3 }
    r && $1 == "port" { port = $3 }
    END { print server "|" port }')}")
system_dns="${resolver1[1]}" system_port="${resolver1[2]:-53}"
vpn_dns=() # server and port pairs, in resolver order
if [[ -n "$vpn" ]]; then
    vpn_dns=(${=$(print -r -- "$dns_config" | awk -v ifname="($vpn)" '
        function flush() { if (tunnel) for (i = 1; i <= n; i++) print servers[i], (port ? port : 53); n = 0; tunnel = 0; port = "" }
        /^resolver #/ || /^$/ { flush() }
        $1 ~ /^nameserver\[/ { servers[++n] = $3 }
        $1 == "port" { port = $3 }
        $1 == "if_index" && index($0, ifname) { tunnel = 1 }
        END { flush() }' | awk '!seen[$0]++')})
fi

forwarder_port=5053 config_state=none
upstreams=() invalid_upstreams=() split_dns="" health_url=""
config="${CONDUIT_CONFIG:-$HOME/Library/Application Support/Conduit/config.json}"
if [[ -e "$config" ]]; then
    # One line per field: the forwarder port, the health-check URL, then a line per enabled upstream and split-DNS entry.
    # Hosts and servers are checked here, so nothing else from the file reaches the output or a command line.
    if settings="$(python3 -I -c '
import ipaddress, json, re, sys

def is_ip(s):
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False

c = json.load(open(sys.argv[1]))
port, url = c.get("dnsForwarderPort", ""), c.get("healthCheckURL", "")
print(port if isinstance(port, int) else "")
print(url if isinstance(url, str) and url.isprintable() else "")
for n, u in enumerate(c.get("upstreams", []), 1):
    host, port = u.get("host"), u.get("port")
    if not u.get("enabled", True) or not host or not port:
        continue
    if isinstance(host, str) and (re.fullmatch(r"[A-Za-z0-9.-]+", host) or is_ip(host)) and isinstance(port, int) and 0 < port < 65536:
        print("upstream", ("[%s]:%d" if ":" in host else "%s:%d") % (host, port))
    else:
        print("invalid upstream", n)
for n, e in enumerate(c.get("dnsEntries", []), 1):
    domain, servers = e.get("domain"), e.get("servers")
    if not e.get("enabled", True) or not domain or not servers:
        continue
    if isinstance(domain, str) and re.fullmatch(r"[A-Za-z0-9.*_-]+", domain) and isinstance(servers[0], str) and is_ip(servers[0]):
        print("split", domain, servers[0])
    else:
        print("invalid split", n)
' "$config" 2>/dev/null)"; then
        config_state=ok
        settings=("${(@f)settings}")
        [[ "${settings[1]:-}" == <1-65535> ]] && forwarder_port="${settings[1]}"
        health_url="${settings[2]:-}"
        for line in "${(@)settings[3,-1]}"; do
            case "$line" in
                upstream\ *) upstreams+=("${line#upstream }") ;;
                invalid\ upstream\ *) invalid_upstreams+=("${line#invalid upstream }") ;;
                split\ *|invalid\ split\ *) [[ -z "$split_dns" ]] && split_dns="$line" ;;
            esac
        done
    else
        config_state=unreadable
    fi
fi

system_local=false uses_conduit=false
[[ "$system_dns" == 127.* || "$system_dns" == ::1 ]] && system_local=true
# Conduit listens on 127.0.0.1 with its relay on 53, its forwarder, and the VPN override port.
[[ "$system_dns" == 127.0.0.1 && ( "$system_port" == 53 || "$system_port" == "$forwarder_port" || "$system_port" == 15353 ) ]] && uses_conduit=true
system_shown="$(shown "$system_dns" "$system_port")"
vpn_shown=()
for server port in "${(@)vpn_dns}"; do vpn_shown+=("$(shown "$server" "$port")"); done

echo "Conduit network probe  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  name=$name"
echo "  network  ${physical:-none}  ip ${address:-none}  gateway ${gateway:-none}  dns ${network_dns:-none}"
echo "  vpn      ${vpn:-none}${vpn:+  $($vpn_full && echo full || echo split) tunnel  default route ${default_interface:-none}}${vpn_shown:+  dns ${(j:,:)vpn_shown}}"
if [[ -z "$system_dns" ]]; then
    echo "  system   resolver none"
elif $uses_conduit; then
    echo "  system   resolver $system_shown (Conduit)"
elif $system_local; then
    echo "  system   resolver $system_shown (local, not Conduit's)"
else
    echo "  system   resolver $system_shown"
fi
[[ "$config_state" == unreadable ]] && echo "  config   Conduit config unreadable"
for n in $invalid_upstreams; do echo "  config   upstream #$n has an invalid host"; done
echo

# The physical network. On a full-tunnel VPN the client blocks traffic outside the tunnel, so these say nothing there.
if [[ -z "$address" ]]; then
    check link "Mac has a network address" fail "${physical:-no interface} has no IPv4 address"
elif $vpn_full; then
    check link "Mac has a network address" ok "$physical $address"
    for id label in gateway "gateway answers ping" network_dns "network's DNS answers" internet "direct HTTPS to 1.1.1.1 or 9.9.9.9" public_dns "public DNS 1.1.1.1 answers"; do
        check $id "$label" skip "the VPN carries all traffic"
    done
else
    check link "Mac has a network address" ok "$physical $address"
    if [[ -n "$gateway" ]] && ping -n -c 2 -t 3 -b "$physical" "$gateway" >/dev/null 2>&1; then
        check gateway "gateway answers ping" ok "$gateway"
    else
        check gateway "gateway answers ping" fail "${gateway:-no gateway} (some routers drop ping)"
    fi
    if [[ -n "$network_dns" ]]; then
        dns_check network_dns "network's DNS answers" "${network_dns%% *}" 53 "$address"
    else
        check network_dns "network's DNS answers" skip "DHCP gave no DNS server"
    fi
    # Two targets, so one blocked address is not read as a dead network.
    direct=""
    for target in 1.1.1.1 9.9.9.9; do
        code="$(curl -q --interface "$physical" --noproxy '*' -m 5 -s -o /dev/null -w '%{http_code}' "https://$target" 2>/dev/null)"
        if [[ "$code" == <100-599> ]]; then direct="$target HTTP $code"; break; fi
    done
    if [[ -n "$direct" ]]; then
        check internet "direct HTTPS to 1.1.1.1 or 9.9.9.9" ok "$direct"
    else
        check internet "direct HTTPS to 1.1.1.1 or 9.9.9.9" fail "no HTTP response from either in 5 s"
    fi
    dns_check public_dns "public DNS 1.1.1.1 answers" 1.1.1.1 53 "$address"
fi

if [[ -n "$vpn" ]]; then
    if (( $#vpn_dns )); then
        vpn_answer="" tried=()
        for server port in "${(@)vpn_dns[1,6]}"; do
            dns_query "$server" "$port" "$name"
            if [[ "$rcode" != timeout ]]; then vpn_answer="@$(shown "$server" "$port") $rcode"; break; fi
            tried+=("@$(shown "$server" "$port")")
        done
        if [[ -n "$vpn_answer" ]]; then
            check vpn_dns "VPN's DNS answers" ok "$vpn_answer"
        else
            check vpn_dns "VPN's DNS answers" fail "${(j:, :)tried} timeout"
        fi
    else
        check vpn_dns "VPN's DNS answers" skip "the VPN pushed no DNS server"
    fi
fi

# The corporate side, from Conduit's configuration. An upstream proxy that answers off the VPN means a corporate network;
# a 407 is an answer. Names here resolve through the system resolver, so on a network with dead DNS these fail too.
if [[ "$config_state" == unreadable ]]; then
    check corp_proxy "corporate proxy answers" skip "Conduit config unreadable"
elif (( $#upstreams )); then
    proxy_answered="" misses=() subset=""
    (( $#upstreams > 3 )) && subset="; tried the first 3 of $#upstreams"
    for upstream in "${(@)upstreams[1,3]}"; do
        reply="$(curl -q --noproxy '' -x "http://$upstream" -m 4 -s -o /dev/null -w '%{http_code} %{http_connect}' "${health_url:-http://www.apple.com/library/test/success.html}" 2>/dev/null)"
        curl_status=$?
        # Through a proxy, an HTTP URL gets the proxy's reply as the HTTP status, an HTTPS URL as the CONNECT status.
        for code in ${=reply}; do
            if [[ "$code" == <100-599> ]]; then proxy_answered="$upstream HTTP $code"; break 2; fi
        done
        if (( curl_status == 5 )); then misses+=("$upstream name does not resolve"); else misses+=("$upstream no answer in 4 s"); fi
    done
    if [[ -n "$proxy_answered" ]]; then
        check corp_proxy "corporate proxy answers" ok "$proxy_answered"
    elif [[ -n "$vpn" ]]; then
        check corp_proxy "corporate proxy answers" fail "${(j:, :)misses}$subset"
    else
        check corp_proxy "corporate proxy answers" skip "${(j:, :)misses}$subset: expected outside the corporate network"
    fi
else
    check corp_proxy "corporate proxy answers" skip "no valid upstream proxy configured"
fi
if [[ "$config_state" == unreadable ]]; then
    check corp_dns "internal DNS answers" skip "Conduit config unreadable"
elif [[ "$split_dns" == invalid\ split\ * ]]; then
    check corp_dns "internal DNS answers" skip "split-DNS entry #${split_dns##* } has a server that is not an IP address"
elif [[ -n "$split_dns" ]]; then
    entry=(${=split_dns#split })
    dns_query "${entry[2]}" 53 "${entry[1]}"
    rcodes[corp_dns]=$rcode
    if [[ "$rcode" != timeout ]]; then
        check corp_dns "internal DNS answers" ok "@${entry[2]} for ${entry[1]} $rcode"
    elif [[ -z "$vpn" && "${result[corp_proxy]}" != ok ]]; then
        check corp_dns "internal DNS answers" skip "@${entry[2]} timeout: expected outside the corporate network"
    else
        check corp_dns "internal DNS answers" fail "@${entry[2]} for ${entry[1]} timeout"
    fi
else
    check corp_dns "internal DNS answers" skip "no split-DNS entry configured"
fi

# Conduit's own layers, and the resolver apps actually use.
conduit_check() { # <id> <label> <port>: not answering is a failure only while the system resolver uses Conduit.
    dns_query 127.0.0.1 "$3" "$name"
    rcodes[$1]=$rcode
    if [[ "$rcode" != timeout ]]; then
        check "$1" "$2" ok "@127.0.0.1:$3 $rcode"
    elif $uses_conduit; then
        check "$1" "$2" fail "@127.0.0.1:$3 timeout"
    else
        check "$1" "$2" skip "@127.0.0.1:$3 timeout (the system resolver does not use Conduit)"
    fi
}
conduit_check forwarder "Conduit DNS forwarder answers" "$forwarder_port"
conduit_check relay "Conduit relay on :53 answers" 53
if [[ -n "$system_dns" ]]; then
    dns_query "$system_dns" "$system_port" "$name"
    rcodes[system]=$rcode
    if [[ "$rcode" == NOERROR ]] && (( addresses )); then
        check system "system resolver resolves the name" ok "@$system_shown NOERROR, A records: $addresses"
    elif [[ "$rcode" == NOERROR ]]; then
        check system "system resolver resolves the name" fail "@$system_shown NOERROR with no address"
    else
        check system "system resolver resolves the name" fail "@$system_shown $rcode"
    fi
else
    check system "system resolver resolves the name" fail "no default resolver configured"
fi

echo
failed() { [[ "${result[$1]}" == fail ]] }
answered() { [[ "${result[$1]}" == ok ]] }
# Something past this network's own DNS server answered, so the network does carry traffic.
reaches_beyond() { answered corp_proxy || answered corp_dns || answered vpn_dns }
data_path() { answered internet || answered corp_proxy || { $vpn_full && answered vpn_dns } }
case "${rcodes[system]:-}" in
    timeout) system_result="does not answer" ;;
    NOERROR) system_result="answers with no address for $name" ;;
    *) system_result="answers ${rcodes[system]} for $name" ;;
esac
direct="direct HTTPS to 1.1.1.1 and 9.9.9.9 and public DNS 1.1.1.1"
if failed link; then
    verdict="No network connection: ${detail[link]}. Join a network first."
elif ! $vpn_full && failed internet && failed public_dns && ! reaches_beyond; then
    if answered network_dns; then
        verdict="This network is not reaching the internet: $direct all fail, and only its own DNS server answers, maybe from a cache. Switch networks or restart the hotspot or router. Restarting the Mac or Conduit will not help."
    else
        verdict="This network is not passing traffic: $direct all fail. Switch networks or restart the hotspot or router. Restarting the Mac or Conduit will not help."
    fi
elif $vpn_full && failed vpn_dns && failed system && ! answered corp_proxy; then
    verdict="The VPN's DNS servers do not answer, so the tunnel is not carrying traffic. Reconnect the VPN, or disconnect it if the network underneath changed."
elif answered system && ! data_path; then
    if $vpn_full; then
        verdict="Names resolve, maybe from a cache, but neither the VPN's DNS servers nor a corporate proxy answer through the tunnel. Reconnect the VPN."
    else
        verdict="Names resolve, maybe from a cache, but neither direct HTTPS to 1.1.1.1 and 9.9.9.9 nor a corporate proxy gets through, so this network is not passing web traffic."
    fi
elif answered system && failed corp_proxy; then
    verdict="Names resolve, but no corporate proxy answers through the VPN, so corporate sites may fail."
elif answered system && failed vpn_dns; then
    verdict="Names resolve, but the VPN's DNS servers do not answer, so internal names may fail."
elif answered system && failed corp_dns; then
    verdict="Names resolve, but the internal DNS server does not answer, so internal names may fail."
elif answered system; then
    verdict="Names resolve and the network passes traffic."
elif [[ -z "$system_dns" ]]; then
    verdict="No default resolver is configured, so apps cannot resolve names. Use Restore DNS Settings in Conduit, or set a DNS server for this network."
elif $uses_conduit && [[ "${rcodes[forwarder]}" == timeout ]]; then
    verdict="The system resolver points at Conduit, and Conduit's DNS forwarder is not answering. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
elif $uses_conduit && [[ "${rcodes[system]}" == SERVFAIL ]]; then
    verdict="The system resolver points at Conduit ($system_shown), which answers but reports that its upstream DNS failed (SERVFAIL). Conduit is running; the DNS servers it forwards to are failing, so see the network's and the VPN's DNS checks above."
elif $uses_conduit && [[ "${rcodes[system]}" == timeout ]]; then
    verdict="The system resolver points at Conduit ($system_shown) and gets no answer, though the forwarder answers directly. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
elif $system_local && ! $uses_conduit; then
    verdict="The system resolver $system_shown is a local resolver that is not Conduit's, and it $system_result. Check the program that serves it."
elif ! $vpn_full && answered internet && failed network_dns; then
    verdict="The network passes traffic but its DNS server does not answer. Use another DNS server, or let Conduit manage DNS."
else
    verdict="The system resolver $system_shown $system_result."
fi
if [[ -n "$vpn" ]]; then
    location="VPN"
    $vpn_full || location="VPN (split tunnel on $vpn)"
elif [[ "$config_state" == unreadable ]]; then
    location="unknown (Conduit config unreadable)"
elif answered corp_proxy; then
    location="corporate network (experimental: a corporate proxy answers without the VPN)"
elif answered corp_dns; then
    location="unknown (the internal DNS server answers directly, but no corporate proxy does)"
elif (( ! $#upstreams )) && [[ "$split_dns" != split\ * ]]; then
    location="unknown (no corporate proxy or internal DNS server configured)"
else
    location="outside the corporate network"
fi
echo "Location: $location"
echo "Verdict: $verdict"
[[ "$verdict" == "Names resolve and the network passes traffic." ]] && exit 0 || exit 2
