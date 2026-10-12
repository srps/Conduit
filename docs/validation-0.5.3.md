# Conduit 0.5.3 usage validation

This release includes #135's bounded Kerberos recovery and #136's VPN/browser
PAC fixes, plus candidate update compatibility preflight. Automated preparation
does not install, quit, replace, reconfigure or re-pin the serving app/helper.

Record the Mac/OS, old/new app versions, helper protocol and identity policy,
VPN client, and Chrome version with each result. Keep the configuration and
recovery journal; never include credentials, cookies or authorization tokens.

## Chrome and VPN

After the owner installs/launches 0.5.3, start a fresh Chrome process once so
it has the new stable local PAC. Keep that process open for the subsequent
cycles. With at least one enabled upstream, the browser PAC should keep pointing
at Conduit's listener while VPN state changes. Test both a deliberate disconnect
and a brief flap, then reconnect. Load a fresh tab to an external site and a
corporate site, and check existing streams separately. Repeat several cycles
without restarting Chrome or Conduit. Record failures with routing and
`tunnel.relay_failed` events; a Chrome NetLog can distinguish retained proxy
policy, DNS, and socket failures (collect without including raw bytes/cookies).
Test explicit bypasses, strict mode and disabling/re-enabling the final upstream
as separate cases. The old browser-retention mechanism was reproduced in an
isolated Chrome fixture; recovery of the installed corporate incident is still
to be confirmed.

## Kerberos (#99)

During a real service-ticket failure, retain timestamps and the bounded
`auth.kerberos_fallback_ntlm`, `auth.kerberos_recovery_started`,
`auth.kerberos_recovery_succeeded` / `auth.kerberos_recovery_failed` events.
`stage=prime` identifies a fresh worker failure; `stage=retry` means fresh
acquisition succeeded but the long-lived parent still failed. An already-cached
ticket may not generate Apple's cache-change notification, so retry success is
the recovery evidence, not child exit alone.

At recurrence, compare a fresh-process `kvno HTTP/<failing-proxy-host>` under the
same network/TGT conditions while Conduit is still failing; record the return
code/error category and timing, not ticket/token contents. Test TGT replacement,
VPN/DNS transitions, and a genuinely unreachable KDC. Attempts must stay bounded
to one recovery per minute across upstreams, and failed recovery must retain NTLM
fallback (or a clear auth failure without a saved password). Apple's published
negative-cache implementation supports the recovery design; the precise cause
of the historical corporate incident remains unconfirmed until this comparison.

## Installed updates (#111)

The first installed 0.5.2→0.5.3 update tests existing Sparkle shutdown, replacement
and relaunch. New preflight takes effect for updates initiated by 0.5.3; test a
subsequent signed candidate separately. Record normal quit cleanup, version-change
event, listener readiness, then managed proxy/DNS reapplication. Verify config,
state and saved credentials remain available. Repeat with and without helper v5,
and from a downloaded/quarantined app. Record Gatekeeper prompts honestly.

Pre-install failures (bad archive signature, unsuitable OS/architecture, helper
pin/protocol conflict, unwritable destination) must leave the old process and
bundle serving. Use a disposable test installation for destructive interruption,
replacement failure and relaunch failure; do not power-fault the daily-driver
instance. Confirm recovery settings don't point to a dead listener, and follow
the manual fallback in `release-installation.md`.

Test HTTPS feed/archive access through corporate proxy, DIRECT, and trusted
corporate CA paths with TLS verification enabled. Record both macOS 26 and 27 on
Apple Silicon where available, or explicitly record a platform waiver. Confirm
an encrypted offline backup of the release certificate and update key exists and
is recoverable according to `release-signing.md`; no private key belongs in this
record. These installed/key-custody checks are owner-run acceptance evidence,
not something unit tests or stand-in updater hosts establish.

## Existing installed update evidence

Read-only inspection on 2026-10-12 found two completed owner-initiated updates
in `~/Library/Logs/Conduit/proxy.log`. The machine currently runs macOS 26.7.1
on arm64; the serving 0.5.2 process has remained up since the second update.
The following timestamps are UTC on 2026-10-09:

| Observation | 0.5.0 → 0.5.1 | 0.5.1 → 0.5.2 |
| --- | --- | --- |
| `update.installing` | 14:35:22.248 | 22:18:28.340 |
| Scoped proxy restoration before relaunch | 14:35:22.296–22.419 | 22:18:28.478–28.653 |
| `lifecycle.version_changed` | 14:35:23.024 | 22:18:29.309 |
| Proxy listener ready | 14:35:29.027 | 22:18:35.280 |
| First scoped proxy reapplication | 14:35:29.077 | 22:18:35.338 |
| DNS forwarder ready | 14:35:29.934 | 22:18:36.343 |
| Kerberos use resumed | 14:35:29.508 | 22:18:37.484 |

This records installed replacement/relaunch, proxy restoration, reapplication
after listener readiness, and resumed corporate authentication for the earlier
updater. It does not validate the new 0.5.3 preflight, absent/conflicting helpers,
quarantine/Gatekeeper variants, DNS-settings restoration, destructive failure
recovery, credential-store preservation in all modes, or macOS 27. No update or
live-system change was performed to collect this evidence.

## 0.5.3 → 0.5.4 and Chrome usage evidence

Read-only log inspection on 2026-10-12 confirms the owner-initiated update using
0.5.3's new preflight. Times below are UTC, from the installed app's log:

| Observation | Time |
| --- | --- |
| Candidate preflight started | 18:51:13.958 |
| Candidate preflight passed | 18:51:17.273 |
| Install requested | 18:51:20.575 |
| Scoped proxy restoration before relaunch | 18:51:20.688–20.900 |
| Proxy variables and managed resolver/intercept files cleared | 18:51:21.006–21.049 |
| Version changed to 0.5.4 | 18:51:21.703 |
| Proxy / PAC listeners ready | 18:51:24.750 / 24.755 |
| DNS forwarder / transparent listener ready | 18:51:25.573 / 25.594 |

The loaded helper remained v5 with its original process. Published ZIP/DMG
checksums, update signature, release certificate, hardened runtime, bundle seal
and derived caller pin were independently verified without installation or
private-key use. This is positive installed-preflight/relaunch evidence for #111;
its negative paths, key-custody evidence and full platform matrix remain open.

After cycling VPN with Chrome kept open, the owner reported fresh tabs and
existing pages/streams were "all good". Logs show reconnect revoking VPN-off
routing before PAC/probe awaits, stable local PAC settings, old direct sockets
reporting timeouts, and fresh upstream traffic. This is one usage pass, not a
long-duration or all-path recovery claim. No real KDC-recovery recurrence was
observed, so #99 remains an acceptance item.

The same cycle exposed a monitoring gap: the first reconnect probe failed and
`upstreamsUnreachable` persisted despite subsequent upstream traffic. Its
production-timer simulator and fix are tracked in the immediate roadmap queue;
this usage observation does not establish that every probe failure was caused
by VPN route-settling timing.
