# Design: DNS Intercept + Transparent TCP Proxy

## Problem

Applications that use Node.js `http2.connect()` (or any HTTP client that bypasses `HTTP_PROXY`) fail to reach external servers when the only network path is through a corporate proxy. DNS resolution fails locally, and even if it succeeded, the IPs are not routable without the proxy.

## Solution

Add a **DNS intercept** capability to Conduit's existing DNS forwarder module, combined with a **transparent TCP proxy** that uses SNI extraction to determine the real destination and tunnels through the corporate proxy.

No new dependencies required. No TLS termination. No HTTP/2 parsing. End-to-end encryption is preserved.

## Architecture

```
Application (e.g., Cursor http2.connect)
    │
    ▼ DNS query: api2.cursor.sh → ?
┌─────────────────────────────────────┐
│  LocalDNSForwarder (existing)       │
│  ┌───────────────────────────────┐  │
│  │ NEW: Intercept check          │  │
│  │ "*.cursor.sh" in intercept    │  │
│  │ list → return 127.44.3.0     │  │
│  └───────────────────────────────┘  │
│  (else: forward to corporate DNS /  │
│   DoH as before)                    │
└─────────────────────────────────────┘
    │
    ▼ TCP connect to 127.44.3.0:443
┌─────────────────────────────────────┐
│  NEW: TransparentTCPProxy           │
│  Binds 127.44.3.0:443              │
│  ┌───────────────────────────────┐  │
│  │ 1. Accept connection          │  │
│  │ 2. Peek first bytes (≤512)    │  │
│  │ 3. Parse TLS ClientHello SNI  │  │
│  │    → "api2.cursor.sh"         │  │
│  │ 4. CONNECT tunnel via         │  │
│  │    CONNECTCoordinator         │  │
│  │    (reuses existing infra)    │  │
│  │ 5. Forward peeked bytes +     │  │
│  │    bidirectional relay        │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
    │
    ▼ CONNECT api2.cursor.sh:443 + NTLM auth
┌─────────────────────────────────────┐
│  Corporate Proxy (existing path)    │
└─────────────────────────────────────┘
    │
    ▼ TCP tunnel (raw bytes)
┌─────────────────────────────────────┐
│  api2.cursor.sh:443 (origin)        │
│  TLS + HTTP/2 end-to-end            │
└─────────────────────────────────────┘
```

## Components

### 1. DNS Intercept Rules (change to existing code)

**File**: `LocalDNSForwarder.swift` / `DNSForwardingHandler`

**Config model addition** (`ProxyConfig`):
```swift
package var dnsInterceptRules: [DNSInterceptRule]

package struct DNSInterceptRule: Codable, Hashable, Identifiable {
    package var id: UUID
    package var pattern: String       // e.g., "*.cursor.sh"
    package var interceptIP: String   // default: "127.44.3.0"
    package var enabled: Bool
}
```

**Default**: `interceptIP = "127.44.3.0"` (a dedicated loopback address that won't conflict with `127.0.0.1` dev servers).

**Change in `DNSForwardingHandler.channelRead`**: Before the existing `isInternal` / DoH forwarding logic, check if the queried domain matches any enabled intercept rule. If so, synthesize a response with the `interceptIP` using the existing `DNSWireFormat.synthesizeDNSResponse` infrastructure (needs a small helper to produce a response for a given IP without a JSON round-trip).

**Estimated change**: ~30 lines in `DNSForwardingHandler`, ~15 lines in `DNSWireFormat` for a `synthesizeDirectResponse(originalQuery:ip:)` helper, ~10 lines in `ProxyConfig`.

### 2. Transparent TCP Proxy (new module)

**New file**: `TransparentTCPProxy.swift` in `Sources/ProxyKernel/Proxy/` (originally landed in `Sources/ConduitCore/Proxy/`; renamed during the module split).

**Architecture**: Follows the same pattern as `TunnelForwarder.swift`:
- `ServerBootstrap` binding `interceptIP:443` (or configurable port)
- On accept: `SNIExtractHandler` → `TransparentTunnelHandler`

**SNI Extraction**: A `ByteToMessageDecoder`-like handler that:
1. Accumulates the first bytes of the connection (up to 512 bytes)
2. Parses the TLS ClientHello to extract the SNI hostname
3. Removes itself from the pipeline and passes the buffered bytes + hostname to the tunnel handler

The TLS ClientHello SNI is at a well-defined offset:
```
ContentType (1) | Version (2) | Length (2) |
  HandshakeType (1) | Length (3) | Version (2) | Random (32) |
  SessionID length (1) | SessionID (var) |
  CipherSuites length (2) | CipherSuites (var) |
  Compression length (1) | Compression (var) |
  Extensions length (2) |
    Extension: type (2) | length (2) | data (var)
    ... find type 0x0000 (server_name) → extract hostname
```

This is ~100 lines of pure byte parsing, no dependencies.

**Tunnel establishment**: Once SNI is extracted:
1. Call `CONNECTCoordinator.connectUpstreamTunnel(target: "\(sniHost):443")`
2. This reuses the existing NTLM-authenticated CONNECT handshake
3. Forward the buffered ClientHello bytes to the upstream tunnel
4. Attach bidirectional relay handlers (same `TunnelRelayHandler` pattern)

The application's TLS handshake completes end-to-end through the tunnel. Conduit never sees the plaintext.

**Estimated size**: ~200 lines for the proxy + ~100 lines for SNI parsing.

### 3. Privileged Port Binding

Port 443 is privileged (< 1024). Two options:

**Option A: Helper relay (same as DNS port 53)**
Add a `startTCPRelay` / `stopTCPRelay` command to the helper contract. The helper binds `interceptIP:443` and relays TCP to `interceptIP:high-port` where the unprivileged `TransparentTCPProxy` listens. Follows the same pattern as `UDPRelay` for DNS, but for TCP streams.

**Option B: Direct bind via helper**
The helper binds the socket, passes the file descriptor to the app. More efficient but more complex IPC.

**Recommendation**: Option A for simplicity. TCP relay overhead on loopback is negligible.

### 4. Configuration & UI

**Settings additions**:
- "DNS Intercept" section in Settings, under the existing "Split DNS" section
- Table of intercept rules: pattern, interceptIP, enabled toggle
- Preset for "Cursor HTTP/2" that adds `*.cursor.sh`, `*.cursorapi.com`
- The transparent proxy starts/stops with the DNS forwarder

**Config fields** (`ProxyConfig`):
```swift
package var dnsInterceptRules: [DNSInterceptRule]
package var transparentProxyEnabled: Bool
package var transparentProxyIP: String      // default "127.44.3.0"
package var transparentProxyPort: Int       // internal high port, e.g. 10443
```

## Data Flow (detailed)

1. App calls `http2.connect('https://api2.cursor.sh')`
2. Node.js internally calls `getaddrinfo('api2.cursor.sh')`
3. System DNS → `127.0.0.1:53` (Conduit's DNS relay)
4. DNS relay → `127.0.0.1:5053` (LocalDNSForwarder)
5. ForwarderHandler matches `*.cursor.sh` intercept rule → returns `127.44.3.0`
6. Node.js receives `127.44.3.0`, calls `net.Socket.connect('127.44.3.0', 443)`
7. TCP relay on `127.44.3.0:443` → `127.44.3.0:10443` (TransparentTCPProxy)
8. Proxy accepts, peeks TLS ClientHello, extracts SNI `api2.cursor.sh`
9. `CONNECTCoordinator.connectUpstreamTunnel(target: "api2.cursor.sh:443")`
10. Upstream CONNECT + NTLM → corporate proxy → tunnel established
11. Forward buffered ClientHello to tunnel, attach bidirectional relay
12. TLS handshake completes end-to-end (app ↔ api2.cursor.sh)
13. HTTP/2 ALPN negotiated, streams flow through the tunnel

## Prerequisites

- DNS forwarder must be enabled (`dnsForwarderEnabled: true`)
- System DNS management must be active (`manageSystemDNS: true`)
- Privileged helper must be installed (for port 53 relay and port 443 relay)
- At least one upstream proxy must be configured and reachable

## What This Does NOT Require

- No `swift-nio-ssl` — TLS is end-to-end, Conduit never terminates it
- No `swift-nio-http2` — HTTP/2 frames flow as opaque bytes
- No certificate generation or trust management
- No per-domain certificate issuance
- No HTTP/2 frame parsing or translation

## Estimated Effort

| Component | Lines | Complexity |
|-----------|-------|------------|
| DNS intercept rules (config + forwarder) | ~55 | Low |
| `DNSWireFormat.synthesizeDirectResponse` | ~15 | Low |
| SNI parser | ~100 | Medium |
| `TransparentTCPProxy` | ~200 | Medium (reuses patterns) |
| TCP relay in helper | ~80 | Low (follows UDP relay) |
| Helper contract additions | ~10 | Low |
| Settings UI | ~60 | Low |
| **Total** | **~520** | |

All new code follows existing patterns (`TunnelForwarder`, `UDPRelay`, `DNSForwardingHandler`). No new dependencies.
