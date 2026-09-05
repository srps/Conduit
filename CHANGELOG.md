# Changelog

All notable changes to Conduit. Released versions come first; below them is the
pre-release development history that precedes the first public `0.1`, grouped by theme.
Forward-looking plans live in [`ROADMAP.md`](./ROADMAP.md).

## Unreleased

The three surfaces stop competing to be the whole app. The menu bar icon and popover answer
"is it working, and can I flip it" without scrolling; one app window with a sidebar holds
everything else; and Settings is no longer a separate thing but a group of sections in that
window, each pairing a subsystem's live state with its knobs.

**Upgrading:** the global shortcut is now off by default and, when enabled, is ⌃⌥⌘P rather than
⌘⇧P, which the previous default swallowed in every editor's command palette. A saved
`globalShortcutEnabled: true` is honoured; only the chord changes. The "Show menu bar icon"
toggle is gone — nothing read it, and the app has no Dock icon to fall back on.

### Menu bar

- The status item glyph carries the state: stopped, direct (VPN off or no upstreams),
  proxied, and needs attention (degraded, recovering, failed, or upstreams unreachable). The
  glyph choice lives in `MenuBarPresentation` next to the labels and has the same unit
  coverage.
- The popover is a fixed 320 pt panel that no longer scrolls: one state line ("Proxied via
  corp-eu-1", "Direct, VPN off", "Failed: port in use") with health, VPN and uptime under it;
  switches for the proxy, DNS forwarder and tunnels instead of buttons whose label had to be
  read to know the current state; the active upstream as a traffic-light row with the rest
  of the pool summarised as one line of counts ("4 fallbacks · 3 healthy · 1 open"), both
  opening the app on Upstreams; one activity line; the last three events; and Open Conduit, Restart Proxy, Copy
  Diagnostics and Quit. Fourteen controls became seven.
- First-run setup no longer waits for the popover to be opened. It is presented at launch as a
  sheet on the app window when NTLM is configured without saved credentials.

### App window

- One `Window` scene replaces the dashboard, Settings, Logs, Connections and Setup Wizard
  scenes, which were `WindowGroup`s and could each be opened several times. ⌘0 opens it on
  Overview; ⌘, opens it on the first Configure section. Closing it returns the app to the menu
  bar, decided by which windows the app registered rather than by sniffing private window
  class names.
- Overview is the old dashboard minus the duplication: three module rows with switches and
  status pills, a route card, one telemetry line, the richer upstream rows, and Restart Proxy,
  Test DNS, Open Test URL and Copy Diagnostics as ordinary buttons. Setup Wizard is no longer
  the most prominent button on a screen users see every day.
- Settings became eight sidebar sections that follow `ProxyConfig`: Proxy, Upstreams & Routing,
  Authentication, DNS, Tunnels, Shell Environment, General, Advanced. The "Network" grab bag is
  gone: launch at login and the shortcut moved to General, the test URLs to General >
  Diagnostics, the VPN flap sliders to Advanced. NO_PROXY and force-proxy lists moved from Env
  to Upstreams & Routing > Bypass Rules, next to the PAC that consumes them. Verbose and file
  logging, import/export and the privileged helper moved to General.
- Upstreams & Routing, DNS, Tunnels, Proxy and Authentication show a live status strip above
  their settings: route and per-upstream health with latency on each editable row; DNS
  queries, cache hit rate and DoH fallbacks with Test DNS; tunnel sessions and DNS override
  status; bindings; last auth handshake outcome.
- Every Configure section shows the config boundary's own validation next to the field it
  refuses, and lists cross-field conflicts it owns, instead of leaving them in the banner.
- "Detach" and "Detach Full UI" are "Open Conduit"; "Copy Summary" is "Copy Diagnostics";
  "Enable floating window mode" is "Keep window on top".

### Fixed

- Turning a platform integration off now undoes it. "Manage macOS proxy settings", "Manage
  shell proxy environment variables", the resolver files and "Manage system DNS" used to
  change a stored flag and nothing else while the proxy ran: the system proxy stayed pointed at
  Conduit, and because teardown checked the same flag, stopping or quitting left it there. A
  save now diffs the integration flags the way it already diffed the proxy config and applies
  or clears each surface on the spot, including a PAC/manual mode change and launch at login,
  which no longer waits for the next proxy start (#13).
- Quitting cleans up whatever Conduit applied, whatever the switches say now. Stop and
  termination clear a surface when its flag is on *or* when the prior-state journal shows it
  is ours, which covers a crash between the flip and the save and a config file edited by
  hand. Resolver files gain the journal's applied/released marker for this; the system proxy
  and the launchd environment already had one. The guard is the journal, not the machine: a
  proxy or resolver file the user set up themselves is never read as ours.

## 0.2.0

Teardown now restores the machine to what it was instead of switching things off, the
privileged helper speaks a new protocol to make that possible, and the parts of the app
that talk to subprocesses, the helper and the log no longer have silent failure modes.

**Upgrading:** reinstall the helper (`sudo ./install-helper.sh`) — the helper protocol moved
from 3 to 4 to carry the restore operations. A `saved-dns.json` left by 0.1.x is imported into
the new journal on first launch and then removed, so a machine that crashed with system-DNS
management active gets its resolvers back after the upgrade. The helper accepts protocol 3 as well, so an
app rolled back to 0.1.x keeps working against the new helper. The helper's own log file
is gone; it now writes to the unified log, and one query reads both processes in order:
`/usr/bin/log show --predicate 'subsystem == "io.github.srps.Conduit"' --info --last 1d`.

### Restore, not erase

- Platform side effects record what the machine looked like before Conduit changed it —
  system proxy settings, system DNS, launchd proxy variables — in a prior-state journal, so
  teardown puts the user's own settings back instead of blanket-disabling them. A second
  teardown no longer wipes what the first restored, a restore that only partly lands keeps its
  records rather than losing them, and teardown decides from the machine's actual state rather
  than from an empty journal. The legacy DNS snapshot and the optional-journal mode are gone.
- The privileged helper gained restore operations, so on machines where `networksetup` needs
  admin rights the restore is a real restore rather than degrading to a clear. Conduit's own
  leftovers are no longer captured as the user's prior settings, and saved settings survive a
  privileged write that fails.
- Fixed a teardown that silently did nothing: every command in the system-proxy clear script
  ended in `2>/dev/null || true`, which forced a zero exit and discarded the `requires admin`
  text the privileged-helper fallback keys on. Stopping the proxy on such a machine cleared
  nothing while reporting success. Permission failures now surface instead of being hidden by
  a blanket clear.
- Teardown restores a recorded service that is listed but down — a VPN link, an unplugged
  adapter — rather than skipping it and forgetting its record, which left it pointed at a
  dead proxy (or at the stopped resolver) for whenever it came back. And a service whose
  current settings could not be read is neither recorded nor written: recording the empty
  default for it turned the next teardown into an erase.
- A failed start reverts its platform side effects in both hosts. Previously an error out of
  `startProxy` left the system PAC setting naming a dead port and `/etc/resolver` files naming
  a dead forwarder, breaking DNS and proxying for every client on the machine.
- Fixed listener recycling, which could never succeed: it bound a replacement accept socket
  before closing the old one, burned its retry budget on `EADDRINUSE` against its own socket,
  and surfaced a raw NIO `IOError`. It now no-ops on a healthy listener and closes-then-binds
  only when the socket is dead or on the wrong address.
- Port conflicts report themselves: a typed `ListenerBindError` names the process holding the
  address, resolved through `libproc` rather than by spawning `lsof` on an already-failing
  start path. Only failures a wait can resolve are retried, so a permissions error no longer
  stalls the start path for ten seconds.
- Split-DNS entry files are removed whenever the VPN is down, not only while the proxy runs,
  and a start with the VPN down sweeps files a previous run stranded. Both hosts previously
  skipped reconciliation entirely when the runtime was down — exactly the state a crashed or
  failed start leaves behind, with the overrides pointing into a tunnel that is gone.
- Launch-time crash recovery decides from liveness (is the forwarder answering) rather than
  from socket ownership, runs off the main actor, and is joined before anything depends on it.

### Subprocesses and batches

- `CommandRunner` drains the child's pipes while it waits instead of afterwards, so a child
  that writes more than a pipe buffer no longer deadlocks against a parent waiting for exit.
  The drain is cancellable, read errors are no longer mistaken for EOF, the cancel wait is
  bounded, and the output cap is per caller — the PAC fetch states its own ceiling with a
  reason, and a PAC that was too large or timed out no longer reads as "PAC unreachable".
- Resolver-file removal batches finish after a failure and then report it, validate inside
  the loop, and migrate even after a partial sweep. An unusable domain is warned about and
  skipped rather than counted as a failed teardown.
- A thrown DNS reconcile no longer skips the intercept-file refresh, which could leave the
  intercept files pointing at a pre-restart forwarder port.

### Configuration boundary

- Intercept rules are validated at the config boundary with one RFC-grounded domain grammar
  (underscores allowed, as in service records). A bad rule withholds the resolver files, not
  the listener; an empty pattern is unconfigured, not wrong; an intercept target has to be
  IPv4 because the synthesized answer is an A record; and `dns.transparentProxyIP` is checked
  at the field new rules copy it from. Settings show the validation on the field that is wrong
  and keep the rules on screen whenever the boundary can refuse one. The daemon logs the config
  errors its start gate deliberately ignores.
- DNS server addresses use one IP-literal grammar, decided by `inet_pton` rather than a regex.

### Logging

- The app's file log is on by default, appended rather than truncated, and rolled by size
  (5 MiB × 3) at `~/Library/Logs/Conduit/proxy.log`. A file that cannot be written is reported
  once in the in-app log, and writing resumes silently when it can.
- The helper logs to the unified log with level and pid, and the app mirrors its own lines
  there under the same subsystem. The old helper log file and its rotation entry are removed
  on install and uninstall.
- Unified-log levels follow os_log's own semantics in both processes: notices and warnings
  are `.default`, errors are `.error`, and `.fault` is reserved for invariant violations —
  routine connect failures no longer fill Console's Fault column.
- Each CONNECT tunnel is logged at info rather than notice, and a tunnel relay failure names
  the target and the errno. Relay-setup failures are logged, and a read is resumed only once
  the upstream is writable.
- SwiftNIO failures are described instead of bridged: "The operation couldn't be completed.
  (NIOCore.ChannelError error 0.)" — the same text for a connect timeout, a DNS failure and a
  write to a closed channel — becomes the timeout, the lookup that failed, or each address
  that refused. The auto-recovery health summary carries the same detail. Expected outcomes
  log at the level they deserve: an origin that no DoH route answered for during an outage
  is a warning, a client that went away while the upstream connected is informational.

### Helper and relays

- A helper refusal is an answer, not a dropped connection: "unauthorized" and "no console
  user" come back as typed frames the app shows as state. Nothing prompts for a password on a
  refusal and nothing sleeps on it; the reconcile paths (health tick, wake, VPN change) re-issue
  the work when the situation changes.
- Relay starts are idempotent, and re-pointing a relay keeps the `lo0` alias with the host it
  serves. Relay liveness is honest: the accept loop rides out descriptor and buffer exhaustion
  instead of exiting, and a relay that does die closes its listener so a connect probe cannot
  be fooled by a backlog that still completes handshakes.
- The orchestrator probes the transparent TCP relay every 30 s and re-issues it when it is
  gone — the case being a helper relaunched by launchd after a crash, which comes back with no
  relays and previously left transparent proxying dead until a manual restart.
- A connection that closes before the TLS handshake no longer logs a spurious "SNI
  extraction timed out" ten seconds later. The liveness probe connects and closes without a
  handshake, which made that warning fire like clockwork — 2,880 lines a day.

### Under an outage

Three days of one machine's proxy log, read against the code, found the places where a
network that went away turned into work done many times over.

- Fixed a crash in the Kerberos handshake: two connections that both lacked a service ticket
  ran Heimdal's KDC-locate path at the same time, and the platform SSO plugin on that path is
  not safe to run twice at once. GSS initiator calls are now serialised process-wide, so one
  handshake fetches the ticket and the rest find it in the credential cache. After a KDC or
  network failure the next attempts to that target fail at once for five seconds instead of
  each waiting on the same unreachable KDC; a missing ticket is still reported every time, so
  the NTLM fallback and a fresh `kinit` behave as before.
- Automatic recovery admits one ladder at a time and pauses for a minute after one exhausts.
  Previously every failed health check started a ladder, and a ladder that exhausted restarted
  the health loop with an immediate check — 47 ladders in six minutes, overlapping, with their
  "switch upstream" steps flipping the active upstream back and forth. A healthy check clears
  the pause. Both decisions are on the event stream (`recovery.suppressed`,
  `recovery.cooldown_started`).
- Connects no longer race AAAA answers on a host whose only IPv6 addresses are link-local.
  Happy-eyeballs picked the AAAA, the connect came back half-open, and the IPv4 fallback then
  did the real work — a wasted connect and a warning per upstream connection, thousands a
  day. The resolver attached to every direct connect returns no AAAA while the host has no
  routable IPv6; the half-open fallback stays as the safety net.
- One PAC evaluation serves a burst of requests for the same host; before, each queued its
  own run of the script and waited for all the ones ahead of it, which is how one stalled
  `dnsResolve()` became a page of timeouts.
- The PAC is never fetched through the proxy it configures. curl inherited the proxy
  variables Conduit publishes, and the system session honoured the proxy settings Conduit
  installs, so a refresh went through the local listener, was routed by the previous PAC,
  and failed exactly when the upstreams were what had changed. The PAC host is also an
  implicit bypass in the HTTP and SOCKS5 handlers.
- During a network outage the transparent proxy's origin lookup remembers a host that no
  DoH route answered for, for five seconds, instead of paying the full provider × route
  fan-out of timeouts on every intercepted connection.
- Bounds on the new caches and queues: a PAC evaluation holds at most 256 waiters and the
  evaluator queue at most 64 evaluations (past either, a request is answered without routes,
  as a timeout would, and a `pac.evaluation_refused` event says so), the origin negative
  cache holds 256 hosts, and the GSS cooldown table 32 targets.

## 0.1.1

Makes the DNS forwarder usable as a resolver on a split-DNS corporate network, where
internal DNS answers NXDOMAIN for public names and the DoH fallback meant to cover that
was itself unreachable.

- Addressed the default DoH providers by IP literal (`1.1.1.1`, `9.9.9.9`, `8.8.8.8`) instead
  of hostname, with a schema-2 migration for configs still carrying the untouched hostname
  list. A fallback resolver named by hostname needs working DNS to obtain working DNS, and on
  a split-DNS network those hostnames are exactly the names that will not resolve. IP literals
  also sidestep URL-category filtering: all three shipped providers were observed serving a
  proxy's 404 block page while their IPs answered DNS normally.
- Made the forwarder log a total DoH failure instead of swallowing it, once, with the distinct
  HTTP statuses observed. A uniform status across every provider is a filtering proxy
  answering on their behalf; no status at all means nothing was reachable.
- Extended the origin resolver behind the transparent proxy's direct relay path to try the
  proxied routes as well as a direct dial. It was direct-only, and a direct dial to a public
  resolver is dropped under a full-tunnel VPN, the one condition in which that path runs.
- Answered SERVFAIL on the four DNS failure paths that previously returned nothing at all
  (intercept synthesis failure, unresolvable name, question mismatch, query-limit rejection).
  A client that gets no datagram waits out its own timeout and reports a dead forwarder rather
  than a failed lookup.
- Served DNS over TCP alongside UDP on the same port, with RFC 1035 §4.2.2 length-prefix
  framing, a 4 KiB message cap and an idle timeout. Clients may open with TCP and must retry
  over it after a truncated answer; `dig +tcp` was previously met with `connection refused`.
  Accepted connections are bounded (64) and closed when the forwarder stops, since closing a
  listener socket does not close its children.
- Internally, resolution moved into a transport-independent `DNSResolutionCore` so UDP and TCP
  share one cache, one URLSession pool and one metrics counter, and `DoHSessionFactory` absorbs
  the session construction both DoH clients duplicated.

## Unreleased (pre-0.1)

### Architecture & modularization
- Split the monolithic core into focused SwiftPM targets: a portable, Apple-framework-free
  kernel (`ProxyKernel`) plus `ProxyAuth`, `ProxyPAC`, and a macOS-only `PlatformMac` glue
  layer. Cross-target calls go through protocols (`LogSink`, `CredentialProvider`,
  `PacEvaluator`, `PrivilegeClient`, `ProxyAuthenticator`, `VPNStatusObserving`,
  `TunnelResolverApplying`), and the build itself enforces the import fence - the headless
  `pm-proxy` links no macOS frameworks.
- Introduced a `LogSink` protocol with stock console/discarding/recording conformers, and a
  single config-snapshot provider on the orchestrator that removed duplicated config mirrors.
- Externalized vendor presets to bundled JSON under `Resources/Presets/` loaded by a single
  `PresetLoader`; persistence falls back to generic defaults, and tests use a vendor-neutral
  `ProxyConfig.testFixture()`. Runtime config now carries a schema version and auto-normalizes
  unversioned files on load.

### Security
- Added a documented threat model covering malicious PAC, upstream MITM, Keychain credential
  theft, in-memory token snooping, local port hijack, helper privilege escalation, IPv6 family
  confusion, and SNI/CONNECT host mismatch.
- Replaced the JavaScriptCore PAC engine with the OS-patched CFNetwork evaluator (Safari
  parity), and removed the JavaScriptCore dependency from the sources entirely.
- Added `SecretBytes`, an opaque credential container that redacts in `print`/`dump`/lldb,
  refuses JSON serialization, and zeroes on deinit; routed in-memory credential boundaries
  through it.
- Centralized log/event sanitization so `Authorization` / `Proxy-Authorization` / `Cookie` /
  `Set-Cookie` and bearer tokens are masked across every sink, with an assertion that no log
  line carries an unmasked long token.
- Hardened the privileged-helper trust boundary: versioned and validated IPC, rejection of
  legacy unversioned frames, console-user-restricted socket, and pre-IPC command validation.
- Closed a confirmed gateway-mode SSRF bypass by applying the metadata blocklist to all
  outbound paths and canonicalizing IPv6 metadata-address forms.
- Added a privileged-action audit trail (request/outcome events with no raw helper values),
  tunnel credential rotation on config reload, and device-bound Keychain accessibility.

### Reliability & networking
- Automatic upstream failover with health-probed reachability, an upstream circuit breaker
  (failure threshold, exponential backoff, half-open probing, EWMA latency), idempotent retry
  on connection reset, and connection prewarming.
- Replay-aware request-body handling for non-CONNECT HTTP: bodies stay in memory up to a cap
  and spill to bounded `0600` temp files, preserving direct/PAC/fallback routing and multi-leg
  upstream 407 auth replay without unbounded RAM or event-loop file I/O.
- WebSocket / HTTP-Upgrade relay over a dedicated direct origin connection, with
  upgrade-preserving header sanitization and raw splice on `101`.
- `Expect: 100-continue` answered by the proxy, response trailers forwarded on the pooled path,
  and debug-only event-loop confinement assertions at callback-driven mutation sites.
- DNS-cache-poisoning resistance: responses whose question doesn't match are neither forwarded
  nor cached.
- Sleep/wake recovery so the proxy no longer sticks in DIRECT mode after macOS sleep, plus
  VPN/network-change reconciliation and port-retry on restart.

### PAC-aware routing & DNS
- PAC routing engine that fetches/caches corporate PAC files, evaluates `FindProxyForURL()`
  per request via CFNetwork, and respects full fallback chains (`PROXY → PROXY → DIRECT`).
- Native PAC DNS resolution (`dnsResolve`, `myIpAddress`, `isResolvable`, `isInNet`) with a
  per-evaluation cache.
- Local PAC serving: hosts the active routing chain at `http://127.0.0.1:<port>/proxy.pac` and
  points macOS auto-proxy at it, so browsers keep a stable local PAC URL that survives
  corporate PAC outages.
- DoH forwarder with a smart connection cascade (direct → upstream proxy → local proxy),
  LRU+TTL response cache with NXDOMAIN negative caching, DNS intercept rules, and optional
  system-DNS management via a native UDP relay in the privileged helper with crash recovery.

### Authentication
- Kerberos/SPNEGO via the system GSS framework as the default mode, with a protocol-based
  authenticator strategy: NTLMv2, Kerberos, and Negotiate (Kerberos-first with NTLM fallback).
  Default mode requires no first-run password prompt.
- GSS contract hardening (correct empty-token / mutual-auth-final-leg handling, replay/sequence
  flags) and a fix to store the authenticator per-handshake so multi-leg SPNEGO works.

### Protocol tunnels
- A tunnels module with service presets and proxied-tunnel support over HTTP CONNECT through a
  corporate proxy (TLS-inside-CONNECT with Kerberos auth), validated end-to-end against a
  cloud database through a corporate proxy.
- Self-contained per-tunnel DNS override via a mini UDP DNS responder and `/etc/resolver/`
  files, with progressive capability tiers (helper installed → fully transparent; AppleScript
  fallback → one admin prompt; no privilege → guided SOCKS5/hosts setup).
- DNS-intercept + transparent TCP proxy for clients that bypass `HTTP_PROXY`, with TLS
  ClientHello SNI extraction and privileged port-443 binding in the helper.

### Efficiency
- Connection-pool hot-path hardening: dedicated CONNECT tunnels reserve capacity through the
  same active/idle/pending cap as pooled exchanges, with O(1) channel→connection cleanup.
- Snapshot fan-out coalescing, an O(1) active-connection store, and amortized log ring-buffer
  trimming cut menu-bar CPU spikes substantially.
- Repeatable perf gates in CI (cold-start budget, `multi-100` completion, wall time, max RSS)
  and a scheduled sanitizer (ASan/TSan) soak job for the C-boundary code.

### Observability
- A fully `Codable` orchestrator snapshot, NDJSON `ready`/`status` streaming from `pm-proxy`,
  and a documented, versioned (v1), additive-only event-stream contract so observer extensions
  are third-party-buildable.
- `pmctl diag` collects recent, sanitized crash reports (home-path/login-name/device-id
  redaction, symbols preserved) with a crash-triage runbook.

### Diagnostics & tooling
- `pm-tls-check` captures and classifies the presented TLS chain (publicly trusted vs
  locally-trusted inspection vs untrusted), names common inspection vendors, and exports the
  inspection CA as PEM.
- Headless `pm-proxy` and `pm-dns` CLIs, plus the `pm-sim` fault-injection harness used as the
  reliability test bed.

### UI
- Module-cards dashboard with independent start/stop and live metrics for the proxy and DNS
  forwarder, per-module inline errors, a setup wizard, and a filterable log view.
- Draggable upstream ordering persisted as failover priority, reachability probes that don't
  rewrite priority, auth-mode badges, and a settings layout aligned to the config sections.

### Documentation & project
- Engineering-discipline style guide (`docs/STYLE.md`), contributor/AI guardrails
  (`AGENTS.md`), and a vendor-neutral README with the product-pillars contract.
