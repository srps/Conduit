---
name: vpn-dns-override-model
description: Model-check Conduit's 0049 VPN resolver override (VPNDNSOverrideLedger in the helper, HelperDaemon's kevent loop, VPNResolverOverridePolicy and its controller, PushedResolverReading's substitution, RuntimeHostVPNDNSOverride and RuntimeHostSplitDNSDetection's ordering) with the TLA+ spec formal/vpn-detection/VPNDNSOverride.tla. Use when a change touches any file in its coverage record, or for a bug where Cisco's or another VPN's DNS key is left at 127.0.0.1, clobbered, deleted, lost after a flap, suspended, or loops back to Conduit.
---

# VPN DNS override model

Decision 0049 lets the helper point a full-tunnel VPN's `State:/Network/Service/<id>/DNS` at the relay (`127.0.0.1`) and give it back. `formal/vpn-detection/VPNDNSOverride.tla` models one such service: the client's DNS and IPv4 keys and the VPN gate, the helper's ledger record, its relay and forwarder probe and its kevent loop, the owner process, the helper's restarts, and the app's monitor reading, substitution box, policy, controller, live and held split-DNS sets and helper calls. TLC checks every interleaving of those steps under small bounds. It is a separate spec from `VPNDetection.tla` (skill `vpn-detection-model`), which models the gate's own chain and the entry files.

## Does my change touch it?

It does if it changes the behaviour of any function in the coverage record below, or adds a path that writes the tunnel's DNS key, feeds the override policy, or orders a release against a split-DNS set update.

```sh
python3 formal/vpn-detection/check.py --full-for SYNC_COMMIT
```

prints `override` when a file in `OVERRIDE_COVERED` in `check.py`, the spec or this skill changed since the sync commit; `--changed REF` lists the files. `OVERRIDE_COVERED` is the one list of covered files.

## Run it

```sh
python3 formal/vpn-detection/check.py --spec override --mutants
```

That runs the four checks, every mutant, the open bugs and the witnesses at the default bounds (times in **Bounds**). `--full=override` runs the larger bounds; `--only <check or mutant>` runs one. It needs Java 11 or later; the first run fetches `tla2tools.jar` into `formal/.tools/`. Each run writes `formal/vpn-detection/.out/<name>/tlc.out`.

CI runs it in the `vpn-model (override)` job of `.github/workflows/swift.yml`, in parallel with the detection spec's job: every run checks this spec's default tier, and its full tier when its covered or model files changed (`check.py --full-for`) or on the nightly schedule.

Read every result with the `/statechart` skill: give it the spec and the config from `.out/<name>/`, and it shows a violation as its shortest path in plain words. Before you trust a path, replay it against the Swift, one step per action, in a ledger test over the fake `VPNDNSStore` and `VPNDNSForwarderProbe`, or a pm-sim scenario over `FakeMachine`.

## What it checks

Each property's comment in the spec says what it guarantees and the harm if it breaks.

- `NoClobber`. A helper write replaces only what it compared and meant to replace, or the value it wrote itself, or a client value written between its compare-read and its write (the documented window). A write with no compare-read before it gets no window. Harm: the client's current servers are overwritten.
- `NoSelfReference`. The reading, the live set and a held set never carry `127.0.0.1` as a tunnel server. Harm: the forwarder queries itself.
- `NoServerlessDefault`. The key holds `127.0.0.1` only while the helper holds a record. Harm: nothing can give the key back.
- `ReleaseBeforeUnset`. While the key holds `127.0.0.1` and the relay and forwarder serve it, the live set has the tunnel's servers, except between the owner's exit and the helper handling it. After a client write inside apply's window, or a reading parsed with a box replaced since (both self-correcting), any list the client published counts. Harm: internal names fail.
- `NoLoopbackWithoutService`. A key at `127.0.0.1` exists without the IPv4 key, other than during an IPv4 flap, only while the helper holds a record and is inside an operation or down. Harm: a `127.0.0.1` key outlives the removed service.
- `ClientKeyKept`. A service that is up or only flapping always has its DNS key; the helper never deletes it. Harm: the client does not republish a deleted key, so the Mac has no default resolver (the owner's machine, 2026-11-19).
- `OneRefusalPerTrigger`. A refused apply is not sent again until a store reading, a tick or a wake. Harm: a refusal that asks for its own pass spins the helper with no client change.
- `EventuallyReleased` (liveness, under weak fairness of the helper's steps, ticks, NOTE_EXIT and restart; the app and the client are not assumed fair). A key at `127.0.0.1` that nothing serves is released, unless the relay and the forwarder come back. Harm: every system-resolved name fails.

- `NeverSuspended`, under `override-flaps` (three IPv4 flaps) and `override-same-endless` (same-server rewrites and refused flaps with no bound). Neither flaps nor a client writing its own servers back bring `decide` to `.suspend`. Harm: public names fail for the suspension's lifetime.
- `SuspensionEnds` (liveness, under weak fairness of `SuspensionExpires`), under `override-suspension-expires` (three lists, cap 1) and in `override-liveness`. A suspension ends. Harm: the override stays off until the VPN disconnects.
- `NeverLost`, under `override-same-rewrite` (one same-server rewrite and one IPv4 flap). The override is never gone while both sides hold its record and `decide` returns `.none` even after a status call. Harm: the tunnel's DNS stays the default resolver.

## Bugs fixed on claude/vpn-override-flap

Each was an open bug or a witness at the sync commit and is now a mutant that must stay caught:

- `ov-held-set-applied-unchecked` (`ReleaseBeforeUnset`). `runVPNDNSOverride` applied `vpnDNSOverrideHeldSet` after the pass without asking `vpnDNSOverrideReleases(before:)` again: an apply out, the gate off, the empty set held, the apply landing, the set applied with the key at `127.0.0.1`. It now asks, runs one more pass with the set held, and after a failed release leaves the set held for the next request.
- `ov-refusals-count-as-applies` (`NeverSuspended`). Every apply sent counted toward `maximumApplies`. Now only applies that landed do.

## Bugs fixed on claude/vpn-override-republish

- `ov-same-servers-capped` (`NeverSuspended`, at `OVERRIDE_ENDLESS`). Applies against the servers of the last landed apply counted toward a cap (`maximumRepublishApplies`, classified by a withdrawn service), so a client re-asserting its servers suspended the override. Now they count toward no cap; `minimumApplySpacing` alone bounds them, modelled as `spaced` and `SpacingElapses`.
- `ov-refusals-capped` (`NeverSuspended`, at `OVERRIDE_ENDLESS`). Refusals counted toward a cap (`maximumRefusedApplies`), so a client that flaps without end and is refused each time suspended the override. Refusals now count toward nothing. `refusals` exists only for this mutant.
- `ov-refusal-retries-at-once` (`OneRefusalPerTrigger`, at `OVERRIDE_MUTANT`). A refused apply leaves `fresh` set, so the app sends it again with no reading, tick or wake in between. In the Swift a refusal arms no wake and requests no pass; `tries` counts refusals since the last trigger.
- `ov-suspension-never-expires` (`SuspensionEnds`, at `OVERRIDE_SUSPENSION`). A suspension lasted until the gate turned off or DNS restarted. It now ends after `suspensionLifetime`.
- `ov-same-rewrite-kept` (`NeverLost`). The client writing the same servers back over `127.0.0.1` left `decide` matching the record. `confirm` now sets `keyRewritten` when the helper still holds the record and the key reads with the client's servers, once a reading of the helper's write was seen or `readingSettle` passed since the apply.
- `ov-hold-reads-live-set` (`ReleaseBeforeUnset`). The hold rule is safe only on the `serversInUse` `decide` is handed; on the orchestrator's live set it breaks.

`BoxBothSides` (the monitor's box taken on both sides of the store read) has no mutant: no property here fails with the box taken before the read only, because the hold makes the spurious no-full-tunnel reading harmless. The Swift test `testAReadThatSpansTheBoxChangingReadsThroughEitherSide` covers it.

## Bounds

Every check starts from `OVERRIDE_NONE` (one list, no fault, cap 3) and adds one class of trouble, because all of them at once ran past 7 GB of TLC state in five minutes:

- `override-safety-client` (`OVERRIDE_CLIENT`): three lists, a disconnect, a gate flap, an IPv4 flap, a DNS Stop.
- `override-safety-process` (`OVERRIDE_PROCESS`): two lists, a disconnect, an IPv4 flap, an app exit, a helper crash or SIGTERM, a DNS Stop.
- `override-safety-relay` (`OVERRIDE_RELAY`): two lists, a disconnect, a gate flap, a relay death, a forwarder fault, a DNS Stop.
- `override-liveness` (`OVERRIDE_LIVE`): see `check.py` for its bounds.
- `override-flaps` (`OVERRIDE_FLAPS`): three IPv4 flaps; adds `NeverSuspended`.
- `override-same-rewrite` (`OVERRIDE_SAME_REWRITE`): one same-server rewrite and one IPv4 flap; adds `NeverLost`.
- `override-same-endless` (`OVERRIDE_ENDLESS`): same-server rewrites and IPv4 flaps that spend no budget (`Endless`), each flap able to cost a refusal; adds `NeverSuspended` and `NeverLost`.
- `override-suspension-expires` (`OVERRIDE_SUSPENSION`): three lists at cap 1; checks `SuspensionEnds`.

`--full` adds a list to each safety check and an IPv4 flap to liveness. Safety mutants run at `OVERRIDE_MUTANT`, the tick mutants with only a forwarder fault (`OVERRIDE_FORWARDER_ONLY`).

Measured on a 12-core laptop: client 11.3M distinct states in 40 s, process 14.5M in 54 s, relay 15.5M in 52 s, liveness 2.6M in 75 s; every mutant, bug and witness 1 to 2 s. The full liveness bounds took 13.8M states and 521 s.

## Coverage record

Synced at SYNC_COMMIT. Move it forward only after you confirm, function by function, that the model still describes the code.

| Model | Code |
| --- | --- |
| `key`, `svc`, `ver`, `ClientRewrite`, `ClientRewriteSame`, `ClientDelete`, `ClientPublishDNS`, `ClientPublishIPv4`, `ClientRepublish`, `ClientIPv4Flap`, `ClientIPv4Back` | the VPN client writing `State:/Network/Service/<id>/DNS` and `/IPv4` (another process) |
| `vgate`, `GateFlap`, `GateBack` | `SplitDNSVPNGate.entriesWanted` (its chain is `VPNDetection.tla`) |
| `rec` | `Sources/ConduitShared/VPNDNSOverrideLedger.swift` `record` and `persistence` |
| `HAccept` (apply) | `VPNDNSOverrideLedger.apply`: `check()` (one `dns(service:)` read, `ipv4Exists`, `primaryService`, `servers == expected`, `probe.tcpListening()`, `probe.probe()`), the release of another service's record, `persistence.save`, and the second `dns(service:)` read that must equal the first (the model's one read is this one) |
| `HApplyWrite` | `apply`: `store.setDNS(overridden)` |
| `HApplyIPv4`, `ApplyChecksService`, `WatchOwner` | `apply`: `guard store.ipv4Exists(service:)`, `record = replacement`, `resetProbeStreaks`; `Sources/ConduitHelper/HelperDaemon.swift` `applyVPNDNSOverride` (`overrideOwner = peerPID`) and `run`'s `loop.watchOwner(...)`, `ESRCH` releasing `.ownerExited` |
| `HApplyGoneRead`, `HApplyGoneWrite`, `ApplyGoneCompares` | `apply`'s no-IPv4 path: `store.dns(service:) == overridden`, `setDNS` of the originals, `forgetRecord`, refused `not_found` |
| `HRelRead`, `HRelWrite`, `ReleaseCompares`, `FinishRelease` | `VPNDNSOverrideLedger.release` -> `restore`: `dns(service:)`, `guard ... == .strings(Self.relayServers)`, `setDNS` of the originals; `forgetRecord`, `lastRelease` |
| `HRelIPv4`, `HRelRemove`, `RemovesGoneKey` | the ledger before 276eebd5 (`ipv4Exists`, `removeDNS`), run only by `ov-removes-key-without-ipv4` |
| `HTick` | `VPNDNSOverrideLedger.tick`: `probe.tcpListening()` false or `.notRunning` -> `relayStopped`, two `.refused`, three `.silent`; `HelperEventLoop.next(tickDue:)` |
| `HOwnerExit`, `ExitPending`, `HelperFree`, `ExitsFirst` | `Sources/ConduitHelper/HelperEventLoop.swift` `ordered` (signals, owner exits, one connection) and `next`; `HelperDaemon.run` `.ownerExited` -> `release(.ownerExited)` |
| `HSignal` | `HelperDaemon.run` `.signal` -> `release(.helperStopping)`, exit |
| `HAccept` (other requests) | `HelperDaemon.processRequest`: `releaseVPNDNSOverride` (`.requested`), `startDNSRelay` (both halves, idempotent; a restart keeps the record only if TCP binds too, and a TCP bind failure is `HAccept` then `RelayDies`; `relayRestarted(succeeded:)`), `.stopDNSRelay` (`release(.relayStopped)` then both stop) |
| `HelperCrash`, `HStart`, `ReleaseAtStart` | the helper killed (relay, watch, `overrideOwner` lost); launchd starting it: `VPNDNSOverrideLedger.start` -> `release(.helperStart)` |
| `Parse`, `ParseLoopback`, `Overridden` | `Sources/PlatformMac/PushedResolver.swift` `PushedResolverReading.parseResolver`: `overridden`, the substitution, `selfReferential` |
| `AppReadBox`, `AppReadStore`, `snapBox`, `snapKey`, `BoxBothSides` | `Sources/PlatformMac/PushedResolverMonitor.swift` `read(_:_:)` (the box taken before and after `copyMultiple`, the later winning), `deliver`, `storeChanged`; `LiveSplitDNSDetection.lastReading` |
| `box` | `VPNResolverOverrideController.substitutions`, read by the monitor through `RuntimeHost.swift`'s `setSubstitutions` provider |
| `DecisionOf`, `WantedOf`, `UseSetOf`, `ServersInUse`, `HoldRule`, `KeepsThroughFlap` | `Sources/PlatformMac/VPNResolverOverridePolicy.swift` `decide`, `wanted`; `Sources/ConduitRuntime/RuntimeHostVPNDNSOverride.swift` `vpnDNSOverrideInputs`; `HoldRule`, `HoldOnSetInUse`: `VPNResolverOverridePolicy.holds`; `CapReached`, `SameServers`, `SameServersUncapped`: the cap and `lastApplies`' servers |
| `MayHoldOf`, `known`, `unApply`, `unRel`, `applies`, `refusals`, `lastN`, `spaced`, `susp`, `rewritten`, `fresh`, `tries`, `RefusalsSeparate`, `RefusalsCapped`, `RefusalRetriesAtOnce`, `SuspensionsExpire` | `Sources/PlatformMac/VPNResolverOverrideController.swift` `mayHoldRecord`, `record`, `unconfirmedApply`, `unconfirmedRelease`, `applies` (`note(_:in:)`), `lastApplies` (`noteLanded`), `wakeAt`, `suspended`, `keyRewritten`, `observe` |
| `SpacingElapses`, `SuspensionExpires` | controller `armWake(at:)` and `onWake` (`RuntimeHost.requestVPNDNSOverrideRun`); `observe`'s expiry of `suspended` past `suspensionLifetime` |
| `AppPoll`, `Polled`, `SameRewriteReapplies` | controller `pass`'s `status(_:)` and `confirm(_:lastRelease:restorePending:reading:)` (`keyRewritten` once `writeSeen` or `readingSettle`; an adopted `unconfirmedApply` counted through `landed`) |
| `AppPass`, `ApplyOK`, `ApplyRefused`, `ApplyFailed`, `ReleaseOK`, `ReleaseFailed`, `AfterCall` | controller `pass`, `apply`, `release`; `RuntimeHostVPNDNSOverride.runVPNDNSOverride` (the held set after the pass, `HeldSetRechecked`) |
| `AppTake`, `NewSet`, `HoldBeforeRelease`, `FlapHold` | `Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift` `applyPendingSplitDNSDetection`, `vpnDNSOverrideReleases(before:)`; `LiveSplitDNSDetection.take`; `Sources/PlatformMac/LiveSplitDNSPolicy.swift` `heldThroughFlap` (added to the model on claude/vpn-override-flap: without it every flap dropped the set) |
| `AppRestartRelay`, `AppStartDNS` | `RuntimeHost.handleDNSHealthResult` (a relay restart); `startDNSModule` and `SystemDNSManager.startRelay` |
| `AppStop`, `AppTdRelease`, `AppTdClear` | `RuntimeHostLifecycle`'s DNS teardown: `stopDNSHealthTimer`, `await vpnDNSOverride.release(.stop)`, `dnsStopped()`, `SystemDNSManager.clear` -> `stopRelay` |
| `AppCallFails` | a privileged call while the helper is down |
| `relay`, `RelayDies` | both of the helper's relays on `127.0.0.1:53`, `UDPRelay` and the DNS `TCPRelay`; `check()` requires `probe.tcpListening()` and an answered probe; `RelayDies` is either one dying |
| `OwnerExit`, `AppLaunch`, `ForwarderFault`, `ForwarderRecovers` | the environment |

The atomicity of each step, and the code it relies on, is in the spec's header.

## Semantic choices

1. A healthy monitor reads only on a store notification: a read follows a change of the keys since the last one began; two changes between reads are one notification.
2. A refused apply is sent again after a new reading or at the health tick's status call (`fresh`, `Polled`): the key change that refused it usually notifies at once, but a flap can end before the monitor reads it, and only the tick then retries. The model's tick re-arms only with the service present: ticks are 30 s apart and a flap lasts well under one, so the model leaves out at most one refusal per flap.
3. Two different server lists share no server, so a live set and a held set either agree or have nothing in common.
4. The caps have no 10-minute window: every apply counts toward its cap until the gate turns off or DNS stops. The backoff, which only delays, is left out.
5. `relayServing` reads the relay and the forwarder as they are, not through the 30 s health timer.
6. A helper reply is applied by the app instance that sent it, and dropped if it exited.
7. The pid watch, the reply and the held set's application join the step that ends their event or turn; no key is touched between them.
8. `readingSettle` is abstracted as the reading being the key as it is: the status call that finds a same-server rewrite comes after the reading has caught up.
9. A store write never fails. A failed restore keeps the record (`restorePending`) and the next tick retries it before any probe; the Swift tests and `dns-vpn-override-restore-retry` cover that, not the model.

## What it leaves out

Two VPN services and split tunnels; the primary-service lag behind `not_primary`; fields other than `ServerAddresses`; the relay's target port and a restart onto a new one; reboots; an undecodable record file; the backoff; the forwarder's own routing.

## A real bug or a modeling error?

When a check fails, read the path with `/statechart`, then:

1. Map each step to the code through the coverage record. If a step does something the code cannot do (two helper operations interleaved, a monitor read with no store change, a reading parsed with a box the monitor could not have taken), the model is wrong: fix the action and say why in the commit.
2. If every step is possible, replay it in a ledger test or a pm-sim scenario. A replay that shows the harm is a bug: report it with the path in the code's words, and record it as a `bug-` entry with its fix in `OVERRIDE.fixes`. Do not weaken the property or the model to make it pass, and do not fix product code as part of a model change.
3. A path that is possible but harmless means the property is too strong for what the owner decided; ask the owner before changing it.

## When the code changes on purpose

Change the action that stands for the code, keep the property, and run `check.py --spec override --mutants`. Every mutant must still be caught, every open bug still fail, every witness still be reached; a mutant whose text no longer matches the spec makes `check.py` stop with the text it looked for. Each mutant's `swift` text in `check.py` names the scratch change it mirrors, by function. Add a mutant for each bug you fix: the Swift change that reintroduces it, the same change in the spec, and the property that catches it. Then update the coverage record and move the sync commit.
