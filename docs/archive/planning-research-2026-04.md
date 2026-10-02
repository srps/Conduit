# April 2026 planning research

Historical research retained from the former V2 plan. This material informed the
module split, native PAC evaluation, and engineering discipline. Its package
versions, competitive comparisons, platform claims, and recommendations describe
April 2026 and have not been refreshed for the current roadmap.

References below to Plan A mean the historical macOS work; Plan B means the
superseded cross-platform proposal. Neither is an active planning track. No rewrite
or cross-platform port is planned. Historical section references refer to the
original plan, available in Git history.

For current priorities see [ROADMAP.md](../../ROADMAP.md); for implementation
rationale and acceptance criteria see [planning.md](../planning.md).

This section is the *reason* for every decision above. Every claim is dated April 2026 based on the research pass performed for this plan revision. When reality changes, revisit.

## 5.1 Swift cross-platform viability (April 2026)

**Verdict**: Swift is fine for macOS. It is **not viable for a proxy daemon on Windows** today. Linux is possible but offers no ergonomic win over Rust for our stack.

### Windows blockers

| Blocker | Evidence |
|---|---|
| **SwiftNIO on Windows is pre-production** with known-broken TCP semantics for proxy workloads | [Mid-2025 status thread](https://forums.swift.org/t/mid-year-2025-swiftnio-for-windows-status/81143); PR [#3433](https://github.com/apple/swift-nio/pull/3433) "Winsock Fixes" open since Nov 2025 and still under review; known bug: *"TCP client connections to Windows servers don't read/write until a second connection arrives"*. No `NIOWindows` target shipping as of April 2026. |
| **No maintained Swift Kerberos/GSSAPI wrapper** | `PerfectlySoft/Perfect-SPNEGO` — last commit 2018. Nothing else. |
| **No Swift SSPI binding** | Would require hand-authoring `module.modulemap` over `sspi.h` and manually marshalling `SecBufferDesc` / `CtxtHandle`. |
| **No Windows Service support** in `swift-service-lifecycle` | [Issue #196](https://github.com/swift-server/swift-service-lifecycle/issues/196): explicitly POSIX-only. |
| **ABI not stable on Windows/Linux** | Apple's own [ABI Stability Manifesto](https://www.swift.org/blog/abi-stability-and-more/): *"Windows is maturing, but there is still a long path to get to the point where we should start thinking about ABI stability."* Swift runtime DLLs must ship with every release. |
| **`swift-system` Windows surface is officially "Unstable"** | Minor releases can be source-breaking. |
| **Toolchain instability in Q1 2026** | Nightly installers shipping without required DLLs (`_CompilerSwiftScan.dll`, `mimalloc-redirect.dll`) — swift#86191, swift#88376. ARM64 release/6.3 branch has 274 test failures (swift#86529). |

### Positives (2026)

- **Swift 6.3 shipped March 24, 2026** with cross-platform build improvements.
- **Official Windows Workgroup** formed Jan 2026 — first formal corporate commitment.
- **Static Linux SDK** is real (Tuist uses it) but there's no Windows equivalent.
- The Browser Company ships Arc on Windows in Swift — proof it *can* ship, though Arc is a GUI app, not a long-running networked service.

### Linux positives

- `swift build` + `swift test` generally work.
- Foundation-on-Linux has improved substantially.
- Static musl target exists.

### Linux negatives

- Still must hand-roll `libkrb5`/`libgssapi` FFI (no maintained Swift wrapper).
- Still must hand-roll `libsecret` FFI (no `keyring-rs` equivalent).
- Still on unstable ABI — runtime ships with releases.

### Interpretation

For Plan A (macOS-only), Swift is the right tool — it's our comfort zone, the codebase already exists, and macOS is the primary target. For Plan B (cross-platform, if triggered), Swift-on-Windows is a non-starter; Rust is the answer. There is no path where Swift-everywhere makes sense in 2026.

## 5.2 Rust forward-proxy stack

**Verdict**: hyper 1.x + tokio + httparse + fast-socks5 is the 2026 correct answer. Pingora and rama are out. (Relevant only if Plan B activates.)

### hyper 1.x — **recommended**

- **Latest stable**: 1.8.1 (2025-11-13); 1.9.0 scheduled 2026-03-31.
- **CONNECT support**: first-class via `hyper::upgrade::on(req).await`. The `examples/http_proxy.rs` in-repo demonstrates exactly the forward-proxy CONNECT pattern.
- **hyper-util 0.1.20** (2026-02-02) provides connection pool, CONNECT tunnel client (`Tunnel` with custom `Proxy-Authorization`), and h1/h2 auto-negotiation. Cherry-pick features; avoid default-features bloat.
- **500M+ downloads; 1.9k+ direct deps.** Every production Rust forward proxy uses it.

### pingora — **rejected**

- **0.8.0 (Mar 2026)** actively regressed CONNECT: returns 405 by default unless `allow_connect_method_proxying` is set.
- [Maintainer](https://github.com/cloudflare/pingora/issues/224): *"Pingora doesn't implement typical protocols such as HTTP CONNECT, PROXY protocol or SOCKS. So it does not work out of box with clients that expect one of these protocols."*
- Phase graph (`ProxyHttp` trait with `upstream_peer` / request filter / response filter / logging) is reverse-proxy-shaped and fights forward-proxy semantics (per-connection 407 state, connection pinning across Type 1/2/3).
- Idle footprint dominated by `Server` + `Service` + background-service runtime, designed for fleet services, excessive for a desktop daemon.
- **No production Rust forward proxy uses pingora.**

### rama — **rejected (for now)**

- **0.3.0-alpha.4 (2025-12-27)**, stable 0.3 planned for late Jan 2026.
- Service-graph framework with fingerprinting, TLS, HTTP/SOCKS5, telemetry. Used in production by commercial partners.
- Pre-1.0 with major architectural churn (they forked parts of `http`; the `Context` type was removed wholesale in 0.3).
- Fine for a multi-protocol gateway product; overkill and unstable for a single-binary forward proxy.

### Raw tokio + httparse — **use selectively**

- **httparse 1.10.1** (2025-03-03) — zero-alloc, zero-copy, used by hyper internally, shadowsocks, linkerd2-proxy, reqwest.
- Appropriate for tight control over a specific hot path (custom pre-parse for transparent-mode sniffing, etc.). Not appropriate as the whole HTTP/1.1 framer — hyper is 500–800 LOC you don't write.

### SOCKS5

- **fast-socks5 1.0.0** (2026-01-20) — MIT, tokio-native, SOCKS5+4+4a, UDP+TCP, user/pass + custom auth, 1.5M+ downloads. **Use this.**
- `socks5-proto 0.4.1` / `socks5-server 0.10.1` (EAimTY) — lower-level, **GPL-3.0** (kill-switch for shipping), stale since Apr 2024. **Skip.**

### Reference implementations (for learning)

- **Tinyproxy** (C, ~2 MB RSS): closest philosophical match to "single-binary desktop daemon." Reads well.
- **https_proxy** (Rust, hyper+tokio, ~7 MB binary with LTO): existing proof that hyper is the right layer for this use case. 407 auth, CONNECT tunneling, HTTP/2 extended CONNECT (RFC 8441).
- **linkerd2-proxy** (Rust, hyper+tower+rustls+tokio): service-mesh proxy; good reference for production-scale event loop.
- **mitmproxy** (Python+asyncio): study its `ConnectionHandler` layered-protocol design.
- **Squid** (C++ AsyncJob): 20+ years of corner cases; consult when hit by a weird interaction.

## 5.3 NTLM / Kerberos / SPNEGO libraries

**Verdict**: For macOS today (Plan A), keep the Swift implementations. For Plan B if triggered: port the Swift NTLMv2 to Rust by hand (~500 LOC) and use `libgssapi` / `cross-krb5` for Kerberos/SPNEGO. **Do not adopt `sspi-rs`.**

### sspi-rs (Devolutions) — detailed

- **Latest crate**: `sspi 0.19.2` (Mar 2026). GitHub tag `v2026.03.27.0`. Last push Mar 30, 2026. 73 stars, 33 forks, 40 contributors.
- **Reverse deps**: 8 on crates.io, almost all Devolutions' own tools (`ironrdp`, `jetsocat`, `picky-ldap`).
- **Activity**: multiple 2026 releases; dependabot weekly; Kerberos-first-with-NTLM fallback actually works as of v0.19.1 (Mar 13, 2026).
- **Regressions of concern**: Issue [#640](https://github.com/Devolutions/sspi-rs/issues/640) — NTLM broken in 0.18.8–0.19.1 when `USE_SESSION_KEY` is requested without Kerberos. Tested matrix on Dell PowerScale: v0.18.7 = 53/53 pass, v0.18.8 = 0/53. Only fully fixed in 0.19.2. Direct relevance: corporate proxies are often IP-addressed and non-domain-joined, which is exactly what broke.
- **Does NOT handle `Proxy-Authorization`.** You parse 407s, you pin the TCP connection across Type 1→407→Type 3, you base64-wrap tokens. The HTTP-proxy-specific plumbing is on you regardless.
- **On macOS**: pure-Rust reimplementation via `picky-krb` / `picky-asn1-*`. Does **not** call GSS.framework or read the user's `kinit` ccache without explicit work. Loss of SSO.
- **Dependency tax**: `picky-*` chain adds ~15 transitive crates (ASN.1, X.509, Kerberos, RC4/DES/AES/HMAC). Several MB of `.text`.
- **Production users for HTTP proxies**: effectively zero. Users are FreeRDP, RDP gateway, LDAP clients, SQL Server (via `tiberius`).

### Alternatives that *are* appropriate

| Crate | Latest | NTLM | Kerberos | macOS | Notes |
|---|---|:--:|:--:|---|---|
| **libgssapi 0.9.1** (estokes, Jul 2025) | — | ✗ | ✓ | via Heimdal/GSS.framework | Best when you want native ccache/TGT on macOS |
| **cross-krb5 0.4.2** (estokes, Jun 2025) | — | ✗ | ✓ | ✓ | Single API across libgssapi (*nix) + system sspi (Windows). Use this for Plan B cross-platform Kerberos. |
| **winauth 0.0.5** (steffengy, Mar 2024) | — | ✓ NTLMv2 only | ✗ | pure Rust | 600 LOC, MS-NLMP-faithful, supports channel bindings. Good reference or drop-in. |
| **ntlmclient 0.2.0** (Nov 2024) | — | ✓ | ✗ | pure Rust | Alternative to winauth |
| **reqwest-negotiate 0.1.0** (Jan 2026) | — | ✗ | ✓ | via Heimdal | Uses `libgssapi`. Client-side only (not proxy auth), but proves the integration pattern. |
| **krb5proxy 0.1.8** (veldrane, Oct 2025) | — | ✗ | ✓ | Linux only | Rust forward proxy that injects `Proxy-Authorization: Negotiate`. cntlm-for-Kerberos. |

### What cntlm, px, gontlm-proxy actually use

- **cntlm** (C, `versat` fork): fully in-tree NTLMv2 in `ntlm.c`. Zero external crypto. This is the blueprint for our hand-rolled port.
- **px** (Python): Windows via SSPI (`pywin32`); Linux/macOS via libcurl built with GSSAPI/krb5. Doesn't implement NTLM itself — delegates to libcurl.
- **gontlm-proxy** (Go): Windows SSPI via `go-ntlmssp`, no pure-Go NTLMv2 path, Windows-only really.

### HTTP-proxy auth gotchas (universal, not library-specific)

1. **TCP connection affinity.** NTLM authenticates the *connection*, not the request. The pool must pin the socket across Type 1 → 407+Type 2 → Type 3. `Connection: close` on any leg restarts from scratch. Already handled by our `CONNECTHandler` + `ConnectionPool`; verify when porting.
2. **CONNECT vs. non-CONNECT.** Authenticate the tunnel hop first (three-leg handshake on the proxy), then open the tunnel, then do TLS. Some proxies send periodic mid-tunnel 407s (Zscaler, Bluecoat).
3. **Channel bindings (EPA / CBT).** NTLMv2 with Extended Protection for Authentication hashes the TLS server-cert. Our NTLM doesn't support this today; relevant when proxy enforces EPA.
4. **SPN for the proxy.** Kerberos to the proxy is `HTTP/proxy.corp.example.com` — *not* the origin host. Lots of implementations get this wrong.
5. **IP-addressed proxies** trigger sspi-rs's (broken until 0.19.2) IP-SPN path. If ever adopting, pin ≥ 0.19.2.
6. **Target name for NTLM.** Echo Type 2's `TargetName` AV-pair in Type 3. cntlm does this; verify our Swift NTLM does.
7. **macOS TGT.** `sspi-rs` will not read the macOS ccache. `libgssapi` or direct GSS.framework FFI is needed for SSO.
8. **Unicode in passwords.** NTLMv2 requires UTF-16LE. Easy to get wrong.

## 5.4 PAC evaluation

**Verdict (Plan A, macOS)**: replace JavaScriptCore with `CFNetworkExecuteProxyAutoConfigurationURL`. Zero binary overhead, Safari-parity behavior, Apple-maintained security surface. **Verdict (Plan B, cross-platform)**: `rquickjs` (QuickJS-NG). Do *not* use `boa_engine`. Do *not* write a PAC-subset interpreter.

### CFNetworkExecuteProxyAutoConfigurationURL (macOS) — **recommended**

- Zero binary cost; system-maintained; what Safari uses.
- Known quirks: 5-second internal timeout (we wrap with our own); silent drop of `HTTPS` return keyword (our route normalizer should tolerate this); `PACClient` retain cycle (wrap in `autoreleasepool`).
- Our current `PACResolver.swift` uses `JavaScriptCore`. Migration is a module-scoped swap; the `PacEvaluator` protocol lands in `ProxyKernel` (abstractions), `PACResolver` moves to `ProxyPAC` as the CFNetwork-backed impl.

### rquickjs (QuickJS-NG) — cross-platform recommendation

- **Latest**: 0.11.0 (Dec 24, 2025). Repo pushed Mar 31, 2026. MSRV 1.85.
- Wraps **QuickJS-NG**, the actively-maintained fork of Bellard's QuickJS (upstream is dormant).
- Binary cost: 500 KB – 1 MB stripped. Runtime create/teardown < 300 μs.
- Near-complete ES2020; higher real-world PAC compatibility than boa today.
- **pacparser 1.5.0 (Feb 8, 2026) just migrated from SpiderMonkey to QuickJS.** The most experienced PAC implementer alive picked QuickJS in 2026. That's the strongest possible signal.
- Requires a C compiler in CI.

### boa_engine — **not for production PAC**

- **Latest**: 0.21.1 (Mar 29, 2026). Register-based VM, NaN-boxed `JsValue` since 0.21 (Oct 2025).
- **Test262**: 94.12% — ~6% of real-world ECMAScript behavior fails. Includes regex Annex-B semantics, `String.replace` with function callbacks, closure corner cases — exactly what Zscaler-generated corporate PACs use.
- Self-describes as "experimental" in README.
- **If used**, users will hit silent PAC returns-DIRECT bugs that are near-impossible to diagnose.
- Acceptable for a *learning* PAC evaluator. Not for a product.

### rusty_v8 — **too heavy**

- V8 is 600k+ LOC C++. Binary cost tens of MB; cold start orders of magnitude worse than QuickJS.
- Chromium uses V8 for PAC only because V8 is already in-process. We are not in-process.

### Is "PAC-subset interpreter" viable?

**No.** Research is unambiguous:

1. Real PAC files are not a clean subset. Closures, regex with Annex-B, `String.prototype.replace` with function callbacks, sometimes ES6 chunks. Zscaler-generated PACs rotate.
2. The only project that tried (Java `hudeany/ProxyAutoConfig`) self-documents as *"far from being a perfect JavaScript interpreter."*
3. Savings (~500 KB vs rquickjs) are negative against the maintenance and security burden of owning a JS parser.

### What browsers and tools use

| Stack | PAC engine |
|---|---|
| Chromium / Chrome / Edge | V8 in-process (memory-tuned flags; isolated `proxy_resolver` in some builds) |
| Firefox | SpiderMonkey (`netwerk/base/ProxyAutoConfig.cpp`) |
| WebKit / Safari / macOS apps | `CFNetworkExecuteProxyAutoConfigurationURL` (system service) |
| curl | **None.** Official guidance: pre-resolve manually or run a PAC-aware local proxy |
| libproxy 0.5.x | Duktape via `pacrunner-duktape` plugin |
| pacparser 1.5.0 (Feb 2026) | **QuickJS** (migrated from SpiderMonkey) |

### PAC landscape in 2026

PAC is not dying. Zscaler Client Connector still generates it; Netskope / Cloudflare Gateway / Palo Alto Prisma all emit PAC as an output format. The trend is wrapping PAC in a SASE tunnel (Client Connector / WARP / Entra PNC), not replacing it.

### Security

- PAC over WPAD is attacker-controllable on hostile networks (Pacdoor, BlackHat 2016).
- CVE-2021-23406 in npm `pac-resolver` bypassed Node `vm` sandbox via `this.constructor.constructor`. Any PAC evaluator needs a real sandbox + CPU/memory limits.
- pacparser's 2026 migration was driven by SpiderMonkey's 17-year-old "Ancient Monkey" JS escape. Frozen engines eventually become vulnerabilities.

## 5.5 DNS, TUI, Zig, Odin, tokio, JS engines

### hickory-dns (ex trust-dns) — **recommended** (Plan B only)

- **Latest stable**: `0.25.2` (May 2025). Pre-release `0.26.0-beta.3` (Apr 2, 2026). Last repo activity Apr 3, 2026.
- 40M+ downloads, 267 reverse deps on `hickory-resolver`. Maintainer `bluejekyll` + 240 contributors.
- Native DoH/DoT/DoQ/DoH3 via `https-rustls` feature. Crate split (`hickory-proto`/`-client`/`-server`/`-resolver`/`-recursor`) means we pull only what we need.
- Alternatives (`domain`, `simple-dns`) are sub-scope for a local forwarder.

### rustls — **recommended** (Plan B only)

- **Latest**: `0.23.37` (Feb 24, 2026).
- aws-lc-rs is default backend since Feb 2024; FIPS available; post-quantum ML-KEM shipping (~2% of Cloudflare TLS 1.3 traffic).
- Does NOT handle CONNECT (correct layering — CONNECT is HTTP). Pair with `hyper` + per-SNI `ResolvesServerCert` for MITM patterns (2026 crates `slinger-mitm`, `rustls-mitm`, `rust-forward-proxy` all demonstrate this).

### ratatui — **recommended if we ever want a Rust TUI**

- **Latest**: `0.30.0` (Dec 26, 2025). MSRV 1.86.0. Stars 19,481; downloads 23.6M; reverse deps 3,436.
- Monolithic crate → modular workspace in 0.30: `ratatui-core`, `ratatui-widgets`, `ratatui-crossterm`, `ratatui-termion`, `ratatui-termwiz`, `ratatui-macros`.
- Alternatives: `tui-rs` is **dead** (ratatui is its fork); `cursive` is active but much smaller and ncurses-flavored. **ratatui is the pick if Rust TUI is wanted.**

### Zig — **usable, expect churn**

- **Latest stable**: `0.16.0` (Apr 14, 2026). 1.0 is multi-year out; no 2026 timeline.
- 0.15→0.16 was **Writergate**: `std.io`→`std.Io`; `GenericReader`/`AnyReader`/`FixedBufferStream` deleted; `readToEndAlloc` signature changed; `usingnamespace` removed. Every tutorial older than ~Dec 2025 is broken.
- Cross-compilation via `cargo-zigbuild 0.22.1` is production-grade for linking Rust binaries. That's the real Zig-in-Rust-ecosystem use.
- **Not appropriate** as the source language for a DNS parser linked into Swift or Rust — hickory-proto / DNSWireFormat.swift already solve it better.

### Odin — **not appropriate for a Rust-consumed library**

- Rolling `dev-YYYY-MM` tags; latest `dev-2026-04`. LLVM 22.
- Solo BDFL (Ginger Bill); 10K+ stars but bus factor 1.
- No public production users exporting C ABI consumed by Rust. No `cbindgen` equivalent.
- Fine as a standalone tool/game language. Risky as a Rust dependency.

### tokio — **recommended** (Plan B only)

- **Latest**: `1.52.0` (Apr 14, 2026).
- 1.50–1.52 highlights for a proxy: sharded `spawn_blocking`, LIFO steal, vectored writes, `io_uring` SQPOLL support in-flight (Linux-only, unstable feature flag).
- No breaking changes in 1.x line.

### boa_engine vs rquickjs (Rust JS engines)

- **boa_engine 0.21.1** (Mar 29, 2026): pure Rust, no-unsafe, debuggable, async-Rust-friendly; 94.12% Test262; register-based VM + NaN-boxing since 0.21.
- **rquickjs 0.11.0** (Dec 24, 2025): C dependency; near-complete ES2020; higher real-world PAC compatibility; smaller binary.
- See §5.4 for the PAC-specific verdict.

### Zig ↔ Rust interop

- **Linker use** (`cargo-zigbuild`): ✅ production-grade.
- **Library source interop** (`autozig` + manual `build.rs` + hand-authored `extern "C"`): 🟡 works, niche. No `cxx` equivalent for Zig. No `cbindgen` for Zig.
- **Async boundary**: 🔴 do not cross tokio/Zig-async. Keep Zig sync; call from `spawn_blocking`.

### Rust ↔ Swift interop (on macOS, for Plan B's macOS shell)

- **Unix-socket control protocol is the right answer.** C FFI between Swift and Rust works mechanically but recreates the exact class of bugs Hashimoto called out in the Ghostty GTK rewrite (§5.7). Cost-benefit favors IPC.

## 5.6 Competitive landscape

**Verdict**: the niche for Conduit is **macOS developers at AD-Kerberos/NTLM enterprises running legacy explicit proxies**. This niche has no live competitor that offers our combination of features. Plan A extends the moat. Plan B competes on Windows/Linux where multiple tools already exist.

### Direct competitors

| Tool | Lang | Stars | Latest release | Maint. | macOS | Linux | Win | NTLM | Kerb | PAC | SOCKS5 | DNS fwd | Failover |
|---|---|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| **px** (genotrance) | Python | 1,082 | v0.10.3 (Mar 11, 2026) | Active | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | comma-list, no health |
| **cntlm** (versat fork) | C | 165 | v0.94.0 (Aug 19, 2025; pushed Apr 7, 2026) | Active | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | round-robin |
| **alpaca** (samuong) | Go | 244 | v2.0.11 (Aug 11, 2025) | Active | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ | PAC-list only |
| **gontlm-proxy** (bdwyertech) | Go | 75 | v0.5.35 (Nov 14, 2025) | Active | — | — | ✓ | ✓ | ✓ | reg/env | ✗ | ✗ | single upstream |
| **proxydetox** (kiron1) | Rust | 46 | v0.13.0 (Dec 12, 2025) | Active | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ | dnsdetox module | PAC-list only |
| **krb5proxy** (veldrane) | Rust | tiny | v0.1.8 (Oct 2025) | Early active | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | — |
| **Preproxy** (Eugene Hom) | ObjC/Swift | App Store | 1.5.5 (May 2022) | **Dead** | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ | basic |
| **Conduit** (us) | Swift | (us) | — | **Active** | ✓ | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | **health + circuit breaker + ladder** |

### Adjacent categories

- **mitmproxy**: upstream-auth support is Basic only; NTLM requires custom Python addon hacks. Not a corporate-auth tool.
- **proxychains-ng**: `LD_PRELOAD` sockifier. Different category.
- **ngrok Desktop / Cloudflare Tunnel / WARP**: inbound-tunnel / SASE client. Needs to cross a corporate proxy, doesn't authenticate to one. Orthogonal.
- **Zscaler Client Connector / Netskope / Cisco Umbrella / Entra Private Access + PNC**: SASE/ZTNA *replacements* for explicit proxies. On managed endpoints, intercept at kernel/NetworkExtension layer and push through the cloud — no NTLM handshake. The strategic risk to Plan B, not to Plan A.
- **Windows native (WinHTTP + SSPI + WPAD)**: seamless for Edge/Chrome/.NET. Does *not* help WSL (no NTLM/Kerberos per [WSL #10804](https://github.com/microsoft/WSL/issues/10804)), Python, Node, Go, curl, JetBrains, etc. Partial solution at best.
- **Docker Desktop 4.30+**: native NTLM/Kerberos/SOCKS5 — Docker traffic only.

### macOS-specific pain points (relevant to Plan A's differentiation)

- `curl --proxy-negotiate / --proxy-ntlm` fails on macOS while succeeding on Windows in the same AD domain ([curl #14757](https://github.com/curl/curl/issues/14757)).
- `URLSession` breaks when proxy advertises `Negotiate` before `NTLM` — Apple's stack picks Negotiate and can't fall back ([Apple Dev Forums 100523](https://developer.apple.com/forums/thread/100523)).
- `px` on macOS has a history of PAC-parsing regressions (v0.8.4, v0.10.0) and a "URL malformed" bug under Python 3.11/3.12.
- Preproxy dead since May 2022.

### Interpretation

Plan A's niche (macOS-native, real failover, all protocols in one tool, Kerberos + NTLM, active maintenance) is genuinely unfilled in April 2026. A Swift-native macOS app with our feature set hits a gap that has been open for 4+ years. We should not try to be a better px; we should be the thing that finally makes Preproxy's successor, with failover no competitor has.

## 5.7 Ghostty / TigerBeetle architectural fact-check

**Verdict**: philosophy ✓, template ⚠️. Keep the discipline; don't copy the architecture uncritically.

### Ghostty claims

| Claim | Status | Note |
|---|:-:|---|
| libghostty is a platform-independent core in Zig | ✓ | [ghostty.org/docs/about](https://ghostty.org/docs/about). Also `libghostty-vt` for narrower VT-only use, targets macOS/Linux/Windows/WASM. |
| Swift/AppKit on macOS, Zig/GTK4 on Linux | ✓ with update | **GTK application rewritten Aug 2025** (PR [#8235](https://github.com/ghostty-org/ghostty/pull/8235), "gtk-ng") to embrace GObject. Hashimoto's post-mortem explicitly rejects the thin-shell pattern: *"an entire class of bugs where the Zig memory or the GTK memory has been freed, but not both."* Shipped in 1.2 (Sep 15, 2025). **This changes how we should think about the Swift layer.** |
| Core exposes a C API any language can embed | ⚠️ overstated | API exists, PR [#11506](https://github.com/ghostty-org/ghostty/pull/11506) added `ghostty_terminal_*` / `ghostty_formatter_*` surface in Mar 2026, **but docs state**: *"API is currently used primarily by the macOS app and is not yet stabilized for general-purpose embedding. The API may change significantly between releases."* Four years in, still not stable. |
| Core owns all terminal logic; shells only handle platform/UI | ✓ | Reinforced, not contradicted, by GTK rewrite — core stayed in Zig; platform integration got deeper. |
| ~2 years of private beta before 1.0 | ✓ | [1.0-reflection post](https://mitchellh.com/writing/ghostty-1-0-reflection): private beta reached ~600 → ~5,000 users before public 1.0 Dec 2024. |

### TigerBeetle claims

| Claim | Status | Note |
|---|:-:|---|
| Zero external dependencies | ✓ | Enforces Zig 0.14.1 exactly. Vendors tools (`llvm-objcopy`) as released binaries. No `build.zig.zon` third-party deps as of Apr 2026. |
| Deterministic simulation testing — replay any failure | ✓ | VOPR simulator, seeded. `./zig/zig build vopr`. |
| Static allocation, no GC, no dynamic allocation in hot paths | ✓ (extended) | Canonical [article](https://tigerbeetle.com/blog/2022-10-12-a-database-without-dynamic-memory). Extended to the REPL via `StaticAllocator` in 2025. |
| Chose Zig over Rust for "favorable ratio of expressivity to complexity" | ✓ exact phrasing | In the Oct 25, 2025 [ZSF pledge post](https://tigerbeetle.com/blog/2025-10-25-synadia-and-tigerbeetle-pledge-512k-to-the-zig-software-foundation). Stated reasons: Rust's crash-on-OOM default, single-threaded TigerBeetle doesn't benefit from borrow-check, never-frees-memory model. |
| TIGER_STYLE.md is authoritative | ✓ | [docs/TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md). Order: safety, performance, developer experience. |
| **TigerBeetle has shipped 1.0** | ✗ | **No.** Latest `0.17.0` (Apr 3, 2026), weekly releases. Roadmap issue #259 closed Jan 2025 but no 1.0 tag. Production-ready in practice, 1.0-labelled never. The "TigerBeetle 1.0" benchmark claim in casual reading is wrong. |
| Ghostty 1.x shipped? | ✓ | 1.0 Dec 2024, 1.1 Feb 2025, 1.2 Sep 15 2025. ~50K stars by Mar 2026. |

### "Ghostty model" as architectural template (April 2026)

Still a reasonable template, with three refinements from the 2025–2026 experience:

1. **Embrace the platform toolkit.** Don't make the native shell thin. Wrap core structs in the toolkit's reference-counted / memory-managed types (GObject on GTK, NSObject-bridgeable Swift types on macOS). This is the explicit lesson of the Ghostty GTK rewrite.
2. **C ABI stability is harder than advertised.** Ghostty hasn't stabilized theirs in 4 years. If Plan B ever activates, we don't expose a C ABI; we expose a Unix-socket control protocol (which is what Plan A's daemon-first phase already establishes).
3. **Narrow, focused sub-libraries are what people actually embed.** `libghostty-vt` (VT parsing only) is more embeddable than `libghostty` (terminal). If we ever go cross-platform, a narrow `pm-core` with just the config + event types might be the stable public interface, not the whole runtime.

### In-production projects following the ghostty model

- `Xuanwo/gpui-ghostty` — Rust/GPUI embeds Ghostty VT.
- `semos-labs/attyx` — Zig GPU terminal.
- `duanebester/gooey` — Zig UI framework, Metal/Vulkan/WebGPU.
- `evmts/agent` (Smithers v2) — native macOS IDE on Swift + Zig using Ghostty.
- `ghostty_vte` (Dart package) on pub.dev — uses `libghostty-vt` via FFI incl. Windows.

Pattern: the narrower sub-libraries get embedded. The full runtime gets shipped as an app.

---
