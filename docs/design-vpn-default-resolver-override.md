# Design: take the default resolver back from a full-tunnel VPN

Decision: [0049](decisions/0049-take-the-default-resolver-back-from-a-full-tunnel.md), revised in #330 to the combined design below: a temporary key of Conduit's own, served by a fail-safe relay in the helper. The first design rewrote the VPN client's key; [The first implementation](#the-first-implementation) lists what the combined design removed. Builds on [0044](decisions/0044-split-dns-follows-vpn-pushed-resolvers.md) and [`design-live-vpn-split-dns.md`](design-live-vpn-split-dns.md). An independent review (2026-11-19) of the first design shaped the liveness, re-trigger and restart rules that carry over; its findings are listed under [Review](#review).

## Problem

On macOS 27 a full-tunnel VPN's service is the primary service, and configd takes the default resolver from the primary service's DNS. Conduit's `127.0.0.1`, written on the physical services, is demoted to a scoped resolver. On a proxy-only corporate network the tunnel's servers answer NXDOMAIN for public names, so while connected every application that resolves through the system fails on public names. On macOS 26 the same configuration kept `127.0.0.1` as resolver #1.

## Evidence

Owner's machine, macOS 27.2.1 and 27.2, Cisco Secure Client, full tunnel. Values are masked as in the 2026-11-09 capture: `corp.example` for the pushed domain, and RFC 5737 addresses for the tunnel's servers and the test server's answer.

| Step | Default resolver | Public names | Internal names | Route and proxy |
| --- | --- | --- | --- | --- |
| Baseline | the tunnel's `192.0.2.53`, `198.51.100.53` | NXDOMAIN | resolve | via `utun`, reachable |
| A: `SearchOrder 0` on Conduit's physical-service DNS | the tunnel's | NXDOMAIN | resolve | unchanged |
| B: the tunnel's `State:` DNS `ServerAddresses` set to `127.0.0.1` | `127.0.0.1` | resolve | fail: 0.6.2 has no route to the tunnel's servers | unchanged |
| B, 10, 20 and 30 s later | `127.0.0.1` | resolve | — | the client did not rewrite the key |
| C1: a Conduit-owned `State:` service, DNS only, no `SupplementalMatchDomains` | the tunnel's | NXDOMAIN | resolve | unchanged: without `SupplementalMatchDomains` a DNS-only service contributes no resolver |
| C2: C1 plus a copy of the tunnel's IPv4 with `OverridePrimary 1` | the tunnel's | NXDOMAIN | resolve | unchanged: the client's service stays primary |
| 1: a temporary key of a held `scutil` session at `State:/Network/Service/<non-UUID id>/DNS`: `127.0.0.1`, `ServerPort 15353`, `SupplementalMatchDomains [""]`, `SupplementalMatchOrders [0]` | the test server on `127.0.0.1:15353`, resolver #1 (Supplemental); the tunnel's order 1 is #2 | every lookup reaches the test server (it answers `192.0.2.53` to every A query) for 30 s | same | unchanged; the VPN's DNS key unchanged |
| 1, after `kill -9` of the session | the tunnel's, as baseline | NXDOMAIN | resolve | configd removed the key by itself |
| 2: the same key, test server silent | the silent server | every lookup hangs 60 s | every lookup hangs 60 s | mDNSResponder does not fall back to resolver #2 |

Each experiment restored what it wrote and verified the restore. Conduit's relay and forwarder answered public names correctly throughout A to C; the system was not asking them.

configd's source (configd-1405.100.8) explains rows C1, 1 and 2. A DNS-only service contributes a resolver only with `SupplementalMatchDomains` (`get_dns_changes`). A `""` domain becomes a domainless supplemental resolver, which sorts ahead of the default (`add_supplemental`, `compareDomain`, and a stable merge sort in `dns-configuration.c`). mDNSResponder orders resolvers by search order, so `SupplementalMatchOrders 0` is required. A temporary value (`SCDynamicStoreAddTemporaryValue`) is removed by `cleanupSession` when its session dies; adding one needs root and a store opened with `kSCDynamicStoreUseSessionKeys`.

## Shape

```
VPN reading (PushedResolverMonitor)              helper (root, one thread, kevent loop)
  the VPN's own key, as the client wrote it        │
        │                                          │  own store session (session keys)
        ▼                                          ▼
VPNResolverOverridePolicy ── arm(service, ──►  override publisher ──► State:/Network/Service/<Conduit id>/DNS
  (pure; re-run on reading, health     servers)   │ armed: service, servers, owner pid      127.0.0.1, ServerPort <relay>,
   tick, relay start, helper reply)               │ (memory only)                            SupplementalMatchDomains [""],
        │                           disarm ──►    │                                          SupplementalMatchOrders [0]
        │                                         ├─ publish while: armed, owner alive, probe passes,
        │                                         │    relay up, the VPN's key a full tunnel with the armed servers
        │                                         └─ withdraw otherwise (remove own key); configd removes it if the helper dies
        ▼
PushedResolverReading.parse                    relay on 127.0.0.1 ──► Conduit's forwarder,
  ignores Conduit's own key                      or per query ──► the VPN's servers, read live from its key
```

There are two halves, each testable on its own:

- a pure publisher in `HelperSupport`, a small internal target that the helper, `FakeMachine` and pm-sim link and the kernel never imports
- a pure policy in `PlatformMac`, which the host drives

## The helper half

### The key

The helper adds one temporary value through its own SCDynamicStore session, opened with `kSCDynamicStoreUseSessionKeys`:

- **Path.** `State:/Network/Service/io.github.srps.Conduit.dns-relay/DNS` (`HelperConstants.vpnDNSOverrideServiceID`). The id is not a UUID, so the 0044 reader, which takes VPN services by UUID, never mistakes it for a pushed resolver; the reader also skips the id by name.
- **Value.** `ServerAddresses [127.0.0.1]`, `ServerPort` the fail-safe relay's port, 15353 (`HelperConstants.vpnDNSOverrideRelayPort`, neither 53 nor 5353), `SupplementalMatchDomains [""]`, `SupplementalMatchOrders [0]`. Nothing else.
- **Lifetime.** The key lives at most as long as the helper's session. A crash, `kill -9`, a reinstall or `SIGTERM` ends the session, and configd removes the key (experiment 1). A configd restart drops it too.

The helper never writes, restores or deletes the VPN client's keys, nor any key but its own.

### Publisher

The publisher (`VPNDNSOverridePublisher` in `Sources/HelperSupport`) holds, in memory only, the armed request: the VPN service, the servers the app's live set holds for it, and the owner pid. There is no record file: nothing outlives the helper that a later helper would have to undo.

It reaches the machine through two protocols, so tests drive it with fakes: `VPNDNSStore`, with `dns(service:)`, `overridesPrimary`, `primaryService`, and `publishOwnKey` (added, collision or failed), `removeOwnKey`, `ownKeyState` (present, absent or unreadable) and `closeSession` for its own key only; and `VPNDNSFailoverRelay`, the relay's listening port, its mode, its failover servers, its socket renewal, its probe, its recheck, its stop, and its count of real queries Conduit answered and left unanswered over UDP and TCP, with whether the latest went unanswered. `dns(service:)` tells a key that is absent from one that cannot be read.

**Ready.** The key is published exactly while all of these hold:

- the app armed it, and the owner has not exited
- the VPN's DNS key has `ServerAddresses` equal to the armed servers and no `SupplementalMatchDomains`, its IPv4 key has `OverridePrimary` 1, and it is the primary service
- at least one of those servers is not loopback or unspecified
- the relay is listening on both UDP and TCP
- the probe passes: not two consecutive refusals, not three consecutive silent ticks, and an answered probe within the last 30 s (`unverifiedSecondsToWithdraw`)

The publisher re-evaluates Ready after every event: an arm or disarm, a store notification for the VPN's keys or for its own key, a probe tick, the owner's exit, a relay start or stop. If Ready holds and the key is missing, it publishes; if Ready fails and the key exists, it removes it. A removal is tried whenever the key may be this session's: published, pending cleanup, or read present; a read that fails is not taken for absence. A removal the store refuses is completed by closing and reopening the session, which configd cleans up; if no read can then show the key gone, the cleanup stays pending, nothing is published, the relay is kept up failing over to the VPN's servers even after `stop-dns-relay`, and each tick tries again. A tick that cannot read the VPN's key keeps the failover servers it last validated (`failover_servers_kept`) and fails Ready (`vpn_unreadable`); only a key that is gone or changed changes them. Only a successful add makes the key this session's: a key at the path that this session did not add is `publish_collision`, left alone, and nothing is published; without an arm, a withdrawal touches only a key this session added. Republishing after a VPN republish, the end of a flap or a configd restart is one store call, and there is nothing to fight over.

**Arm.** `vpn-dns-override-arm [service, server...]` is taken only from a caller whose pid is known and whose exit the loop is now watching; one with no pid, one that has exited, or one whose `NOTE_EXIT` watch fails is declined with an error, so no key outlives an owner the helper cannot see leave. A lease was the alternative; declining needs no renewal in the versioned contract. If the watch later fails, the arm is dropped (`owner_unwatched`). The arm records intent, probes once, and replies; the helper publishes as soon as Ready holds. The servers hold no loopback or unspecified address, or the arm is refused as invalid. An arm made before the relay runs finds no relay to probe through and waits for the next answered tick. An arm from another caller replaces the earlier one; the owner is the caller that armed last.

**Disarm.** `vpn-dns-override-disarm` forgets the arm and removes the key. `stop-dns-relay` disarms first too. When that leaves the cleanup pending, the publisher defers the relay's stop (`relay_stop_deferred`) and holds every publication until the cleanup completes, when it stops the relay in the same step (`relay_stopped_after_cleanup`); a `start-dns-relay` cancels the deferred stop.

**Status.** `vpn-dns-override-status` returns the armed service and servers, whether the key is published and at which port, why not, and whether the caller asking is the one that armed.

**Tick** (every 10 s while armed or while a cleanup is pending): ask `conduit-probe.invalid.` through the relay's own listener, over UDP and over TCP, the way the system resolver reaches it. The relay sends that name to Conduit only, whatever its mode, and answers REFUSED itself when Conduit's side refuses. A half answers when the reply is NXDOMAIN with the query's ID and question; anything else is a refusal, no reply within 500 ms is silence. A tick answers only when both halves answer. An answer resets the streaks and puts the relay on Conduit. A refusal or a silence puts the relay on the VPN's servers at once; two refusals or three silences in a row fail Ready, and the key is withdrawn. A forwarder restart for a DNS edit costs one refused tick and no withdrawal. A probe whose own socket fails (`EMFILE`, say) leaves the mode alone but confirms nothing: whatever mix of outcomes the ticks give, 30 s with no answered tick fails Ready (`target_unverified` when the last was a socket failure). Once the latest real query Conduit was sent went unanswered, the failure holds across ticks: each answered probe counts as silent (`queries_unanswered`, with the recheck's outcome) and the relay stays on the VPN's servers, until Conduit answers a real query or the recheck, which asks Conduit's forwarder directly the last question it left unanswered and waits the 1 s a real query fails over on. A forwarder that answers only the probe so loses the key within the 30 s bound and never gets the lookups back on its probe answers. The bound is an age, not a tick count: Ready also fails once the last confirmed answer is older than 30 s, and the loop checks that after every event.

### Fail-safe relay

The relay runs on `127.0.0.1` over UDP and TCP, as before, and is what the key names: experiment 2 shows that a silent resolver #1 hangs every lookup, so the key never names Conduit's forwarder.

**Modes.** Off, to Conduit's forwarder, and to the VPN's servers. To Conduit while the owner is connected and the last probe answered; otherwise to the VPN's servers. A `start-dns-relay` from a caller that does not own the arm stays on the VPN's servers until a probe answers.

**The VPN's servers** are read from the VPN's own DNS key, live, at each store notification for it. Every loopback or unspecified address (`127/8`, `::1`, `0.0.0.0`, `::`) is dropped. With none left, the relay has no failover target, and Ready fails.

**Per-query failover.** Each relay also fails over per query, so a published key is answered between ticks:

- A query that Conduit's forward socket refuses (`ECONNREFUSED`, or a refusal reported as `POLLERR`) goes to the VPN's servers at once.
- When a query to Conduit has waited 1 s with no reply from Conduit since it was sent, the relay sends Conduit `conduit-probe.invalid.`, which the forwarder answers locally at once once it has admitted it. If that is not answered within 500 ms, the relay switches to the VPN's servers and sends them every query still pending for Conduit. A hung Conduit costs a lookup at most about 1.5 s plus the VPN's reply.
- The relay does not race each slow query against the VPN's servers. Conduit legitimately takes longer than 1.5 s on a name it sends from the tunnel to DoH (0044, decision 9), and the tunnel's NXDOMAIN for a public name would win the race and be cached by the system resolver. A Conduit that answers anything, even the probe name, is slow, not hung.

**Bounds.** One pending entry per client query, at most 1,024 per UDP relay (`DNSFailoverUDPRelay.maximumPendingQueries`). At the cap a new query is dropped unanswered, for the resolver to retry, and the relay logs `dns-relay udp at_capacity` on the first drop and every 100th. A failed-over query keeps its entry and its relay transaction ID, so failover adds no entries. The VPN's servers are tried one at a time, 1 s apart, at most three per query. A server whose socket cannot be made is skipped, not counted as tried, and made again after 1 s doubling to 30 s (`DNSFailoverTiming.socketRetry`, `socketRetryLimit`), logged `dns-relay failover server_unavailable` each time and `server_restored` when it is back; a send that fails outright counts as tried, drops the socket and moves on at once. When the publisher sees the primary service change, every server socket is made again and the queries sent on the old ones are asked again. An entry ends at the first matching reply from a target it was sent to, or after 10 s (`UDPRelay.staleTimeoutSeconds`). The TCP half has the same 64-session cap as the `:53` TCP relay (`HelperDaemon.dnsTCPRelayMaximumSessions`), logged `dns-relay failover tcp at_capacity`: a session takes the mode at connect, a connect Conduit refuses goes to the VPN's servers, and a session to Conduit is closed when the relay switches, so the resolver's TCP retry reaches the VPN's servers.

**No duplicate replies.** A reply is relayed only if it matches a pending entry's question and arrives on the connected socket of a target that entry was sent to; the entry is removed when it is relayed. A later reply, from Conduit or from another server, finds no entry and is dropped.

**The relay is UDP and TCP.** With Conduit's key first, every lookup on the Mac goes to the relay, including a resolver's TCP retry of an answer too large for UDP (on the owner's machine, an internal name with about 67 A records). `start-dns-relay` starts the fail-safe relay (`DNSFailoverRelay`, both halves on `127.0.0.1:15353`) beside the unchanged `UDPRelay` and `TCPRelay` on `127.0.0.1:53` that the physical services' DNS names. Each half restarts only if it is not already running for that target. A fail-safe half that cannot bind logs `dns-relay failover start_failed`, does not fail the command, and fails Ready; a `:53` TCP bind failure still leaves UDP serving and logs `dns-relay tcp start_failed`. A fail-safe half that dies is restarted at the next loop wake on the VPN's servers; until it is, or if it cannot bind, Ready fails and the key is withdrawn.

The probe uses a reserved name, not a public one. The forwarder answers `conduit-probe.invalid.` itself, at once, with a synthesized NXDOMAIN, and never forwards it (`DNSWireFormat.forwarderProbeDomain`). It answers only after admission, so at its in-flight cap the probe gets the same SERVFAIL as every lookup and the relay sees the saturation; it still answers on an unsatisfied path, so the `:53` health check does not restart relays for a network that is only down. The `one.one.one.one` probe and its 100 ms bound stay as they are for launch recovery (0041). The override probe's bound is 500 ms.

### Loop

`HelperDaemon.run`'s `kqueue` watches:

- `EVFILT_READ` on the listening socket
- `EVFILT_PROC NOTE_EXIT` on the owner's pid, the pid in the audit token of the connection that armed, while armed
- `EVFILT_SIGNAL` for `SIGTERM` and `SIGINT`
- the store session's notifications, for the VPN's keys, the primary service and Conduit's own key: the store's callback runs on a dispatch queue and triggers an `EVFILT_USER` event, so the publisher only ever runs on the loop
- a 10 s timeout while armed

Requests are still served one at a time. One request can hold the loop for up to its 30 s operation budget (`HelperSubprocess.operationMilliseconds`), so a withdrawal waits for at most one request in flight; the per-query failover answers meanwhile. The 30 s bound does not wait: each publish or confirmation sets the key's deadline in `VPNDNSOverrideExpiry`, and a watchdog thread removes the key through the store session, which a lock serializes, once the deadline passes. The loop finds the key gone when it is free and reports the withdrawal. The owner's exit is handled before the next connection, so a relaunched app's arm cannot be served ahead of the dead owner's exit.

### Contract

Three commands, within protocol v5 behind `HelperFeature.vpnDNSOverride`:

| Command | Values | Admission | Reply |
| --- | --- | --- | --- |
| `vpn-dns-override-arm` | `[service, server...]` | console user | ok, or an error for an arm out of shape |
| `vpn-dns-override-disarm` | `[]` | teardown-only (no console user needed) | ok |
| `vpn-dns-override-status` | `[]` | teardown-only | `vpnDNSOverride: {serviceID, servers, published, reason?, owned, port?}?` |

The feature's wire name is `vpn-dns-override-key`; a helper from the rewrite advertised `vpn-dns-override` and reads as lacking it. An older helper lacks the feature, and then the app never asks. The audit line records the command and the outcome, never the servers.

## The app half

### Reading the tunnel's servers

The VPN's key always holds the client's own servers, so `PushedResolverReading.parse` reads it as it is: no substitutions, and no special case for `127.0.0.1` in the VPN's key. It skips Conduit's own key by id. A loopback server in any pushed resolver is still dropped, and a key left with none is rejected with `reason=self_referential`.

### Policy

`VPNResolverOverridePolicy` is a pure function from the reading, the servers in use (the 0044 live set), the gate, "Manage system DNS", the relay's health, helper support and the helper's status, to `none`, `arm(service, servers)` or `disarm`.

It **arms** when the helper supports the commands, "Manage system DNS" is on, the relay serves, the gate wants entries, exactly one resolver in the reading has `overridesPrimary`, and that service's servers are all in the live set in use. It **disarms** when any of these stops holding, before the live set drops the armed servers. Arming again with the same service and servers is a no-op, and the helper handles the VPN's republishes, flaps and configd restarts itself.

**Retired.** The caps (`maximumApplies`, `cap=applied`), suspensions and `suspensionLifetime`, `minimumApplySpacing`, the same-server rewrite detection (`keyRewritten`), the hold of the override through a flap and the re-apply backoff. Each bounded a fight over the client's key, which no longer happens. The 0044 flap hold of the live set stays.

**Unconfirmed arms.** An arm whose reply was lost, or that failed in flight, counts as armed until a `status` shows otherwise, so a set without its servers waits for a disarm.

### When the policy runs

1. In `RuntimeHostSplitDNSDetection.applyPendingSplitDNSDetection`. When the action is a disarm, it is sent first, and the new live set is applied after it. When the action is an arm, the live set is applied first. A set that arrives while the override may be armed is held until the disarm returns.
2. From the 30 s DNS health timer, which also polls `vpn-dns-override-status` while an arm is expected.
3. After every successful relay start: `startDNSModule`, a relay restart, and "Manage system DNS" turned on.

### Disarm ahead of every clear

The "Manage system DNS" toggle and the DNS module teardown (Stop and Quit) disarm before they restore system DNS or stop the relay. The helper's own disarm on `stop-dns-relay` is the backstop.

### Resolver order check

With the key published, the app reads resolver #1 from `scutil --dns` (`ScutilResolverOrder`, behind `ResolverOrderReading`, run on the platform work queue) after each status, and emits `dns.vpn_override_not_first` when it is not `127.0.0.1` at the key's port. It changes nothing on its own: the event is for diagnosis of a macOS change to the undocumented order.

### Events

These go in `docs/events.md` under `### health`:

- `dns.vpn_override_armed service= servers=N`, `dns.vpn_override_disarmed reason=` (`gate`, `not_in_use`, `manage_off`, `relay_not_serving`, `stop`)
- `dns.vpn_override_published` and `dns.vpn_override_withdrawn reason=` (`owner_exited`, `owner_unwatched`, `target_refused`, `target_silent`, `target_unverified`, `vpn_changed`, `relay_stopped`, `disarmed`, `helper_stopping`), seen through `status`
- `dns.vpn_override_failed operation= reason=`: a helper call did not complete
- `dns.vpn_override_not_first`: resolver #1 is not Conduit's key

The rewrite's `dns.vpn_override_applied`, `_released`, `_refused`, `_suspended`, `_suspension_expired` and `_restore_pending` are retired.

## What can go wrong

| Failure | State after | Bound |
| --- | --- | --- |
| App crashes or is killed | lookups fail over per query; the helper withdraws on `NOTE_EXIT` | per query at once; withdrawal at the next loop wake |
| App hangs, forwarder's loop stuck | lookups fail over per query; withdrawal after three silent ticks | per query ≤ 1.5 s; withdrawal ≤ 30 s |
| Forwarder gone, relay up | lookups fail over per query on the refusal; withdrawal after two refused ticks | per query at once; withdrawal ≤ 20 s |
| Forwarder restarts for a DNS edit | one refused tick: lookups go to the VPN's servers until the next answered probe | — |
| Relay half dies | restarted on the VPN's servers; if it cannot bind, the key is withdrawn | next loop wake |
| Helper crashes, is killed or reinstalled | configd removes the key with the session | at once |
| Helper hangs with the key published | lookups to the relay hang | unbounded (residual) |
| VPN disconnects, flaps or rewrites its servers | the key is withdrawn at the store notification, republished when the key matches the armed servers again | one helper event |
| configd restarts | the key is gone; the helper republishes it on its own key's notification | one helper event |
| macOS changes the resolver order | Conduit's key is not #1; `dns.vpn_override_not_first` | the next check |
| Lookups scoped to the tunnel's interface | go to the tunnel's servers, not to Conduit | — |

**Known cost.** Names outside the pushed domains change behaviour; for this VPN, that's anything outside `corp.example`'s pushed search domain.

- Today mDNSResponder asks every tunnel server for every such name.
- With the override, the forwarder makes one 1.5 s attempt on `firstServers` and then goes to DoH (decision 9 of 0044), and it caches a DoH NXDOMAIN for a name it doesn't know to be internal.
- A tunnel server that answers within 1.5 s still resolves such names. A manual split-DNS entry for the parent domain restores the old behaviour for it.

## The first implementation

#330 first implemented alternative A of 0049: the helper rewrote `ServerAddresses` in the VPN's key to `127.0.0.1` and restored it on release, with a record file under `/var/run`, compare-then-write on both sides, a pending restore retried on each tick, and the app-side caps, spacing and suspensions. The combined design replaced all of it:

- The ledger, its record file and the policy's caps, suspensions, spacing, backoff and same-rewrite detection are gone, as is the reading's substitution of `127.0.0.1`.
- A helper from the rewrite may have left its record. A helper from this design reads it at start (`VPNDNSOverrideLegacyRestore.check`) and logs `awaiting_recovery` as an error naming the manual step; it writes nothing and keeps the record. The manual step is either reconnecting the VPN, whose client writes its own servers, or `sudo /Library/PrivilegedHelperTools/io.github.srps.Conduit.Helper --restore-legacy-vpn-dns`, which runs `VPNDNSOverrideLegacyRestore.run` once: if the VPN's key still holds `127.0.0.1`, it writes the saved servers back over it and then deletes the record. The write is compare-then-write, not atomic: the key is read just before, a client write between the read and the write loses to the restore, and nothing is ever deleted from the key; that is why nothing runs it unasked. A key the client has rewritten or removed is left alone and the record deleted. A key or record that cannot be read, a write the store refuses, or a delete that fails keeps the record for another run. A record that is read but malformed (a link, over 16 KiB, not JSON or out of shape) is renamed to `vpn-dns-override.json.malformed` beside it rather than deleted: it may hold the only copy of the VPN's original servers, and once renamed it is never read again.

## Verification

- **Publisher unit tests** (`VPNDNSOverridePublisherTests`), over a fake store and a fake relay: Ready's every condition; publish and withdraw on each event; republish after a configd restart and after a flap; a refused removal closing the session; loopback servers dropped.
- **Relay tests** (`DNSFailoverRelayTests`), over loopback stand-in servers: per-query failover on a refusal and on a silent forwarder; the pending cap and its log; first reply wins, later replies dropped; TCP sessions follow the mode.
- **Policy and parser tests**: arm and disarm, the ordering against the live set, unconfirmed arms; Conduit's own key ignored.
- **`FakeMachine`** runs the real publisher over an in-memory session store, so pm-sim exercises the helper's logic.
- **pm-sim scenarios**: `dns-vpn-override-publishes` (the key once the live set is in use), `dns-own-key-conduit-gone` (lookups answered by the VPN's servers at once, the key withdrawn on the owner's exit), `dns-own-key-conduit-hung` (a hung forwarder within the probe's budget), `dns-own-key-conduit-probe-only` (a forwarder that answers only the probe name), `dns-legacy-record-awaits-recovery`, `dns-own-key-helper-dies`, `dns-own-key-configd-restart`, `dns-vpn-override-flap` (each flap and republish, and the order check), `dns-vpn-override-disconnect`, `dns-vpn-override-stop` (Stop and "Manage system DNS" off), `dns-vpn-override-split-tunnel`, `dns-vpn-override-tcp-bind-fails`, `dns-own-key-cleanup-pending` and `dns-failover-server-socket-recovers`.
- **TLA+**: `formal/vpn-detection/VPNDNSOverride.tla`, run by the same `check.py` as the detection spec, describes the code.
  - **State**: the VPN's key and service, the gate, Conduit's key, the helper (up or down, its arm, its probe streaks, its view of the store), the relay's mode, Conduit's forwarder (serving, refusing, silent) and the app's reading, live set and arm.
  - **Invariants**: `KeyAnswered` (whenever Conduit's key exists, the helper and relay run and the VPN publishes servers, every lookup is answered by Conduit or by the VPN's servers), `VPNKeyUntouched`, `NoLoopbackTarget`, `KeyWithdrawn` (once the helper has handled every event, the key exists only for a live owner and a usable VPN), `InternalNamesServed`, `NoSelfReference`.
  - **Liveness**: `EventuallyWithdrawn` (a key Conduit does not serve is withdrawn) and `KeyReturns` (a key dropped while Conduit could serve comes back).
  - **Mutants**: no per-query failover, the key naming Conduit directly, failover to loopback, the key kept after the owner's exit, no `NOTE_EXIT`, no republish after a configd restart, writing the VPN's key, reading Conduit's own key, arming before the live set, a set dropped before the disarm, an unconfirmed arm kept, and ticks that never withdraw.
- **Owner checks, on the real VPN on macOS 27**: connect (public and internal names resolve, Conduit's key is resolver #1); disconnect (the key is gone); reconnect; sleep and wake; a Wi-Fi roam; DNS Stop and "Manage system DNS" off (the key goes at once); Quit; `kill -9` of the app (lookups keep resolving through the VPN's servers, and the key goes within seconds); `kill -9` of the helper (configd removes the key); `sudo launchctl kickstart -k` of the helper; a soak of several hours connected.

## Review

An independent review of the first draft (2026-11-19) raised these points, all taken:

- the public-name relay probe as a liveness signal, replaced by a local probe name
- no policy re-run on non-reading inputs, now covered by the health tick, relay starts and helper replies
- helper releases invisible behind reading deduplication, now carried by the helper's `status`
- a record kept across a helper restart while the relay is gone, now moot: the key dies with the helper's session
- unbounded re-applies against the client, now moot: Conduit no longer writes the client's key
- an unspecified internal relay restart
- `SIGTERM` handled in a signal handler, moved to `EVFILT_SIGNAL`
- the "Manage system DNS" toggle using a different clear path than teardown, now disarmed explicitly ahead of both
- withdraw order on a blind gate, now disarm before the set drops
- weaker coverage of internal names outside the pushed domains, recorded above
- the delete race, three commands instead of value-aware admission, loopback as `127/8` and `::1`, and a separate TLA+ spec

The review found the following fine as designed:

- `SystemDNSManager.reconcile`, location reconcile and launch recovery: none of them touches a VPN's `State:` key.
- the 0044 flap hold and 0048 withholding
- the helper's probe of the forwarder's own port, which isn't affected by this machine's swallowed `:53`
- versioning within v5
- checking IPv4 primacy only
