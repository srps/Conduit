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
