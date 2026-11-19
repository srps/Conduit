# 0049: Take the default resolver back from a full-tunnel VPN through the helper

- Date: 2026-11-19
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Observed on the owner's machine on 2026-11-19, macOS 27.2.1, Cisco Secure Client 5.1.12 (unchanged since 2025-11-20), full-tunnel profile:

- With the VPN connected, `scutil --dns` lists the tunnel's servers as resolver #1, and `State:/Network/Global/DNS` reads `Default: com.cisco.anyconnect`. Conduit's `127.0.0.1`, written on every physical service, survives only as a resolver scoped to `en0` and marked Not Reachable.
- The tunnel's servers answer NXDOMAIN for public names (`github.com`, `example.com`). Applications that resolve through the system get `ENOTFOUND`. Applications that only go through the PAC and the proxy are unaffected.
- On 2026-11-09, on macOS 26 with the same client and profile, the capture in [`design-live-vpn-split-dns.md`](../design-live-vpn-split-dns.md) records the opposite order: Conduit's `127.0.0.1` stayed resolver #1 and the tunnel's resolver was scoped to its `utun`. The difference is the macOS upgrade, not Conduit or the VPN client.
- Conduit's relay and forwarder still answered correctly when asked directly. Nothing in the pipeline failed; the system stopped asking it.

The owner ran three reversible experiments with the VPN connected (scripts and outputs recorded in the [design](../design-vpn-default-resolver-override.md#evidence)):

- **A.** Adding `SearchOrder 0` to Conduit's DNS on the primary physical service changed nothing.
- **B.** Rewriting `ServerAddresses` in `State:/Network/Service/com.cisco.anyconnect/DNS` to `127.0.0.1` made `127.0.0.1` the default resolver, and public names resolved. The client did not rewrite the key within 30 s. Internal names then failed, because the forwarder had no route to the tunnel's servers (0.6.2 has no live split DNS, and the owner's manual entries are disabled).
- **C.** Publishing a Conduit-owned service with only DNS, and then with a copy of the tunnel's IPv4 dictionary and `OverridePrimary 1`, changed nothing: the client's service stayed primary for both the route and the resolver.

On the same machine later that day the override held for 52 minutes. Then, for five minutes, the client withdrew its service and wrote its DNS key again with the same servers every 24 to 30 s. The app re-applied each time, but counted those re-applies toward a cap of 6 in 10 minutes (`cap=republished`), suspended at the seventh, and left public names on the tunnel's servers until the VPN disconnected about an hour later. The owner decided on 2026-11-19 that a client re-asserting its own servers is not a fight and must never suspend the override (item 8).

The owner's requirements (2026-11-19): fix it in 0.7.0, and nothing may leave DNS in a worse state than it is without the fix. The owner chose that the helper, not the next launch, restores the tunnel's servers when Conduit goes away, and asked for an independent design review. The review's findings, all taken, are listed in the design.

## Decision

While a full-tunnel VPN holds the default resolver and Conduit's DNS relay serves, the helper points that VPN's published DNS at the relay and restores it as soon as Conduit can no longer serve. The [design](../design-vpn-default-resolver-override.md) holds the details; these are the boundaries.

1. **Scope.** Only a service whose `State:/Network/Service/<id>/IPv4` has `OverridePrimary` 1, whose DNS key has `ServerAddresses` and no `SupplementalMatchDomains`, and which is the primary service in `State:/Network/Global/IPv4`. A split tunnel does not take the default resolver and is never touched. Only `ServerAddresses` changes; every other field of the key is written back as read. The helper never deletes the client's key. On the owner's machine (2026-11-19, the first build) a release during a 196 ms flap found the service's IPv4 key briefly absent, took the service for removed, and deleted the DNS key; the client never republished it, and the Mac had no default resolver until the VPN reconnected. A write that recreates a key for a service the client really removed holds the originals, which is inert without an IPv4 key and what the client publishes on reconnect.
2. **Preconditions.** The override is applied only while "Manage system DNS" is on, the relay is listening on `127.0.0.1:53` over both UDP and TCP with an answering target, and the live split-DNS set (0044) is in use for that tunnel, so internal names have the tunnel's servers. There is no separate preference: "Manage system DNS" already means Conduit is the Mac's resolver, and turning it off releases the override.
3. **The helper owns the override.** Three new commands, `vpn-dns-override-apply`, `-release` and `-status`, behind a new helper feature within protocol v5. Apply is a compare-then-write: the helper writes only if the key's current `ServerAddresses` equal the servers the caller read, and only while the forwarder answers a reserved probe name that it serves locally. It reads the key again after that probe and the record's save, and refuses `changed` if the key moved. SCDynamicStore has no atomic swap, so a client write in the microseconds between the read and the write is overwritten. The helper keeps the service and its original servers in memory and in a root-only file under `/var/run`, which, like the key, does not survive a reboot. It watches the pid of the caller that applied.
4. **Release is a compare-then-write too.** The helper writes the originals back only if the key still holds exactly `127.0.0.1`. If the client has written anything else since, or the key is gone, the helper drops its record and writes nothing: the client's value is authoritative. If the restoring write itself fails, the helper keeps the record and its file, retries the release on each tick before any probe, and refuses an apply for another service until the restore lands.
5. **The helper releases without being asked** when:
   - the owning process exits, watched with `EVFILT_PROC NOTE_EXIT` on the pid from the caller's audit token
   - the relay stops, its UDP or its TCP half, or a relay restart fails
   - the forwarder's probe is refused on two consecutive 10 s ticks, or is silent on three
   - the helper receives `SIGTERM`
   - the helper starts and finds a record: always, because a fresh helper has no relay
6. **Conduit releases** on DNS Stop, on Quit, when "Manage system DNS" is turned off, when the gate turns off for the tunnel (disconnect, end of a flap's grace), when the tunnel's servers leave the live set in use, and when a reading shows a different full tunnel or the service as a split tunnel. A reading with no full tunnel at all does not release while the live set still holds every one of the record's servers: it holds through it, as 0044 holds the set (item 8). Turning "Manage system DNS" off is the user's way out; no separate restore action is added.
7. **Reading the tunnel's servers.** The live split-DNS reader takes the tunnel's servers from the app's own record of the override, set before the apply is sent and cleared after the release, whenever the key holds `127.0.0.1`. The app reconciles that record with the helper's `status` on each relay start, on the DNS health tick while one is expected, and when a reading shows the key move. A key holding `127.0.0.1` that the app holds no record for is rejected (`reason=self_referential`), never followed.
8. **Hold through a flap, re-apply, bounded.**
   - **Hold.** On the owner's machine (2026-11-19, 11:33 and 11:58) Cisco withdrew its service's IPv4 key inside a flap while its DNS key still held `127.0.0.1`. With no `OverridePrimary` and no `SupplementalMatchDomains` the parser ignored the key (`no_match_domains`), 0044 held the set, and the first build released, leaving public names on the tunnel's servers until the next apply. While the gate wants entries, a reading with no full tunnel and nothing for the record's service keeps the override as long as every one of the record's servers is still in the live set in use. Release before unset still holds: the set is decided against before it is applied.
   - **Same-server rewrite.** The client can write its DNS key again with its own servers, inside a flap or on its own. When a reading after the helper's write shows the key with the client's servers, and the helper's status still holds the record, the client rewrote the key, even with the same servers, and Conduit applies again.
   - **Same servers re-apply without a cap.** An apply whose servers equal those of the last apply that landed for the service is the client re-asserting its value, not a fight over it. It is sent at once and counts toward no cap. The only bound is a spacing of 10 s after the last apply that landed for the service (`minimumApplySpacing`): an apply inside it waits until the spacing has passed, through the controller's injected clock, and the policy decides again then. A client that rewrites its key the instant the helper writes gets at most 6 helper writes a minute.
   - **One cap**, per service, in a 10-minute window: 3 applies that landed against servers other than the last landed apply's end in `dns.vpn_override_suspended cap=applied`, the client answering the override with new servers.
   - **Refusals never suspend.** An apply that is refused (`not_primary`, `not_found`, `changed` and the rest), fails or goes unanswered counts toward no cap and is not spaced, since it wrote nothing: the republish that follows a flap's `not_primary` is applied at once. A refusal arms no wake and asks for no pass, so the next attempt waits for the next trigger (a store reading, the 30 s DNS health tick, a relay start or a wake armed for something else): at most one attempt per trigger. The owner approved dropping the earlier cap of 6 refusals in 10 minutes on 2026-11-19: a client that flaps every 25 s and is refused each time would have reached it in under three minutes.
   - **Suspensions expire** after 10 minutes (`suspensionLifetime`), as well as when the gate turns off or DNS restarts. An expiry emits `dns.vpn_override_suspension_expired`, and the policy decides afresh.
   - A release the helper made by itself backs off re-applying, from 60 s up to 10 minutes. The policy re-runs on each reading, on the 30 s DNS health tick, after each relay start and after each helper reply, so inputs that produce no store reading still take effect.
9. **Decision 0002's narrow helper.** The helper now holds one piece of state on the app's behalf: the original servers of at most one VPN service, and the owner pid. This is the bounded exception the owner accepted for crash safety; #274 remains the general design for system DNS.

## Alternatives

- **A, priority on Conduit's own service.** Tested; macOS 27 ignores it for the default resolver.
- **C, a Conduit-owned primary service.** Tested; the client's service keeps the primary role. Winning it would also move the default route, so even a working variant would risk all traffic, not only DNS.
- **Next launch restores** instead of the helper. Rejected by the owner: DNS on the VPN would stay broken from a crash until the next launch.
- **Leave it, document it.** Rejected: system-resolved public names fail on every full-tunnel VPN on macOS 27.
- **Rewrite `State:/Network/Global/DNS`.** configd computes it from the services and overwrites it.

## Consequences

- Public names resolve again on a full-tunnel VPN; internal names go to the tunnel's servers through the live split-DNS set.
- Conduit writes into another vendor's live state. Every failure other than a crash returns to today's behaviour, and the crash case is the helper's.
- 0.7.0 needs a helper update and reinstall. A 0.7.0 app with an older helper detects the missing feature (`HelperFeature.vpnDNSOverride`) and leaves the key alone, as today.
- The helper's accept loop moves from a blocking `accept` to a `kevent` loop, so it can watch an owner process without a thread.
- The helper relays DNS over TCP on `127.0.0.1:53` as well as UDP, to the forwarder's TCP listener on the same port. With every lookup on the Mac going to the relay, a resolver's TCP retry of an answer too large for UDP (on the owner's machine, an internal name with about 67 A records) otherwise failed with "network down" and returned nothing. A TCP relay that cannot bind leaves UDP serving and the override refused.

## Invariants and verification

- **Never leaves `127.0.0.1` behind without a server.** At every point after a release trigger, the key holds the originals, the client's own newer value, or nothing. The one exception is the app and the helper both gone with no helper restart, which is today's state for system DNS after the same failure (#274).
- **Release before unset.** The key never holds `127.0.0.1` while the forwarder lacks the tunnel's servers.
- **Never clobbers the client.** An apply overwrites only the value it read and found equal to the caller's servers, and a release only the `127.0.0.1` it wrote, outside the read-to-write window the design records on each side.
- **Never loops.** The forwarder never sends a query to `127.0.0.1` as a tunnel server.
- **Only one service, only `ServerAddresses`.**

The failure that would disprove the design: the key left at `127.0.0.1` while nothing answers on `:53`, after any of the triggers in 5 and 6, for longer than the design's bound for that trigger (at most 30 s plus one helper request in flight).

The evidence is ledger unit tests over a fake store and probe, policy and parser tests, pm-sim scenarios over `FakeMachine` running the real ledger, and a separate TLA+ spec with mutants; the owner's real-VPN checks listed in the design are still to come.

## Implementation evidence

Implemented in #330:

- The helper's ledger, its record file and its checks: [`VPNDNSOverrideLedger.swift`](../../Sources/ConduitShared/VPNDNSOverrideLedger.swift), [`VPNDNSOverrideValidation.swift`](../../Sources/ConduitShared/VPNDNSOverrideValidation.swift); the commands, the `kevent` loop and the TCP relay: [`HelperDaemon.swift`](../../Sources/ConduitHelper/HelperDaemon.swift), [`HelperEventLoop.swift`](../../Sources/ConduitHelper/HelperEventLoop.swift), [`TCPRelay.swift`](../../Sources/ProxyKernel/Network/TCPRelay.swift).
- The app side: [`VPNResolverOverridePolicy.swift`](../../Sources/PlatformMac/VPNResolverOverridePolicy.swift), [`VPNResolverOverrideController.swift`](../../Sources/PlatformMac/VPNResolverOverrideController.swift), the reading's substitution in [`PushedResolver.swift`](../../Sources/PlatformMac/PushedResolver.swift), and the host's ordering in [`RuntimeHostVPNDNSOverride.swift`](../../Sources/ConduitRuntime/RuntimeHostVPNDNSOverride.swift) and [`RuntimeHostSplitDNSDetection.swift`](../../Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift).
- Tests: [`VPNDNSOverrideLedgerTests.swift`](../../Tests/ConduitTests/VPNDNSOverrideLedgerTests.swift) (every refusal, the compare-then-write and the re-read after the probe, a failed restore kept and retried, the release triggers, persistence), [`VPNResolverOverrideTests.swift`](../../Tests/ConduitTests/VPNResolverOverrideTests.swift) (the policy and the controller, an apply confirmed by status counted once), [`HelperVPNDNSOverrideTests.swift`](../../Tests/ConduitTests/HelperVPNDNSOverrideTests.swift), [`PushedResolverSubstitutionTests.swift`](../../Tests/ConduitTests/PushedResolverSubstitutionTests.swift), [`RuntimeHostVPNDNSOverrideTests.swift`](../../Tests/ConduitTests/RuntimeHostVPNDNSOverrideTests.swift), [`TCPRelayDNSTests.swift`](../../Tests/ConduitTests/TCPRelayDNSTests.swift).
- pm-sim: the `dns-vpn-override-*` scenarios in [`VPNDNSOverrideScenarios.swift`](../../Sources/pm-sim/VPNDNSOverrideScenarios.swift), over `FakeMachine` running the real ledger.
- The model: [`VPNDNSOverride.tla`](../../formal/vpn-detection/VPNDNSOverride.tla), run by [`check.py`](../../formal/vpn-detection/check.py) with its mutants. It has no failing store write, so the kept record and its retry are covered by the tests and `dns-vpn-override-restore-retry` only.

Does not prove: behaviour with a real Cisco client on macOS 27, a client write inside the compare-then-write window, or the owner's real-VPN checks listed in the design, which are still to come.

## Open questions

None.
