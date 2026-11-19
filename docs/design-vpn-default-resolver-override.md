# Design: take the default resolver back from a full-tunnel VPN

Decision: [0049](decisions/0049-take-the-default-resolver-back-from-a-full-tunnel.md). Builds on [0044](decisions/0044-split-dns-follows-vpn-pushed-resolvers.md) and [`design-live-vpn-split-dns.md`](design-live-vpn-split-dns.md). An independent review (2026-11-19) shaped the liveness, re-trigger and restart rules below; its findings are listed under [Review](#review).

## Problem

On macOS 27 a full-tunnel VPN's service is the primary service, and configd takes the default resolver from the primary service's DNS. Conduit's `127.0.0.1`, written on the physical services, is demoted to a scoped resolver. On a proxy-only corporate network the tunnel's servers answer NXDOMAIN for public names, so while connected every application that resolves through the system fails on public names. On macOS 26 the same configuration kept `127.0.0.1` as resolver #1.

## Evidence

Owner's machine, 2026-11-19, macOS 27.2.1, Cisco Secure Client, full tunnel. Values are masked as in the 2026-11-09 capture: `corp.example` for the pushed domain, and RFC 5737 addresses for the tunnel's servers.

| Step | Default resolver | Public names | Internal names | Route and proxy |
| --- | --- | --- | --- | --- |
| Baseline | the tunnel's `192.0.2.53`, `198.51.100.53` | NXDOMAIN | resolve | via `utun`, reachable |
| A: `SearchOrder 0` on Conduit's physical-service DNS | the tunnel's | NXDOMAIN | resolve | unchanged |
| B: the tunnel's `State:` DNS `ServerAddresses` set to `127.0.0.1` | `127.0.0.1` | resolve | fail: 0.6.2 has no route to the tunnel's servers | unchanged |
| B, 10, 20 and 30 s later | `127.0.0.1` | resolve | — | the client did not rewrite the key |
| C1: a Conduit-owned `State:` service, DNS only | the tunnel's | NXDOMAIN | resolve | unchanged |
| C2: C1 plus a copy of the tunnel's IPv4 with `OverridePrimary 1` | the tunnel's | NXDOMAIN | resolve | unchanged: the client's service stays primary |

Each experiment restored what it wrote and verified the restore. Conduit's relay and forwarder answered public names correctly throughout; the system was not asking them.

## Shape

```
VPN reading (PushedResolverMonitor)            helper (root, one thread, kevent loop)
        │                                          │
        ▼                                          │
VPNResolverOverridePolicy ── apply(service, ──►  VPNDNSOverrideLedger ──► State:/Network/Service/<id>/DNS
  (pure; re-run on reading, health      expected)   │ record: service, originals    ServerAddresses = [127.0.0.1]
   tick, relay start, helper reply)                 │ (memory + /var/run file)
        │                             release ──►   ├─ owner exit (EVFILT_PROC)      ─┐
        │                                           ├─ relay stopped / restart failed ├─► release (compare first)
        ▼                                           ├─ probe refused or silent, ticks ├
PushedResolverReading.parse(substitutions:)         ├─ SIGTERM (EVFILT_SIGNAL)        │
  127.0.0.1 → originals, overridden = true          └─ helper start: always          ─┘
```

There are two halves, each testable on its own:

- a pure ledger in `ConduitShared`, which both the helper and `FakeMachine` run
- a pure policy in `PlatformMac`, which the host drives

## The helper half

### Ledger

`VPNDNSOverrideLedger` (`Sources/ConduitShared/VPNDNSOverrideLedger.swift`) holds at most one record:

```swift
package struct VPNDNSOverrideRecord: Codable, Equatable, Sendable {
    package var serviceID: String      // [A-Za-z0-9._-]{1,128}
    package var originals: [String]    // IP literals, 1...16, none loopback (127/8, ::1)
}
```

It reaches the machine only through two protocols, so tests drive it with fakes:

```swift
package protocol VPNDNSStore {        // SCDynamicStore in the helper, a dictionary in tests and FakeMachine
    func dns(service: String) -> [String: VPNDNSValue]?
    func ipv4Exists(service: String) -> Bool
    func overridesPrimary(service: String) -> Bool
    func primaryService() -> String?
    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool
    // No remove: the ledger never deletes the client's key (see below).
}
package protocol VPNDNSForwarderProbe {   // the relay on 127.0.0.1:53
    func probe() -> VPNDNSProbeVerdict     // a UDP query to the target: .notRunning, .answered, .refused, .silent, .failed
    func tcpListening() -> Bool            // whether the TCP relay holds 127.0.0.1:53
}
```

**The relay is UDP and TCP.** With the key at `127.0.0.1`, every lookup on the Mac goes to the relay, including a resolver's TCP retry of an answer too large for UDP (on the owner's machine, an internal name with about 67 A records). `start-dns-relay` therefore runs two relays from `127.0.0.1:53` to `127.0.0.1:<target>`: `UDPRelay`, and a `TCPRelay` bound to `127.0.0.1` that carries each length-prefixed DNS-over-TCP stream to the forwarder's TCP listener on the same port. Each half restarts only if it is not already running for that target, and `stop-dns-relay` stops both. The TCP relay holds at most 64 sessions (`HelperDaemon.dnsTCPRelayMaximumSessions`, the forwarder's own cap); past that it closes a new connection unanswered, before connecting it to the target, and logs `dns-relay tcp at_capacity` on the first refusal and every 100th.

A UDP bind failure fails the command and stops TCP too. A TCP bind failure does not fail the command and leaves UDP serving, as before TCP was relayed. It logs `dns-relay tcp start_failed listen=127.0.0.1:53 target=127.0.0.1:<port> udp=running error="..."`, `dns-relay-status` reports `tcpListening: false`, the ledger refuses an apply with `relay_not_serving`, and a held record is released. The next `start-dns-relay` retries TCP alone. `dns-relay-status` carries `tcpListening` as an optional field within protocol v5: an older helper omits it, and an older client ignores it.

The ledger checks liveness with a reserved name, not a public one. The forwarder answers `conduit-probe.invalid.` itself, at once, with a synthesized NXDOMAIN, and never forwards it (`DNSWireFormat.forwarderProbeDomain`). A reply proves that the forwarder's event loop is alive, whatever DoH or the tunnel are doing. The existing `one.one.one.one` probe and its 100 ms bound stay as they are for launch recovery (0041); the override does not use them. The override probe's bound is 500 ms.

#### Operations

All of these run on the helper's one thread.

**`apply(service:expected:)`** refuses, with a reason, unless all of the following hold:

- `service` names an existing DNS key that has `ServerAddresses` (`not_found`).
- Its IPv4 key has `OverridePrimary` 1 (`not_full_tunnel`).
- `primaryService()` is `service` (`not_primary`).
- The key has no `SupplementalMatchDomains` (`not_full_tunnel`).
- The key's current `ServerAddresses` equal `expected` exactly (`changed`), and `expected` holds no loopback address (`invalid`).
- The relay is listening on both UDP and TCP, and the probe answers (`relay_not_serving`).

If they hold, it persists the record first. It then reads the key again: the probe can take up to about 2 s, so a key that no longer equals the first read means the client wrote it meanwhile, and the ledger forgets the record and refuses `changed`. Otherwise it writes the key back field for field, with `ServerAddresses = [127.0.0.1]`. After the write it checks that the service's IPv4 key still exists. If it does not (the client removing the service, or a flap), it writes the originals back over its own `127.0.0.1`, holds nothing and refuses `not_found`. It never removes the key.

**`release(reason:)`**:

- If the key still holds exactly `[127.0.0.1]`, it writes the originals back, field for field.
- If the key holds anything else, or is gone, it writes nothing.
- A restoring write is the last thing a release does. It never removes the key afterwards, even when the service's IPv4 key is absent: mid-flap that key is briefly gone, and a deleted DNS key is not republished (owner's machine, 2026-11-19: the Mac was left with no default resolver). A key recreated for a service the client really removed holds the originals and is inert.

It then drops the record and deletes the file, unless the restoring write failed (`restore_failed`). Then it keeps the record and its file and marks the restore pending, so the key at `127.0.0.1` still has something behind it; the next tick retries the release, with the same reason, before any probe, one retry per tick. A `key_changed` or `key_gone` result still drops the record, as the client owns the key then. While a restore is pending, an apply first retries it, and refuses `write_failed` if it fails again: the ledger never holds two records, and never overwrites the file of a pending one. The log line reads `write=restore_failed restore_pending=next_tick`, and `status` carries the pending reason. The reasons are `requested`, `owner_exited`, `relay_stopped`, `target_refused`, `target_silent`, `helper_stopping` and `helper_start`.

**`status()`** returns the service and the originals, or nil.

**`tick()`** runs every 10 s while a record exists:

- A restore is pending: retry the release, and nothing else this tick.
- The TCP relay is not listening, or the UDP relay is not running: release with `relay_stopped`.
- The probe is refused on two consecutive ticks: release with `target_refused`, at most 20 s after the forwarder went away. A single refusal is a forwarder restart in progress.
- The probe is silent on three consecutive ticks: release with `target_silent`, at most 30 s. The probe never waits on DoH or the tunnel, so a silent reply means the forwarder's event loop isn't running.

**Relay restarts.** `start-dns-relay` with a new target port, or over a relay that died in place, restarts the relay inside the helper. The record is kept across that restart, and the next tick probes the new target. If the restart fails, on UDP or on TCP, the ledger releases with `relay_stopped`. `stop-dns-relay` releases before it stops the relay.

#### The compare-then-write window

Apply and release each compare, then write. SCDynamicStore has no atomic swap, so a client write in the microseconds between the read and the write is overwritten:

- **Apply.** Apply's last read is the one after the probe and the record's save, so its window is that read to the write. A client write inside it is overwritten with `127.0.0.1`, and the record holds the servers apply read. A later release writes those back rather than the client's newest.
- **Release.** A client write between release's read of `127.0.0.1` and its write gets the originals written over it.

In both cases the client republishes on its next change, and the app re-applies against what it then reads. This is recorded, not closed. The precise rule the rest of the design keeps (`NoClobber` in the model): an apply overwrites only the value it read and found equal to the caller's servers, a release overwrites only the `127.0.0.1` it wrote, and any other overwrite is a client write inside one of these two windows.

**A key holding the originals for a gone service is left alone.** A restore that lands after the client removed the service recreates its DNS key holding the originals. The ledger does not remove it: a reconnecting client publishes exactly that shape, DNS before IPv4, and mid-flap the IPv4 key is briefly absent too, so a removal cannot tell the cases apart. A DNS key for a service with no IPv4 key is inert to configd.

### Persistence and helper start

The helper writes the record to `/var/run/io.github.srps.Conduit.Helper/vpn-dns-override.json` with `CanonicalJSON`. The file is mode 0600 and owned by root.

`/var/run` is cleared at boot, exactly like the `State:` key it describes. The file exists for one reason: a helper that crashes, or is replaced by a reinstall, must still be able to restore the originals.

At start the helper always releases (`helper_start`). The relay lives in the helper's memory, so a fresh helper has no relay, and a key left at `127.0.0.1` would be unserved. The app re-applies once its next relay start and its policy run succeed. A file that can't be decoded is deleted and logged, and the key is left alone, because the originals are unknown; the client's next write heals it.

### Loop

`HelperDaemon.run` replaces its blocking `accept` with a `kqueue` that watches:

- `EVFILT_READ` on the listening socket
- `EVFILT_PROC NOTE_EXIT` on the owner's pid, the pid in the audit token of the connection that applied, while a record exists
- `EVFILT_SIGNAL` for `SIGTERM` and `SIGINT`, in place of today's `signal()` handlers, so the release runs on the loop and not in a signal handler
- a 10 s timeout while a record exists, and none otherwise

Requests are still served one at a time, on no thread. One request can hold the loop for up to its 30 s operation budget (`HelperSubprocess.operationMilliseconds`), so every bound below includes "plus up to one request in flight". If `EVFILT_PROC` registration fails with `ESRCH`, the owner is already gone, and the ledger releases with `owner_exited`. A pid reused after exit doesn't matter, because `NOTE_EXIT` was registered while the owner was alive.

### Contract

Three commands, added within protocol v5 behind `HelperFeature.vpnDNSOverride`, exactly as `dns-relay-status` was added:

| Command | Values | Admission | Reply |
| --- | --- | --- | --- |
| `vpn-dns-override-apply` | `[service, server...]` | console user | ok, or `refusal` with a reason |
| `vpn-dns-override-release` | `[]` | teardown-only (no console user needed) | ok |
| `vpn-dns-override-status` | `[]` | teardown-only | `vpnDNSOverride: {service, originals}?` |

An older helper lacks the feature, and then the app never asks. The audit line records the command and the outcome, never the servers.

## The app half

### Reading the tunnel's servers

`PushedResolverReading.parse(store:substitutions:)` takes `[serviceID: [String]]`:

- **A loopback server (`127/8`, `::1`) is never a tunnel server.** A key whose `ServerAddresses` are `[127.0.0.1]`, for a service in `substitutions`, reads as the substitution, and the resolver carries `overridden = true`.
- Otherwise every loopback address is dropped, and a key left with no servers is rejected with `reason=self_referential`.

`overridden` is part of the reading's equality. When the helper releases on its own, the next reading differs (`overridden` goes from true to false), and the deduplication in `PushedResolverMonitor.deliver` lets it through.

`PushedResolverMonitor` takes its substitutions from a locked box on the override controller. The box is set before the apply is sent and cleared after a release. A notification for the helper's own write can therefore never be read with the wrong servers. The monitor takes the box on both sides of its store read and parses with both, the later one winning for a service in each: a read that spans an apply has the service only in the later box, and a read that spans a release only in the earlier one. With one side alone such a read rejects the key as `self_referential`, a reading with no full tunnel caused by the helper's own write (found by the TLA+ model).

### Policy

`VPNResolverOverridePolicy` (`Sources/PlatformMac/VPNResolverOverridePolicy.swift`) is a pure function:

```swift
package enum VPNResolverOverrideAction: Equatable { case none, apply(service: String, expected: [String]), release(String) }
package static func decide(_ input: VPNResolverOverrideInput) -> VPNResolverOverrideAction
// input: reading, servers in use (0044 live set), gate wants entries, relay serving, manageSystemDNS,
//        helper supports, helper status, applies in the last 10 min for the service, backoff deadline
```

It **applies** when all of these hold:

- The helper supports the command, "Manage system DNS" is on, and the relay serves.
- The gate wants entries.
- Exactly one resolver in the reading has `overridesPrimary`.
- That service's servers are in the live set in use (0044), so internal names have the tunnel's servers before public names are taken from them.
- No current record matches it.
- No backoff is pending.
- No cap is reached for that service in the last 10 minutes (below).

No current record matches when the record's key was rewritten in place: a reading after the helper's write (one that showed the key overridden) shows the client's own servers in it, and the helper's `status` still holds the record. A client can do this inside a flap, with the same servers, or on its own. The controller asks for `status` on such a reading and then applies again; a reading that leaves the service out says nothing about the key and asks nothing.

**Re-apply.** The controller keeps, per service, the last apply that landed: when, and against which servers. An apply whose reply was lost lands when a later `status` shows the helper holding it: it is counted then, once, as its reply would have counted it, and `dns.vpn_override_applied` carries `confirmed=status`. A `status` that holds the record with a restore pending emits `dns.vpn_override_restore_pending` once; the controller keeps its record until the helper's restore lands.

- **Same servers.** An apply against the servers of the last landed apply is the client re-asserting its value. It counts toward no cap and never suspends.
- **Spacing.** An apply for one service comes at least 10 s after the last apply that landed for it (`minimumApplySpacing`). An apply due sooner is `.wait(until:)`: the controller arms one wake through its injected sleep, and the pass the wake runs decides again. A rewrite after a quieter spell is applied at once. This is the only bound on same-server re-applies: a client that rewrites the instant the helper writes gets at most 6 helper writes a minute. A refused apply wrote nothing, so it is not spaced: the republish after a flap's `not_primary` is applied at once.
- **Changed servers** are the client answering the override, and keep the cap below.

**Cap.** One history per service, counted over the last 10 minutes, ending at its bound in `dns.vpn_override_suspended service= cap=`, once:

| History | Counts | Bound | `cap=` | Bounds |
| --- | --- | --- | --- | --- |
| applies | applies that landed against servers other than the last landed apply's | 3 (`maximumApplies`) | `applied` | a client that answers each override with new servers |

Applies that did not land (refused, `write_failed`, unanswered or an unexpected reply) count toward no cap and never suspend. A refusal arms no wake and asks for no pass, so attempts follow the triggers: at most one per store reading, 30 s DNS health tick, relay start or wake armed for something else. A persistent `not_primary` with a quiet client costs one attempt per health tick. The host's pass loop runs again only for a request that arrived meanwhile, or once after a held set is applied (itself the result of a reading).

A suspension ends after 10 minutes (`suspensionLifetime`), with `dns.vpn_override_suspension_expired service=`, or silently when the gate turns off or DNS is stopped and started. Every apply that reached the cap has then left the window, and the policy decides afresh. The controller arms a wake for the expiry; the 30 s health tick would also see it.

It **releases** when a record exists and any of those conditions stop holding, with one exception, the hold.

**Hold through a flap.** On the owner's machine (2026-11-19, 11:33:07 and 11:58:22) Cisco withdrew `State:/Network/Service/com.cisco.anyconnect/IPv4` inside a flap while its DNS key still held `127.0.0.1` (the helper's release logged `write=restored_then_removed`: it restored over `127.0.0.1`, then found no IPv4 key) and its IPv6 key still named the `utun`. With no `OverridePrimary` the full-tunnel domain rule does not apply, the key has no `SupplementalMatchDomains`, and the parser ignored it (`no_match_domains`); 0044 held the set (`outcome=held`). The first build read that as "no single full tunnel" and released. Now, while the gate wants entries, a reading keeps the override (`.none`) when:

- it shows no full tunnel, and nothing for the record's service (absent, or ignored by the parser)
- every one of the record's originals is in the servers in use

It still releases on a different full tunnel, on the record's service read as a split tunnel, on a set that loses any original, on the gate, on "Manage system DNS" off and on the relay. `ReleaseBeforeUnset` holds through the hold: the servers in use are the forwarder's set intersected with any set held for the pass, the host decides against each new set before applying it (`vpnDNSOverrideReleases(before:)`), and a set that drops an original is held until the release returns.

**Backoff.** A release the helper made on its own (`target_refused`, `target_silent` or `relay_stopped`), seen through `status`, sets a backoff of 60 s that doubles up to 10 minutes and is reset by a successful apply. A refusal with `relay_not_serving` does the same. This prevents an apply-and-release cycle while the forwarder is unhealthy.

There is no new preference. "Manage system DNS" already means "Conduit is the Mac's resolver", and turning it off releases the override.

### When the policy runs

A reading isn't the only input, so the policy runs at each of these points:

1. In `RuntimeHostSplitDNSDetection.applyPendingSplitDNSDetection`.
   - When the action is a **release**, it is sent first, and the new live set is applied after it. The default resolver must never be `127.0.0.1` while the tunnel's servers are missing from the forwarder.
   - When the action is an **apply**, the live set is applied first.
   - A set that arrives while a pass is out is held for it, and decided on again before it is applied (`runVPNDNSOverride`): the pass may have made a record the set would leave unserved, as an apply that was out when the gate turned off. The release then goes first, in one more pass. If that release fails too, the set stays held until the next reading or health tick, so a failing helper costs one call per trigger.
2. From the 30 s DNS health timer (`handleDNSHealthResult`), which also polls `vpn-dns-override-status` while a record is expected. This catches a helper-initiated release, a refused apply, and a reading that arrived before the relay started.
3. After every successful relay start: `startDNSModule`, a relay restart, and "Manage system DNS" turned on.

Helper calls run on `platformWork`.

### Release ahead of every clear

Both of these release the override first, before restoring system DNS or stopping the relay, and outside the guards that can skip `clear`:

- `.clearSystemDNS`, the "Manage system DNS" toggle (`RuntimeHost.swift:2175`)
- the DNS module teardown (`RuntimeHostLifecycle.swift:760-775`), used on Stop and Quit

The helper's own release on `stop-dns-relay` is the backstop, not the mechanism.

### Events

These go in `docs/events.md` under `### health`:

- `dns.vpn_override_applied service= servers=N`
- `dns.vpn_override_released reason=`. The reason is `requested`, `gate`, `not_in_use`, `manage_off`, `stop`, or `helper:<helper reason>` when the policy saw a release the helper made.
- `dns.vpn_override_refused reason=`: the helper refused an apply.
- `dns.vpn_override_suspended service= cap=`: a cap was reached; it lasts 10 minutes.
- `dns.vpn_override_suspension_expired service=`: a suspension reached its lifetime.
- `dns.vpn_override_failed operation= reason=`: the helper was unreachable, or a write failed.

`dns.split_resolver_ignored` gains `reason=self_referential`. Releases the helper makes while the app is gone appear only in the helper's audit log.

## What can go wrong

Each bound adds up to 30 s for one helper request already in flight.

| Failure | State after | Bound |
| --- | --- | --- |
| App crashes or is killed | helper releases on `NOTE_EXIT` | next loop wake |
| App hangs, forwarder's loop stuck | three silent ticks | ≤ 30 s |
| Forwarder gone, relay up | two refused ticks | ≤ 20 s |
| Forwarder restarts for a DNS edit | one refused tick, no release | — |
| Relay restart fails | release with `relay_stopped` | immediate |
| TCP relay cannot bind at a start | UDP serves; the apply is refused, a held record released | immediate |
| TCP relay dies in place | release with `relay_stopped` | next tick, ≤ 10 s |
| Helper crashes or is reinstalled | the new helper releases at start, from the file | helper start |
| Helper and app both gone, no restart | key stays at `127.0.0.1` until the client's next write, a reconnect, or a reboot | — |
| Client rewrites the key with the same servers | the app re-applies, with no cap, at most once every 10 s | one reading, or the rest of the 10 s spacing |
| Client rewrites the key with new servers | the app re-applies at most 3 times in 10 min, then suspends for 10 min | one reading |
| Client withdraws its IPv4 key in a flap | the override holds while the live set holds the servers; a republish with the same servers re-applies as above | one reading |
| The helper refuses every apply (`not_primary` and the rest) | never suspends; at most one attempt per reading or tick | — |
| Client deletes the key mid-release | the restore recreates it holding the originals; inert, never removed | immediate |
| VPN disconnects | the client removes the key; release writes nothing | — |
| configd restarts | the client rebuilds the key; the app re-applies | one reading or tick |
| Read/write race with the client | release restores the servers read, not the newest | the client's next write |
| The restoring write fails | the record and its file are kept; the next tick retries before probing | next tick, ≤ 10 s |

The only row that leaves `127.0.0.1` with nothing behind it is the helper and the app both gone with no restart. That double failure leaves system DNS in the same state today (#274).

**Known cost.** Names outside the pushed domains change behaviour; for this VPN, that's anything outside `corp.example`'s pushed search domain.

- Today mDNSResponder asks every tunnel server for every such name.
- With the override, the forwarder makes one 1.5 s attempt on `firstServers` and then goes to DoH (decision 9 of 0044), and it caches a DoH NXDOMAIN for a name it doesn't know to be internal.
- A tunnel server that answers within 1.5 s still resolves such names. A manual split-DNS entry for the parent domain restores the old behaviour for it.

## Verification

- **Ledger unit tests**, over a fake store, a fake probe and a fake clock:
  - every refusal reason
  - the compare-then-write on apply and on release, and the re-read after the probe
  - a failed restore kept, retried on the next tick, and blocking an apply to another service
  - field-for-field preservation
  - the delete race
  - each release trigger, and the tick thresholds: one refused tick and no release, then two; three silent ticks
  - the record kept across a relay restart
  - persistence round-trip, an undecodable file, and the release at start
- **Policy unit tests**: the decision table, including:
  - a split tunnel
  - two full tunnels
  - a live set without the tunnel's servers
  - the relay not serving
  - the backoff
  - the cap and suspension
  - release ordered before the set change
- **Parser tests**: substitution, `overridden` in equality, loopback rejection across `127/8` and `::1`, and `self_referential`.
- **Forwarder test**: `conduit-probe.invalid.` is answered locally, under a blackholed upstream and a blackholed DoH.
- **`FakeMachine`** runs the real ledger over an in-memory store, so pm-sim exercises the helper's logic.
- **pm-sim scenarios**:
  - `dns-vpn-override-applies`: a full tunnel connects; the override lands after the live set is in use, and internal names go to the tunnel's servers.
  - `dns-vpn-override-client-rewrite`: the app re-applies against the new servers, suspends after the third in 10 minutes, and applies again when the suspension expires 10 minutes later.
  - `dns-vpn-override-flap`: the owner's 11:33 and 11:58 Cisco flaps, then two more inside 10 minutes: the override holds through each withdrawal, a `not_primary` refusal costs no apply and the republish after it re-applies at once, each republish puts the relay back, one inside the 10 s spacing after a landed apply waits for it, and nothing suspends.
  - `dns-vpn-override-republish-burst`: a client withdrawing its service and writing the same servers back every 25 s for 20 minutes is re-applied at once each time and never suspended; a rewrite inside the spacing waits for the wake.
  - `dns-vpn-override-disconnect`: a key removed while still connected is held with the set; the disconnect releases and nothing is written.
  - `dns-vpn-override-stop`: Stop, and "Manage system DNS" off, each release before the relay stops.
  - `dns-vpn-override-helper-release`: the helper releases on its own; the app sees it, backs off, and re-applies after the backoff.
  - `dns-vpn-override-split-tunnel`: the override is never applied.
  - `dns-vpn-override-tcp-bind-fails`: a TCP relay that cannot bind leaves UDP serving and the override refused.
  - `dns-vpn-override-tcp-relay-dies`: a TCP relay that dies makes the helper release on its next tick.
  - `dns-vpn-override-restore-retry`: a restore the helper cannot write keeps its record and lands on a later tick.
- **TCP relay tests** (`TCPRelayDNSTests`): a length-prefixed query reaches a fake target over a real `TCPRelay` on ephemeral ports and a large answer comes back whole; a connection past the session cap is closed before a target connection is spent on it.
- **TLA+**: `formal/vpn-detection/VPNDNSOverride.tla`, a separate small spec run by the same `check.py`. The main VPN spec already takes about 77 of its 120 CI minutes.
  - **State**: the key, the record, the relay and probe, the owner, the app's view, and the live set.
  - **Actions**:
    - the client's rewrite, delete and republish
    - owner exit, helper restart and relay death
    - ticks, and app apply and release
  - **Invariants**:
    - `NoClobber`: an apply overwrites only the value it read and found equal to the caller's servers, and a release only the `127.0.0.1` it wrote; any other overwrite is a client write inside the documented window.
    - `NoSelfReference`: the forwarder's servers never include loopback.
    - `NoServerlessDefault`: the key holds `127.0.0.1` only while a record exists.
    - `ReleaseBeforeUnset`: the key never holds `127.0.0.1` while the live set lacks the tunnel's servers, outside the single step that releases.
    - `EventuallyReleased`: a key at `127.0.0.1` with no serving forwarder is released, under fairness of the helper's actions.
  - **Mutants**: a release without the compare, an apply before the live set, a parser without substitution, no `NOTE_EXIT`, a record kept at helper start, and a set dropped before the release.
  - The ledger, the policy, `PushedResolver*.swift`, `RuntimeHostSplitDNSDetection.swift` and the helper's loop join the coverage record.
- **Owner checks, on the real VPN on macOS 27**:
  - connect: public and internal names resolve
  - disconnect: the key is gone and nothing is left behind
  - reconnect
  - sleep and wake
  - a Wi-Fi roam while connected
  - DNS Stop, and "Manage system DNS" off: the originals come back at once
  - Quit
  - `kill -9` of the app: the originals come back within seconds, checked with `scutil --dns` and `dig`
  - `sudo launchctl kickstart -k` of the helper during an override
  - a soak of several hours connected, to see how the client behaves on rekey

## Review

An independent review of the first draft (2026-11-19) raised these points, all taken:

- the public-name relay probe as a liveness signal, replaced by a local probe name
- no policy re-run on non-reading inputs, now covered by the health tick, relay starts and helper replies
- helper releases invisible behind reading deduplication, now carried as `overridden` plus a `status` poll, with backoff
- a record kept across a helper restart while the relay is gone, replaced by an unconditional release at start
- unbounded re-applies against the client, now capped at 3 per 10 minutes for changed servers and spaced 10 s apart for the same servers
- an unspecified internal relay restart
- `SIGTERM` handled in a signal handler, moved to `EVFILT_SIGNAL`
- the "Manage system DNS" toggle using a different clear path than teardown, now released explicitly ahead of both
- withdraw order on a blind gate, now release before the set drops
- weaker coverage of internal names outside the pushed domains, recorded above
- the delete race, three commands instead of value-aware admission, loopback as `127/8` and `::1`, and a separate TLA+ spec

The review found the following fine as designed:

- `SystemDNSManager.reconcile`, location reconcile and launch recovery: none of them touches the client's `State:` key.
- the 0044 flap hold and 0048 withholding
- the helper's probe of the forwarder's own port, which isn't affected by this machine's swallowed `:53`
- versioning within v5
- checking IPv4 primacy only
- two callers: a second caller's apply is refused `changed`
