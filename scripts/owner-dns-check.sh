#!/bin/zsh
# Read-only snapshot of the DNS state for decisions 0049/0050; never writes.
set -u
key=State:/Network/Service/com.cisco.anyconnect/DNS
echo "== $(date '+%H:%M:%S')  primary: $(echo 'show State:/Network/Global/IPv4' | scutil | awk '/PrimaryInterface/{print $3}')"
echo "-- resolver #1: $(scutil --dns | awk '/^resolver #1/{f=1;next} f&&/^resolver/{exit} f&&/nameserver/{printf "%s ",$3}')"
if echo "show $key" | scutil | grep -q "No such key"; then
  echo "-- VPN DNS key: absent (expected only while the VPN is disconnected)"
else
  echo "-- VPN DNS key servers: $(echo "show $key" | scutil | awk '/[0-9]+ : [0-9a-f.:]+$/{printf "%s ",$3}')"
fi
for n in github.com api.anthropic.com "$@"; do
  printf "   %-28s %s\n" "$n" "$(dscacheutil -q host -a name "$n" | awk '/address/{n++} END{print (n?n" addresses":"FAILED")}')"
done
printf "   %-28s %s\n" "tcp:53 large answer" "$(dig +tcp +time=3 +tries=1 @127.0.0.1 ${1:-github.com} A 2>/dev/null | grep -o 'status: [A-Z]*' || echo FAILED)"
echo "-- last override/fallback events:"
python3 - "$HOME/Library/Application Support/Conduit/events.ndjson" <<'EOF'
import sys, json, datetime
rows = []
try:
    for line in open(sys.argv[1]):
        try: e = json.loads(line)
        except ValueError: continue
        ev = e.get("event", "")
        if ev.startswith(("dns.vpn_override", "dns.network_resolver", "dns.resolution_recovered", "vpn.connected", "vpn.disconnected", "vpn.flap.start")):
            t = datetime.datetime.fromtimestamp(float(e.get("timestamp", 0))).strftime("%m-%d %H:%M:%S")
            rows.append(f"   {t} {ev} {(e.get('detail') or '')[:110]}")
except OSError as error:
    rows.append(f"   events unreadable: {error}")
print("\n".join(rows[-12:]))
EOF
