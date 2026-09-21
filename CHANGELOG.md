# Changelog

All notable changes to Conduit. Released versions come first; below them is the
pre-release development history that precedes the first public `0.1`, grouped by theme.
Forward-looking plans live in [`ROADMAP.md`](./ROADMAP.md).

## Unreleased

### Fixed

- The DNS forwarder started on port 0 (`pm-proxy --dns-port 0`, `pm-sim`, the tests) binds
  UDP first and puts TCP on the number UDP got. An ephemeral UDP port does not reserve its
  TCP twin, so another socket could already hold it, and the forwarder warned and served UDP
  only, with `tcpListeningPort` nil. It now releases the UDP port and binds the pair again
  on a fresh one, up to eight times, and the start fails if none is free on both. A
  configured port keeps serving UDP only when its TCP side is taken. (#57)

### Logging

- `dns.listener_port_retry` reports each port-0 pair that was given up, and
  `dns.tcp_listener_unavailable` reports a forwarder left without a TCP listener, whether it
  serves UDP only or failed to start. Until now the only trace was a warning line.

## 0.3.2

A maintenance release from the September 17–19 source review: two ways a client or an
upstream could crash the proxy, request-line and CONNECT-framing hardening, lost
server-first tunnel bytes, an exchange that could hang for good, and descriptor-lifetime
fixes in both of the helper's relays. It also carries the soak-race and relay fixes that
followed the 0.3.1 triage.

**Upgrading:** reinstall the helper (`sudo ./install-helper.sh`). Both relays and the
helper's request handling changed, and the installed helper keeps the old code until it is
replaced. Nothing in the helper protocol changed, so the 0.3.2 app works with a 0.3.1
helper in the meantime.

### Security

- A CONNECT whose client sent tunnel bytes before the `200` could terminate the proxy:
  removing the HTTP decoder forwarded its leftover raw bytes into a typed handler that was
  still installed. Direct and upstream paths now remove the typed handlers and install both
  relays before the decoder releases anything. (#43)
- A malformed upstream CONNECT response could reach a trapping buffer operation, and the
  parser mixed character counts with byte offsets. The handshake now uses bounded,
  byte-oriented framing with checked lengths. It rejects malformed status lines and
  headers, signed or oversized lengths, duplicate or conflicting framing and unsupported
  transfer codings, emits `connection.upstream_invalid_response`, and fails the attempt
  with the pool slot released. Any `2xx` establishes the tunnel, and bytes after it are
  tunnel bytes, never parsed as a response.
- Direct HTTP and Upgrade forwarding decoded escaped path characters before writing the
  request line, so an encoded delimiter could become HTTP syntax at the origin. Both paths
  now write the encoded origin-form target as the client sent it; literal controls and
  spaces are refused before URL parsing. Query order, duplicates and empty delimiters are
  preserved.
- A direct forward of an absolute-form request sends the target's authority as `Host`
  (RFC 9112 §3.2.2). It used to keep the client's `Host`, so `GET http://a/` with `Host: b`
  was routed by `a`'s rules and served by the origin as `b`. Requests to an upstream proxy
  are unchanged, because that proxy applies the same rule.
- The helper bounds a whole request and a whole reply with a monotonic deadline, 5 s and
  1 MiB, over a nonblocking descriptor. The old 5 s receive timeout restarted with every
  byte, so a staff-group peer sending a byte every few seconds could hold the helper's
  single accept loop, and with it every other client. A peer whose refusal no command could
  change (root, not the console user, nobody remembered at the loginwindow) gets 1 s and
  64 KiB, and its request is never decoded. Requires a helper reinstall. (#47, helper side)
- The helper's UDP relay closed its sockets outside the lock while its loop could sit
  between `poll` and `recvfrom`/`sendto`. Descriptor numbers go to the next socket opened,
  so an evicted loop, running as root and relaying DNS, could read another socket's
  datagram and forward it to its own target. Every read and send now happens under the
  lifecycle lock after a generation check, and `stop()` closes under the same lock.
  Requires a helper reinstall.
- The TCP relay had the same defect: `stop()` closed registered sockets before the owning
  worker's last read or write, including a worker that had not started yet. Descriptors
  stay owned until their worker finishes. Requires a helper reinstall.

### Fixed

- An upstream that closed a kept-alive connection just as a request was written to it left
  the exchange pending for good. A clean close raises no error, the response timeout had
  already been cancelled, and nothing else completed the promise, so the caller never
  returned and the pool slot was never released. The exchange now fails with `.eof`, which
  the pool retries on a fresh connection for an idempotent request. A streamed response
  that ends with the upstream's close, which is how a response with no length ends, still
  completes normally.
- Bytes an origin sent first through an upstream CONNECT could be lost: those in the same
  read as the `2xx` were discarded with the handshake handler, and those arriving before
  the consumer's relay was installed fell off the pipeline. SSH banners and SMTP or FTP
  greetings through an upstream proxy were lost and the client hung, on HTTP CONNECT,
  SOCKS5, proxied port tunnels and the transparent proxy alike. A `2xx` now pauses upstream
  reads, and every consumer installs its relay through `CONNECTCoordinator.attachRelay`,
  which hands the held bytes over once and in order.
- Numeric IP addresses resolve without entering the blocking hostname-lookup queue, so a
  tunnel to a literal no longer waits behind slow DNS. An explicit IPv6 literal bypasses
  the global IPv6-availability check, which keeps loopback and scoped addresses usable
  without a routable IPv6 interface. An out-of-range port fails before the `UInt16`
  conversion.
- A streamed HTTP response through the upstream finished on the client channel's event
  loop while the upstream loop was removing the same handler; ThreadSanitizer reported the
  race in the scheduled soak. The finish now hops to the handler's loop.
- The helper's DNS and port-443 relays identified a loop that exited on its own by its
  descriptor numbers. `stop()` closes those and the next `start()` gets the same numbers
  back, so the evicted loop could close the fresh relay's sockets a moment after a restart.
  Each start now has a generation, the TCP relay's session tracker belongs to one start,
  and an accept that completes after `stop()` starts no session.
- The TCP relay's accept loop polls once a second instead of ten times, like the UDP
  relay. The interval only bounds how long an evicted loop lingers.
- `install-helper.sh --source` takes exactly one of `installed|local|release|debug`, refuses
  a missing or repeated value, and checks its arguments before the root check. The bare-word
  form is gone.

### Logging

- A network-path update emits one `network.path_changed` event carrying the path, whether
  it is satisfied, and both decisions (DNS transport reset, PAC refresh or skip) before the
  log line and the actions; `pac.refresh_skipped` is folded into it.
- An upstream CONNECT or exchange failure emits `upstream.tunnel_failed` or
  `upstream.exchange_failed`, and an unexpected direct-connect failure emits
  `direct.connect_failed`, before the error line. Expected failures (VPN off, a memo repeat,
  a transient path change) stay info lines with no event. `docs/events.md` catalogues these
  and the events 0.3.1 added without documenting.
- A request the pool refused locally reports `connection.pool_exhausted` and gets no
  upstream failure event, whatever the network cause around it.

### Development

- `pm-sim` results carry named assertions, and a failed or missing assertion, an empty
  result or a thrown setup error fails the process. `pm-sim all` runs every scenario from
  one list, 37 of them including the DNS scenario it used to omit, each under a watchdog,
  and is a CI step. Notes and early-close metrics no longer decide anything. (#51)
- New scenarios: `connect-early-direct`, `connect-early-upstream`, `server-first-connect`
  and `server-first-socks5`, each checking exact bytes and the selected route.
  `scripts/test-http-wire-target.py` checks request targets and `Host` on the wire.
- The `flood-slow-drain` fake origin half-closes after its burst. It used to close fully,
  the client's late request bytes drew a reset, and the fake upstream lost the unread part
  of the burst. The proxy delivered every byte it was given; the gate's first run on `main`
  caught the fixture.
- `pm-sim direct-mode-silence` asserts on the request outcome, the failure event and the
  log level instead of matching log text.
- Timing tests wait for observed events instead of fixed sleeps, and the DNS fixtures await
  teardown before their event loops shut down.

## 0.3.1

A maintenance release: the fixes from twelve days of the installed app's log, the
trust-boundary and resource-bound fixes from the September source review, and a dev
instance that runs beside the installed app. It also repairs the install scripts, which
had shipped a stale build since the Xcode 27 update.

**Upgrading:** reinstall the helper (`sudo ./install-helper.sh`) so a logout can tear the
proxy down. Credentials now go only to upstreams listed under Upstreams, so an endpoint a
PAC names but the list does not must be added there to authenticate. Outside gateway mode
the proxy binds only to loopback. A `config.json` that fails to load is no longer replaced
with defaults: the app opens on the error and waits for the file to be repaired.

### Fixed

Findings from twelve days of the installed app's `proxy.log` (2026-09-05 to 09-16).

- Upstream connects on the data path have their own budget, `upstreamConnectTimeoutSeconds`
  (default 5 s, floored at 500 ms), editable under Advanced > Failover & Circuit Breaker as
  "Upstream Connect Timeout". The pool used to borrow the probe timeout, and a profile tuned
  to 500 ms for snappy probes failed 56 CONNECTs in one day against a corporate proxy over
  VPN that merely took longer than that to answer a SYN. The probe field is now labelled
  "Probe Timeout" under "Probes & Direct Connect", with help text saying what it bounds.
- The helper lets the last console user undo at the loginwindow: remove resolver files,
  clear the system proxy, stop relays. A logout used to hit "waiting for a login session"
  on every teardown call, leaving the Wi-Fi proxy pointed at a listener that no longer
  existed until the next launch. Setting a value still waits for a session, so a restore
  at logout clears the proxy instead, and a redirected system DNS goes back to DHCP rather
  than staying on a stopped 127.0.0.1 relay; the recorded settings are restored at the next
  launch. A different user's process is still deferred. The helper seeds the console user
  at start, so one restarted mid-session admits the logout teardown too. Requires a helper
  reinstall.
- A Kerberos handshake whose credential is momentarily unavailable is retried twice at
  750 ms before failing; after a retried handshake still fails, further handshakes to that
  upstream fail at once for 30 s. The SSO extension takes a moment after a VPN reconnect
  to hand the ticket back, and every CONNECT in that window used to fail outright.
- The recovery ladder is not run for a missing credential. Closing connections, resetting
  auth, switching upstream and recycling the listener cannot supply a ticket, and the
  ladder ended by suggesting the password had changed. One warning names the state; the
  health loop keeps checking until a ticket appears.
- The error-rate alarm has a 30 s cooldown and spends the failures that raised it. It used
  to re-arm as soon as the probe returned, eight times in four seconds.
- Network-path updates are debounced for 2 s and carry whether the path is satisfied; an
  unsatisfied path still recycles the DoH transports but does not fetch the PAC. A dark
  wake produces several updates, each of which used to start a `curl`.
- A forced PAC refresh no longer overlaps one in flight, and a failed fetch backs off
  (30 s doubling to 10 min) for path-triggered refreshes. Wake, VPN reconnect and user
  action still fetch at once, and a changed URL always fetches.
- Direct connects to link-local literals (169.254/16, fe80::/10) get a 2 s budget instead
  of 10 s, and a timeout is remembered for 60 s so the next attempt fails at once. A cloud
  SDK probing the metadata endpoint held a connection for 10 s on each of 178 attempts.

### Security

Fixes from the source review of 2026-09-09 (`docs/review-2026-09-09.md`), recorded in
`docs/security-fixes-2026-09-09.md` and `docs/fix-resource-bounds-2026-09-10.md`.

- Credentials go only to configured upstreams. The authenticator is built for the upstream
  the request is going to, matched by host (case-insensitive) and port against the enabled
  entries in Upstreams; an endpoint a PAC names that is not listed emits
  `auth.upstream_not_trusted` and gets no handshake. There is no fallback to the first
  configured upstream.
- A configuration that fails to load is rejected, not replaced with defaults. Corrupt JSON,
  an unsupported future schema or an unreadable file stop `pm-proxy`, `pm-dns`, `pm-tunnel`
  and the daemon with `config.load_rejected`; a rejected reload keeps the previous
  configuration and generation. Defaults apply only on a genuine first run or with
  `--minimal`; a `config.json` deleted beside established state is rejected, and `pm-dns`
  always needs a configuration or `--minimal`. Journal-backed recovery of orphaned system
  proxy and DNS settings still runs after a load failure.
- Outside gateway mode the proxy binds only to loopback: `127/8`, `::1`, or `localhost`
  pinned to `127.0.0.1` so ambient DNS cannot turn it into a LAN bind. The DNS transports
  require loopback even in gateway mode. The advertised endpoint, the generated PAC and the
  environment URLs carry the normalized address.
- Observations are separated from wire inputs: query strings and fragments, origin-form
  targets and rejected CONNECT targets are redacted from logs, events, active records and
  audit targets, while the forwarded bytes are unchanged.
- SOCKS honours forced-proxy rules before the PAC, as HTTP and CONNECT already did, and
  force and bypass rules match equivalent IPv6 literals (compressed, bracketed) in both the
  router and the generated browser PAC.
- HTTP and SOCKS reserve from one inbound admission budget (`inboundConnectionMaxLimit`).
  SOCKS negotiation has a 10 s deadline and a 519-byte buffer bound, and a greeting reply is
  still sent before an oversized payload is rejected. Lowering the limit live stops new
  admissions without evicting connections; a nonpositive limit is rejected.
- PAC fetches are bounded to 256 KiB over HTTPS, HTTP and file sources, HTTPS redirects stay
  on HTTPS without credentials, and a candidate script is probed once before it is
  installed, so a failed fetch or a broken script keeps the last working evaluator.
- Event, audit and console writers share a bounded queue (4,096 records or 4 MiB pending,
  batches of 128 records or 256 KiB) that drops and counts on overflow instead of growing.
  Disk writers append batches rather than rewriting the file per record, flushes have a 2 s
  deadline, and shutdown drains once. Periodic status is written only on change, at most
  10 Hz.
- `pm-dns` keeps its signal sources for the process lifetime, so TERM and INT close the
  forwarder and exit normally instead of being dropped.

### Logging

- Transparent-proxy relay lines moved from notice to info; two hosts alone were half of the
  log file.
- A PAC fetch failure is logged once, by the engine, instead of twice.
- A CONNECT abandoned by the client before the upstream tunnel came up is logged at info
  as such, not as an ERROR `I/O on closed channel`.
- `IOError` text no longer carries NIO's stray parenthesis, and a resolver failure reads as
  `getaddrinfo`'s wording rather than a struct dump.

### Development

- `bundle-app.sh` and `install-helper.sh` ask SwiftPM where the products are instead of
  assuming `.build/<arch>-apple-macosx/<config>`. Xcode 27's build system writes to
  `.build/out/Products/<Config>` and leaves the old directory untouched, so every
  `make install` since the toolchain update rebuilt successfully and then shipped the app
  and helper from 2026-09-05/06. The script now fails if a product is missing.
  `install-helper.sh` installs the newer of the two build products when one exists, and
  falls back to the local bundle, then the installed app (it used to prefer the installed
  app whenever one existed, so a rebuilt helper stayed uninstalled, and a copied bundle's
  timestamp says nothing about its code); `--source installed|local|release|debug` picks one.
- Warning-free build: the pure decision functions on `WindowBehaviorView` are
  `nonisolated`, NUL-terminated C buffers decode through `String(nulTerminated:)`,
  the local PAC server adds its handlers synchronously, and the remaining Sendable and
  capture diagnostics in the kernel and tests are resolved. `CC_MD4` in NTLM stays: the
  protocol requires it.
- `Conduit --dev` (debug builds only, launched with `open -n … --args --dev`) runs the app
  over the harness's fake machine and a scratch state directory, with every port ephemeral
  and a "Popover preview" panel showing the menu bar popover, so a second instance runs
  beside the installed one for visual and VoiceOver checks with faked system settings,
  helper and credential operations. Notifications, network-path observation, scratch
  files and configured network requests remain real.
  It keeps a Dock icon and a dot badge on its menu bar glyph, and never registers the
  global shortcut system-wide. `--section`, `--vpn` and
  `--upstream` drive the states; `--dev-state-dir` puts the journal where an agent can
  read it. `FakeMachine`, `RecordingPrivilegeClient` and `FakeLoginItems` moved from the
  test target into `PlatformMac` for it.
- The helper's lifecycle (status, install, uninstall) and the credential store are seams on
  `AppState`, with a fake and an in-memory store in `PlatformMac`. The dev instance and the
  harness inject both, so neither the Settings helper controls nor the credential controls
  can reach the installed helper or the login Keychain from a fake host (#20, in part).
- The log file follows the state directory: an instance launched with `PM_CONFIG_DIR` or
  `--dev` appends to `proxy.log` beside its config instead of the installed app's
  `~/Library/Logs/Conduit/proxy.log`, which two instances used to interleave.

## 0.3.0

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
- The popover is Liquid Glass. It is chrome over the desktop, which is where the HIG puts the
  effect; the app window is content and stays on materials. The effect is applied once, to the
  panel, and the system handles Reduce Transparency on its own.
- The popover reads as one element per row under VoiceOver: "Proxy, Proxied via corp-eu-1,
  switch, on" with the health, VPN and uptime line as the hint, and "DNS forwarder,
  127.0.0.1:5353, Running, switch", instead of the state line, then the switch, then the state
  again as its value. The upstream rows say that they open Upstreams & Routing.

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
- The Overview VPN row names the tunnel: "Connected (utun4)". The VPN observer already tracked
  the interface; it now names the one carrying its verdict, the orchestrator keeps it on the
  snapshot next to the VPN state, and the diagnostics summary carries it too. The popover keeps
  the short form.
- "Failure Window" and "Connection Warn Threshold" in Advanced show the boundary's reason when
  refused, like every other field. The window must not be negative (0 still means no window),
  the threshold must be at least 1, and a threshold at or above "Connection Max Limit" is listed
  as a conflict, since connections past the limit are rejected before the threshold is checked
  and the warning could never fire.
- Validated fields line up again. Listen Host, the ports, the session limits and every number
  field in Advanced sat in a plain container that hid them from the grouped form's label
  column, so their titles wrapped onto two lines inside the field's own 220 pt frame and the
  fields did not share a trailing edge. Each is now a labelled row: title in the label column,
  field trailing at a fixed width, the boundary's reason under the field.
- The live status strips above Upstreams, DNS, Tunnels, Proxy and Authentication read label
  then value under VoiceOver ("DNS forwarder, running: queries 312, cache hit rate 84%") and
  keep their Test DNS button as a button. A refused field carries its reason as the hint as well
  as showing it underneath, decorative symbols are silent, and icon-only buttons (clear filter,
  copy log line, remove entry) are named.
- The log row's copy button is reachable again. Its accessibility description used
  `children: .ignore`, which hid the button along with the chips and message it had just
  labelled; the row now reads once through its own label while the button stays its own
  element. Hiding the upstream drag handle as decorative had taken away the only reorder
  affordance VoiceOver had, since a drag was never something it could perform — the handle is
  exposed again with Move Up and Move Down actions, one step at a time through the same
  ordering the drop delegate uses.

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
- A queued reconcile pass acts on the flags of the save that queued it. Two saves in quick
  succession, the first carrying a proxy edit plus "system proxy off" and the second turning it
  back on, used to re-apply the proxy, clear it, and apply it again: three admin-level writes
  and a transient flip for two saves. The chain of passes now lives in `RuntimeReconciler`,
  out of `AppState`, with tests for the save that lands while a pass is suspended, the pass
  that reads its own flags, and the failed action that is retried unless a later save moved
  the flag.
- The first launch after an upgrade names the resolver entry files it leaves in place. The
  scan adopts only intercept files, since an entry file's contents are exactly what a user
  writes by hand; the entry files it found for configured domains were not mentioned at all.
  The log now lists them and says to remove them by hand if an earlier release wrote them.
- Edits made while an earlier save was still being applied no longer get replaced by that
  save. The runtime echoed each applied config back into the editor, which was harmless while
  saves applied immediately and became a rollback once they queued behind one another.
- The daemon host has the same ownership guard as the app. It built its resolver manager
  without the journal, so a file it wrote was nobody's once the switch went off; a config
  reload that flipped a platform flag changed the stored value and nothing else; and its stop
  cleared only what the switches still named. `RuntimeReconciler` and the flag table move into
  `PlatformMac` and the daemon runs one pass per reload through them, so a flag flipped on disk
  applies or clears its surface at the reload, a clear the machine refused is retried by the
  next reload, and stop removes whatever the journal says is the daemon's whatever the switch
  says now (#13).
- "Manage system DNS" no longer redirects interfaces it could not capture. Every host treats a
  failed capture of the current DNS servers as non-fatal and goes on to point the interfaces at
  the relay, so one transient `networksetup` listing failure left them redirected with nothing
  to restore from, and the teardown's residue sweep then reset them to DHCP. The manager now
  refuses the redirect until a capture has landed, and redirects only the interfaces the capture
  recorded: one that appears in the window between the capture and the redirect is left for the
  next reconcile, which records an interface before it redirects it.
- The Overview VPN row could show a stale or wrong tunnel name. Both hosts read
  `connectedInterfaceName` after hopping to the main actor, so two transitions queued behind one
  another could both read whatever the monitor had already moved on to; and when the fused
  verdict stayed `.connected` while the tunnel carrying it changed (one interface gone, another
  still up), the monitor delivered nothing, leaving the old name in place indefinitely. The name
  is now read on the monitor's own delivery, and a name change re-delivers the unchanged verdict.
- The VPN observer callback held a strong reference to the monitor, and the monitor held the
  callback, so a stopped host kept its observer — and the state behind it — alive. Both captures
  are weak now.

### Testing

- `AppState` has a harness. The app's lifecycle composition — start and stop, the ownership
  guards, termination cleanup, the failed-start revert, the VPN handler and the wiring between
  the reconciler and the editor — ran only in the app until now; four of the bugs fixed above
  lived there. `AppState` takes its runtime environment, privilege client, command runner, home
  directory, resolver directory and login-item manager as parameters with production defaults,
  and the scenarios in `AppStateHarnessTests` run a real orchestrator on ephemeral ports over a
  `FakeMachine` that answers `networksetup` and `launchctl`, applies privileged writes to its own
  model and writes resolver files into a scratch directory. Assertions read the machine and the
  journal file, not `AppState` internals. One shared `RecordingPrivilegeClient` replaces the
  eight private copies the suite carried. The ownership scenarios also run against
  `DaemonRuntimeHost`, over the same fake machine; the first of them was written as a strict
  expected failure naming what the daemon lacked, and came out with the fix above.

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
