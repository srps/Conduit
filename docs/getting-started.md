# Getting Started

This guide walks you through building Conduit from source and getting a working proxy in under 5 minutes.

## Prerequisites

- **macOS 26** (Tahoe) or later
- A **Swift 6.2+ toolchain** — the Command Line Tools are enough to build; running the test suite additionally needs **Xcode 26+** (XCTest ships with Xcode)
- An upstream proxy to authenticate against (or just use it as a local forwarding proxy)

## Build from Source

```bash
git clone https://github.com/srps/Conduit.git
cd Conduit
swift build
```

The first build fetches SwiftNIO and takes ~60–90 seconds. Subsequent builds are incremental.

## Option A: Headless Proxy (CLI)

Run the proxy as a standalone daemon — no GUI, no system side effects:

```bash
swift run pm-proxy --port 3128 --state-dir /tmp/pm-proxy
```

This starts:
- HTTP/SOCKS5 proxy on `localhost:3128`
- NDJSON status stream to stderr (every 2 seconds by default)

Test it works:

```bash
curl -x http://localhost:3128 https://httpbin.org/ip
```

### Configure an Upstream Proxy

Create a config file at `/tmp/pm-proxy/config.json`:

```json
{
  "proxy": {
    "port": 3128,
    "upstreamProxies": [
      {
        "host": "your-corporate-proxy.example.com",
        "port": 8080,
        "enabled": true
      }
    ]
  },
  "auth": {
    "mode": "systemNegotiated"
  }
}
```

Then run with that state dir:

```bash
swift run pm-proxy --state-dir /tmp/pm-proxy
```

### Auth Modes

| Mode | What it does |
|------|-------------|
| `systemNegotiated` | Kerberos (from your `kinit` TGT) with NTLM fallback |
| `kerberos` | Kerberos only — requires an active TGT |
| `ntlmv2` | NTLMv2 only — requires saved credentials |
| `none` | No upstream auth (for unauthenticated proxies) |

For Kerberos, ensure you have a valid ticket:

```bash
klist  # check existing tickets
kinit your.username@YOUR.REALM  # if none exist
```

## Option B: GUI App

Build and install the app bundle:

```bash
./bundle-app.sh --install
```

This installs `Conduit.app` to `/Applications`. Launch it from Spotlight or Launchpad.

On first launch, macOS may show a Gatekeeper warning because the app is ad-hoc signed. Right-click → **Open** → click **Open** in the dialog. This is only needed once.

### First-Time Setup

1. The app opens a setup wizard on first launch
2. Choose your auth mode (Kerberos recommended if your enterprise uses it)
3. Configure your upstream proxy address
4. Click "Enable" — the proxy starts and macOS system proxy is configured

### Privileged Helper (Optional)

System proxy changes, DNS management, and the port 53 relay require admin. By default the app prompts each time. To eliminate repeated prompts:

```bash
sudo ./install-helper.sh
```

This installs a LaunchDaemon that handles privileged operations. Remove it with:

```bash
sudo ./uninstall-helper.sh
```

## Option C: Standalone DNS Forwarder

Run just the DNS-over-HTTPS forwarder:

```bash
swift run pm-dns --port 5353 --verbose
```

Point your system DNS at `127.0.0.1:5353`. Internal domains go through corporate DNS; external domains resolve via DoH (Cloudflare, Quad9, Google).

## Verify Everything Works

```bash
# HTTP request through proxy
curl -x http://localhost:3128 https://httpbin.org/ip

# HTTPS CONNECT tunnel
curl -x http://localhost:3128 https://www.google.com -I

# Check proxy status (if running pm-proxy with --status-interval)
# The NDJSON stream shows connection counts, upstream health, etc.
```

## Architecture

```
Conduit/
├── Sources/
│   ├── ProxyKernel/       — portable core (Foundation + NIO only)
│   ├── ProxyAuth/         — Kerberos/NTLM (GSS + CommonCrypto)
│   ├── ProxyPAC/          — PAC evaluator (CFNetwork)
│   ├── PlatformMac/       — macOS glue (Security, SystemConfiguration…)
│   ├── Conduit/      — SwiftUI GUI app
│   ├── pm-proxy/          — headless CLI daemon
│   ├── pm-dns/            — standalone DoH forwarder
│   ├── pm-sim/            — fault-injection simulator
│   └── pmctl/             — control CLI for the daemon
└── Tests/
    └── ConduitTests/ — 1,100+ tests
```

See [`docs/architecture.md`](docs/architecture.md) for the full module graph and design rationale.

## Next Steps

- [`docs/architecture.md`](docs/architecture.md) — module graph, dependency invariants
- [`docs/STYLE.md`](docs/STYLE.md) — engineering discipline
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute
- [`ROADMAP.md`](ROADMAP.md) — what's planned next
