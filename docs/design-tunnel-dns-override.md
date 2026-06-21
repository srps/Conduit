# Design: Tunnel DNS Override for TLS/SNI

## Problem

Protocol tunnels (`TunnelForwarder`) map a local TCP port to a remote host via HTTP CONNECT through the corporate proxy. When the tunneled protocol uses TLS (MongoDB, PostgreSQL with `sslmode=require`, Redis TLS, etc.), the client must connect using the **real hostname** so that:

1. **SNI** (Server Name Indication) in the TLS ClientHello matches the server's certificate.
2. The client validates the returned certificate against the hostname it intended to connect to.

If the client connects to `localhost:27017` (the tunnel listen address), SNI = "localhost" and cert validation fails against `*.mongodb.net`.

## Solution

The tunnel module owns its DNS override end-to-end. No dependency on the DNS forwarder module.

### Components

**`TunnelDNSResponder`** (`Sources/ProxyKernel/Proxy/TunnelDNSResponder.swift`)

Minimal UDP DNS server using NIO `DatagramBootstrap`:
- Binds `127.0.0.1:15053` (high port, no privilege)
- Maintains a `NIOLockedValueBox<[String: String]>` mapping `hostname → listenIP`
- A query match → synthesize A record with tunnel's listen IP (5s TTL)
- AAAA query match → NODATA (rcode 0, 0 answers) to suppress IPv6 delays
- No match → REFUSED (rcode 5, macOS resolver falls through to next DNS source)

**`TunnelResolverManager`** (`Sources/PlatformMac/TunnelResolverManager.swift` — moved from `Sources/ConduitCore/System/` during the module split; the kernel-side `TunnelResolverApplying` protocol in `Sources/ProxyKernel/Abstractions/` is the seam `TunnelForwarder` calls through)

Manages `/etc/resolver/<hostname>` files via the existing `PrivilegeClient` protocol:
- `apply(hostname:listenIP:)` → `privilegeClient.execute(.applyDNS, [hostname, ip, "15053"])`
- `remove(hostname:)` → `privilegeClient.execute(.removeDNS, [hostname])`
- `cleanupStale(activeHostnames:)` → scans `/etc/resolver/` for files containing `port 15053`, removes orphans not in the active set

**`DNSWireFormat.synthesizeDirectResponse`** (`Sources/ProxyKernel/Network/DNSWireFormat.swift`)

New helper that creates a DNS response for a given IP without JSON round-trip:
- A queries: synthesize answer with 4-byte IPv4 address, 5s TTL
- AAAA queries: synthesize NODATA (rcode 0, empty answer section)
- Other qtypes: REFUSED

### Helper Change

The existing `applyDNS` command takes `[domain, "ip1,ip2"]`. Extended with an optional third value: `[domain, "ip", "15053"]`. Both `HelperTool.swift` and `AppleScriptPrivilegeClient` check for the third element and append `port <value>` if present. No new `HelperCommand` enum cases. Fully backward-compatible — existing split DNS calls pass 2 values as before.

## Data Flow

```
mongosh → getaddrinfo("cluster0.mongodb.net")
       → macOS resolver checks /etc/resolver/cluster0.mongodb.net
       → nameserver 127.0.0.1 port 15053
       → TunnelDNSResponder returns A 127.0.0.1
       → mongosh connects to 127.0.0.1:27017 (tunnel listen port)
       → TunnelForwarder establishes CONNECT cluster0.mongodb.net:27017
       → TLS ClientHello SNI = "cluster0.mongodb.net" ✓
       → Server cert for *.mongodb.net matches ✓
```

## Module Independence

```
Tunnel Module                DNS Module              Proxy Module
├── TunnelForwarder          ├── LocalDNSForwarder   ├── LocalProxyServer
├── TunnelDNSResponder       └── (independent)       └── (independent)
└── TunnelResolverManager
    └── PrivilegeClient (protocol)
        └── Existing Helper
```

No imports or data flow between modules. `AppState` starts/stops each independently.

### Conflict with DNS Forwarder

| State | Behavior |
|-------|----------|
| DNS forwarder running (system DNS = 127.0.0.1:53) | `/etc/resolver/<host>` takes priority for its domain → mini-DNS. Other queries → forwarder. No conflict. |
| DNS forwarder not running | `/etc/resolver/<host>` → mini-DNS. Other queries → corporate DNS. No conflict. |
| Both stopped | Resolver files removed, mini-DNS stopped. Clean. |

## Progressive Capability Tiers

| Tier | Condition | Behavior |
|------|-----------|----------|
| 1 | Helper installed | Fully transparent. Resolver files created silently. When `localPort == remotePort`, user uses normal connection strings. When ports differ, client connects to `hostname:localPort`. |
| 2 | No helper, admin access | AppleScript fallback prompts once for admin password. Then transparent (same port rules as tier 1). |
| 3 | No helper, no admin | TCP tunnel works. DNS override unavailable. UI shows SOCKS5 connection strings and /etc/hosts guidance with copy buttons. |

## Privilege Surface

No new helper commands. Tunnel DNS uses 2 of 11 existing commands:
- `applyDNS` (with optional port) — writes `/etc/resolver/<domain>`
- `removeDNS` — deletes `/etc/resolver/<domain>`

## UI Integration

**Module card** (MainView): secondary metric shows DNS override status:
- "DNS override: N hosts" when active
- "DNS override unavailable" when failed

**Tunnel settings** (SettingsView): per-definition guidance section:
- When DNS override active and `localPort == remotePort`: green checkmark, "use your normal connection string"
- When DNS override active but `localPort != remotePort`: green checkmark with explicit `hostname:localPort` guidance (DNS rewrites hostname but not port; client must connect to the tunnel's listen port)
- When unavailable: SOCKS5 connection string (with copy button) for MongoDB, `/etc/hosts` entry (with copy button) for all protocols

## Testing

11 tests in `TunnelDNSResponderTests.swift`:
- Responder A record for registered hostname
- Responder NODATA for AAAA
- Responder REFUSED for unknown hostname
- Case-insensitive lookup
- Dynamic hostname updates
- `synthesizeDirectResponse` A record wire format
- `synthesizeDirectResponse` AAAA NODATA
- `synthesizeDirectResponse` invalid IP
- ResolverManager `applyDNS` with port parameter
- ResolverManager `removeDNS`
- ResolverManager `applyAll` success/failure tracking

## Future: Network Extension

When the app is signed with Apple Developer ID, `NEDNSProxyProvider` can replace both `TunnelDNSResponder` and `TunnelResolverManager`. The NE provider intercepts DNS queries in userspace without `/etc/resolver/` files or the helper. The hostname override data structure stays the same — only the interception mechanism changes.
