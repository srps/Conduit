#!/bin/zsh
# Probes each layer between this Mac and the internet, using IP addresses only so it works while DNS is down,
# and names the first layer that fails. Read-only: it changes no setting and needs no sudo.
#
# Usage: ./scripts/probe-network.sh [--name HOST]
# It also asks Conduit's enabled upstream proxies, in priority order, and its first split-DNS server, and guesses
# whether this is the VPN, a corporate network or outside. The guess is experimental and says unknown when the
# answers are ambiguous. It comes from which configured endpoints answer, not from routes. CONDUIT_CONFIG names
# another config.json.
# Exit status: 0 when names resolve and a web request completed, 1 when nothing failed but no web request could be
# verified, 2 when a check fails, 64 on a usage error. It has no overall deadline; it takes about 50 s at worst.
# It diagnoses IPv4 only, and says so on a network with only IPv6. The system check queries up to 3 of the default
# resolver's servers directly with dig, which gives up on each after 2 s. It does not go through the macOS resolver,
# so apps can get a cached or supplemental answer that this check does not see.
emulate -L zsh
setopt pipefail

name=www.apple.com
while (( $# )); do
    case "$1" in
        --name) [[ -n "${2:-}" ]] || { echo "--name needs a host" >&2; exit 64 }; name="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    out="$(HOME=/var/empty dig +time=2 +tries=1 +ignore +noall +comments +answer $source -p "$2" "@$1" -q "$3" -t A 2>&1)"
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
address="" gateway="" network_dns="" has_ipv6=false
if [[ -n "$physical" ]]; then
    address="$(ipconfig getifaddr "$physical" 2>/dev/null)"
    gateway="$(ipconfig getoption "$physical" router 2>/dev/null)"
    network_dns="$(ipconfig getoption "$physical" domain_name_server 2>/dev/null)"
    print -r -- "$nwi" | awk -v ifname="$physical" '
        /^IPv6 network interface information/ { v6 = 1; next }
        /^(IPv4 network interface information|Network interfaces:)/ { v6 = 0 }
        v6 && $1 == ifname && $2 == ":" { found = 1 }
        END { exit !found }' && has_ipv6=true
fi

# The default resolver apps use: resolver #1 of the unscoped configuration, which scutil prints first.
system_servers=(${=$(print -r -- "$dns_config" | awk '
    /^resolver #1$/ { r = 1; next }
    r && /^$/ { exit }
    r && $1 ~ /^nameserver\[/ { servers[++n] = $3 }
    r && $1 == "port" { port = $3 }
    END { for (i = 1; i <= n; i++) print servers[i], (port ? port : 53) }')}) # server and port pairs, in resolver order
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

forwarder_port=5053 config_state=none manages_dns=false health_invalid=false
upstreams=() invalid_upstreams=() split_dns=() health_url=""
config="${CONDUIT_CONFIG:-$HOME/Library/Application Support/Conduit/config.json}"
if [[ -e "$config" ]]; then
    # One tab-separated line per field. Hosts, servers and the URL are checked here, so nothing else from the files
    # reaches the output or a command line. Manage system DNS lives in platform.json, or in config.json before it.
    if settings="$(python3 -I -B -c '
import ipaddress, json, os, re, stat, sys
from urllib.parse import urlsplit

def load(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        return json.load(f)

def is_ip(s):
    # Scope text after % is free-form, so a scoped address is refused rather than printed.
    try:
        return "%" not in s and bool(ipaddress.ip_address(s))
    except ValueError:
        return False

def is_url(s):
    try:
        u = urlsplit(s)
        return (s.isprintable() and u.scheme in ("http", "https") and bool(u.hostname) and "@" not in u.netloc
                and "%" not in u.hostname)
    except ValueError:
        return False

c = load(sys.argv[1])
try:
    manage = load(sys.argv[2]).get("manageSystemDNS")
except FileNotFoundError:
    manage = c.get("manageSystemDNS")
except (OSError, ValueError, AttributeError):
    manage = None
if manage is True:
    print("manage")
port, url = c.get("dnsForwarderPort"), c.get("healthCheckURL")
if isinstance(port, int):
    print("port", port, sep="\t")
if isinstance(url, str) and is_url(url):
    # Quoted for the curl config syntax: curl reads the URL from stdin, so a token in it never shows in ps.
    print("health", url.replace("\\", "\\\\").replace("\"", "\\\""), sep="\t")
elif url:
    print("health-invalid")
ordered = []
for n, u in enumerate(c.get("upstreams", []), 1):
    host, port, priority = u.get("host"), u.get("port"), u.get("priority")
    if not u.get("enabled", True) or not host or not port:
        continue
    if isinstance(host, str) and (re.fullmatch(r"[A-Za-z0-9.-]+", host) or is_ip(host)) and isinstance(port, int) and 0 < port < 65536:
        ordered.append((priority if isinstance(priority, int) else sys.maxsize, n, ("[%s]:%d" if ":" in host else "%s:%d") % (host, port)))
    else:
        print("invalid-upstream", n, sep="\t")
for _, _, endpoint in sorted(ordered):
    print("upstream", endpoint, sep="\t")
for n, e in enumerate(c.get("dnsEntries", []), 1):
    domain, servers = e.get("domain"), e.get("servers")
    if not e.get("enabled", True) or not domain or not servers:
        continue
    if isinstance(domain, str) and re.fullmatch(r"[A-Za-z0-9.*_-]+", domain) and isinstance(servers[0], str) and is_ip(servers[0]):
        print("split", domain, servers[0], sep="\t")
    else:
        print("invalid-split", n, sep="\t")
' "$config" "${config:h}/platform.json" 2>/dev/null)"; then
        config_state=ok
        for line in "${(@f)settings}"; do
            fields=("${(@ps:\t:)line}")
            case "${fields[1]}" in
                manage) manages_dns=true ;;
                port) [[ "${fields[2]}" == <1-65535> ]] && forwarder_port="${fields[2]}" ;;
                health) health_url="${fields[2]}" ;;
                health-invalid) health_invalid=true ;;
                upstream) upstreams+=("${fields[2]}") ;;
                invalid-upstream) invalid_upstreams+=("${fields[2]}") ;;
                split|invalid-split) (( $#split_dns )) || split_dns=("${(@)fields}") ;;
            esac
        done
    else
        config_state=unreadable
    fi
fi

# Sets system_dns, system_port and system_shown to one of the default servers, and whether it is local or Conduit's.
select_system() { # <server> <port>
    system_dns="$1" system_port="$2" system_shown="$(shown "$1" "$2")" system_local=false uses_conduit=false
    [[ "$system_dns" == 127.* || "$system_dns" == ::1 ]] && system_local=true
    # Conduit listens on 127.0.0.1 with its relay on 53, its forwarder, and the VPN override port. Another program can
    # listen there too, so the resolver is Conduit's only while Conduit is set to manage system DNS.
    [[ "$system_dns" == 127.0.0.1 && ( "$system_port" == 53 || "$system_port" == "$forwarder_port" || "$system_port" == 15353 ) ]] &&
        $manages_dns && uses_conduit=true
}
select_system "${system_servers[1]:-}" "${system_servers[2]:-53}"
system_list=() vpn_shown=()
for server port in "${(@)system_servers}"; do system_list+=("$(shown "$server" "$port")"); done
for server port in "${(@)vpn_dns}"; do vpn_shown+=("$(shown "$server" "$port")"); done

echo "Conduit network probe  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  name=$name"
echo "  network  ${physical:-none}  ip ${address:-none}  gateway ${gateway:-none}  dns ${network_dns:-none}"
echo "  vpn      ${vpn:-none}${vpn:+  $($vpn_full && echo full || echo split) tunnel  default route ${default_interface:-none}}${vpn_shown:+  dns ${(j:,:)vpn_shown}}"
if [[ -z "$system_dns" ]]; then
    echo "  system   resolver none"
elif $uses_conduit; then
    echo "  system   resolver ${(j:,:)system_list} (Conduit)"
elif $system_local; then
    echo "  system   resolver ${(j:,:)system_list} (local)"
else
    echo "  system   resolver ${(j:,:)system_list}"
fi
[[ "$config_state" == unreadable ]] && echo "  config   Conduit config unreadable"
for n in $invalid_upstreams; do echo "  config   upstream #$n has an invalid host"; done
$health_invalid && echo "  config   health-check URL is not a plain http(s) URL, so the default is used"
echo

# The physical network. On a full-tunnel VPN the client blocks traffic outside the tunnel, so these say nothing there.
if [[ -z "$address" ]]; then
    if $has_ipv6; then
        check link "Mac has a network address" skip "$physical has IPv6 only, and this probe diagnoses IPv4"
    else
        check link "Mac has a network address" fail "${physical:-no interface} has no IPv4 address"
    fi
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
        code="$(env -u SSLKEYLOGFILE curl -q --interface "$physical" --noproxy '*' -m 5 -s -o /dev/null -w '%{http_code}' \
            "https://$target" 2>/dev/null)"
        if (( $? == 0 )) && [[ "$code" == <100-599> ]]; then direct="$target HTTP $code"; break; fi
    done
    if [[ -n "$direct" ]]; then
        check internet "direct HTTPS to 1.1.1.1 or 9.9.9.9" ok "$direct"
    else
        check internet "direct HTTPS to 1.1.1.1 or 9.9.9.9" fail "no complete HTTP response from either in 5 s"
    fi
    dns_check public_dns "public DNS 1.1.1.1 answers" 1.1.1.1 53 "$address"
fi

vpn_tried=0
if [[ -n "$vpn" ]]; then
    if (( $#vpn_dns )); then
        vpn_answer="" tried=()
        for server port in "${(@)vpn_dns[1,6]}"; do
            dns_query "$server" "$port" "$name"
            if [[ "$rcode" != timeout ]]; then vpn_answer="@$(shown "$server" "$port") $rcode"; break; fi
            tried+=("@$(shown "$server" "$port")")
        done
        vpn_tried=$#tried
        if [[ -n "$vpn_answer" ]]; then
            check vpn_dns "VPN's DNS answers" ok "$vpn_answer"
        else
            check vpn_dns "VPN's DNS answers" fail "${(j:, :)tried} timeout"
        fi
    else
        check vpn_dns "VPN's DNS answers" skip "the VPN pushed no DNS server"
    fi
fi

# The corporate side, from Conduit's configuration. An upstream proxy that answers off the VPN means a corporate network.
# A 407 or a CONNECT reply shows only that the proxy answered; a request through it completes when the destination
# replies, which needs a final status after CONNECT 200, or a 2xx or 3xx for an HTTP URL. Proxies are tried in order
# until a request through one completes, and the first that answers is reported when none does.
# Names here resolve through the system resolver, so on a network with dead DNS these fail too.
proxy_passes=false proxy_silent=false proxies_tried=0
if [[ "$config_state" == unreadable ]]; then
    check corp_proxy "corporate proxy answers" skip "Conduit config unreadable"
elif (( $#upstreams )); then
    proxy_answered="" misses=() subset=""
    (( $#upstreams > 3 )) && subset="; tried the first 3 by priority of $#upstreams"
    for upstream in "${(@)upstreams[1,3]}"; do
        (( proxies_tried++ ))
        # -g keeps curl from reading the URL as a glob pattern.
        reply="$(print -r -- "url = \"${health_url:-http://www.apple.com/library/test/success.html}\"" |
            env -u SSLKEYLOGFILE curl -q -K - -g --noproxy '' -x "http://$upstream" -m 4 -s -o /dev/null \
            -w '%{http_connect} %{http_code}' 2>/dev/null)"
        curl_status=$?
        connect="${reply%% *}" code="${reply#* }" answer=""
        [[ "$connect" == <100-599> ]] && answer+=" CONNECT $connect"
        [[ "$code" == <100-599> ]] && answer+=" HTTP $code"
        if [[ -n "$answer" ]]; then
            if (( curl_status == 0 )) && [[ "$connect" == 200 || ( "$connect" != <100-599> && "$code" == <200-399> ) ]]; then
                proxy_passes=true proxy_answered="$upstream$answer, a request through it completed"
                break
            fi
            if [[ -z "$proxy_answered" ]]; then
                proxy_answered="$upstream$answer, no request through it completed"
                (( curl_status )) && proxy_answered+=" (curl exit $curl_status)"
            fi
            continue
        fi
        if (( curl_status == 5 )); then
            misses+=("$upstream name does not resolve")
        else
            misses+=("$upstream no answer in 4 s") proxy_silent=true
        fi
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
elif [[ "${split_dns[1]:-}" == invalid-split ]]; then
    check corp_dns "internal DNS answers" skip "split-DNS entry #${split_dns[2]} has a server that is not an IP address"
elif (( $#split_dns )); then
    split_domain="${split_dns[2]}" split_server="${split_dns[3]}"
    dns_query "$split_server" 53 "$split_domain"
    rcodes[corp_dns]=$rcode
    if [[ "$rcode" != timeout ]]; then
        check corp_dns "internal DNS answers" ok "@$split_server for $split_domain $rcode"
    elif [[ -z "$vpn" && "${result[corp_proxy]}" != ok ]]; then
        check corp_dns "internal DNS answers" skip "@$split_server timeout: expected outside the corporate network"
    else
        check corp_dns "internal DNS answers" fail "@$split_server for $split_domain timeout"
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
    # The next server is asked only when one does not answer, so the first answer stands for the resolver.
    tried=()
    for server port in "${(@)system_servers[1,6]}"; do
        dns_query "$server" "$port" "$name"
        tried+=("$(shown "$server" "$port")")
        if [[ "$rcode" != timeout ]]; then select_system "$server" "$port"; break; fi
    done
    rcodes[system]=$rcode
    if [[ "$rcode" == NOERROR ]] && (( addresses )); then
        check system "system resolver resolves the name" ok "@$system_shown NOERROR, A records: $addresses"
    elif [[ "$rcode" == NOERROR ]]; then
        check system "system resolver resolves the name" fail "@$system_shown NOERROR with no address"
    elif [[ "$rcode" == timeout ]]; then
        system_shown="${(j:, :)tried}"
        check system "system resolver resolves the name" fail "@${(j:, @:)tried} timeout"
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
web_request() { answered internet || $proxy_passes }
case "${rcodes[system]:-}" in
    timeout) system_result="does not answer" ;;
    NOERROR) system_result="answers with no address for $name" ;;
    *) system_result="answered with ${rcodes[system]} for $name" ;;
esac
direct="direct HTTPS to 1.1.1.1 and 9.9.9.9 and public DNS 1.1.1.1"
proxies_failed=""
(( proxies_tried )) && proxies_failed=", and none of the $proxies_tried corporate proxies tried answers"
exit_code=2
if failed link; then
    verdict="No network connection: ${detail[link]}. Join a network first."
elif [[ "${result[link]}" == skip ]]; then
    exit_code=1 verdict="IPv4 diagnostics unavailable: ${detail[link]}."
elif $uses_conduit && [[ "${rcodes[system]}" == timeout ]]; then
    if [[ "${rcodes[forwarder]}" == timeout ]]; then
        verdict="The system resolver points at Conduit, and Conduit's DNS forwarder is not answering. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
    else
        verdict="The system resolver points at Conduit ($system_shown) and gets no answer, though the forwarder answers directly. Use Restore DNS Settings in Conduit, or turn off Manage system DNS."
    fi
    failed internet && failed public_dns &&
        verdict+=" Whether this network reaches the internet is inconclusive: $direct also fail, which a network that blocks direct traffic causes too."
elif ! $vpn_full && failed internet && failed public_dns && ! reaches_beyond; then
    if answered network_dns && { ! answered system || [[ "$system_dns" == "${network_dns%% *}" ]] }; then
        verdict="This network is not reaching the internet: $direct all fail, and only its own DNS server answers, maybe from a cache. Switch networks or restart the hotspot or router. Restarting the Mac or Conduit will not help."
    elif ! answered system; then
        verdict="This network is not passing traffic: $direct all fail. Switch networks or restart the hotspot or router. Restarting the Mac or Conduit will not help."
    else
        verdict="Inconclusive: names resolve through $system_shown, but $direct all fail. This network may block those addresses, or the answer came from a cache."
    fi
elif $vpn_full && failed vpn_dns && failed system && ! answered corp_proxy && ! answered corp_dns; then
    verdict="The VPN's DNS servers do not answer (none of the $vpn_tried tried), and the system resolver $system_shown $system_result."
    if $proxy_silent || failed corp_dns; then
        verdict+=" No corporate endpoint answers through the tunnel either, so it may not be carrying traffic. Reconnect the VPN, or disconnect it if the network underneath changed."
    else
        verdict+=" Whether the tunnel carries traffic is unverified: no check independent of DNS ran through it. Reconnect the VPN if this persists."
    fi
elif answered system && ! web_request && ! answered corp_proxy && ! $vpn_full && failed internet; then
    verdict="Names resolve, maybe from a cache, but no web request got through: direct HTTPS to 1.1.1.1 and 9.9.9.9 fails$proxies_failed."
elif answered system && $vpn_full && failed corp_proxy && ! answered vpn_dns && ! answered corp_dns; then
    verdict="Names resolve, maybe from a cache, but neither the VPN's DNS servers nor a corporate proxy answer through the tunnel (none of the $proxies_tried tried). Reconnect the VPN."
elif answered system && failed corp_proxy; then
    verdict="Names resolve, but no corporate proxy answers through the VPN (none of the $proxies_tried tried), so corporate sites may fail."
elif answered system && failed vpn_dns; then
    verdict="Names resolve, but the VPN's DNS servers do not answer, so internal names may fail."
elif answered system && failed corp_dns; then
    verdict="Names resolve, but the internal DNS server does not answer, so internal names may fail."
elif answered system && web_request; then
    exit_code=0 verdict="Names resolve and the network passes traffic."
elif answered system && answered corp_proxy; then
    exit_code=1 verdict="Names resolve and the network reaches the corporate proxy, but no request through it completed, so web traffic is unverified."
elif answered system; then
    exit_code=1 verdict="Names resolve, but web traffic through the tunnel is unverified: ${detail[corp_proxy]}."
elif [[ -z "$system_dns" ]]; then
    verdict="No default resolver is configured, so apps cannot resolve names. Use Restore DNS Settings in Conduit, or set a DNS server for this network."
elif $uses_conduit && [[ "${rcodes[system]}" == SERVFAIL ]]; then
    verdict="The system resolver points at Conduit ($system_shown), which answered with SERVFAIL, so it or a DNS server it forwards to failed. See the network's and the VPN's DNS checks above."
    [[ "${rcodes[forwarder]}" == timeout ]] && verdict+=" Conduit's DNS forwarder on :$forwarder_port does not answer directly."
elif $system_local && ! $uses_conduit; then
    verdict="The system resolver $system_shown is a local resolver, and it $system_result. Check the program that serves it."
elif ! $vpn_full && answered internet && [[ "${rcodes[system]}" == timeout && "$system_shown" == "${network_dns%% *}" ]]; then
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
elif (( ! $#upstreams )) && [[ "${split_dns[1]:-}" != split ]]; then
    location="unknown (no corporate proxy or internal DNS server configured)"
elif ! answered internet; then
    location="unknown (no corporate endpoint answers, but direct internet traffic does not get through either)"
else
    location="outside the corporate network (experimental: direct traffic gets through and no corporate endpoint answers)"
fi
echo "Location: $location"
echo "Verdict: $verdict"
exit $exit_code
