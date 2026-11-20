---
name: vpn-dns-override-model
description: Model-check Conduit's 0049 VPN resolver override (the helper's own temporary DNS key and VPNDNSOverridePublisher, the fail-safe DNSFailoverRelay, HelperDaemon's kevent loop, VPNResolverOverridePolicy and its controller, PushedResolverReading, RuntimeHostVPNDNSOverride and RuntimeHostSplitDNSDetection's ordering) with the TLA+ spec formal/vpn-detection/VPNDNSOverride.tla. Use when a change touches any file in its coverage record, or for a bug where lookups hang or fail with Conduit's key first, the key outlives Conduit or the VPN, does not come back after a flap or a configd restart, the VPN's own DNS key is written, or a lookup loops back to Conduit.
---

# VPN DNS override model

Decision 0049, as revised in #330, makes the helper's relay resolver #1 on a full-tunnel VPN through one temporary dynamic-store key of the helper's own, and never writes the VPN client's keys. The relay forwards to Conduit's forwarder and fails each lookup over to the VPN's servers, read live from the VPN's untouched key. `formal/vpn-detection/VPNDNSOverride.tla` models one VPN service: its DNS key and IPv4 key and the VPN gate; configd's restarts; Conduit's key; the helper (up or down, its arm, its probe streaks, its view of the store) and its owner watch; the relay's mode; Conduit's forwarder; and the app's reading, live split-DNS set, arm and helper calls. TLC checks every interleaving of those steps under small bounds. It is a separate spec from `VPNDetection.tla` (skill `vpn-detection-model`), which models the gate's own chain and the entry files.

## Does my change touch it?

It does if it changes the behaviour of any function in the coverage record below, or adds a path that publishes or removes Conduit's key, writes any VPN key, changes where the relay forwards, feeds the override policy, or orders a disarm against a split-DNS set update.

```sh
python3 formal/vpn-detection/check.py --full-for 11ed34ad
```

prints `override` when a file in `OVERRIDE_COVERED` in `check.py`, the spec or this skill changed since the sync commit; `--changed REF` lists the files. `OVERRIDE_COVERED` is the one list of covered files.

## Run it

```sh
python3 formal/vpn-detection/check.py --spec override --mutants
```

That runs the four checks and every mutant at the default bounds (times in **Bounds**). `--full=override` runs the larger bounds; `--only <check or mutant>` runs one. It needs Java 11 or later; the first run fetches `tla2tools.jar` into `formal/.tools/`. Each run writes `formal/vpn-detection/.out/<name>/tlc.out`.

CI runs it in the `vpn-model (override)` job of `.github/workflows/swift.yml`, in parallel with the detection spec's job: pull requests and pushes check this spec's default tier. The full tier runs nightly on main when the spec's covered or model files changed since the last green nightly run, when the workflow is started by hand, and in `release.yml` on a tag, where it gates the draft release. CI does not run it for a pull request, so run `--full=override` yourself when `check.py --full-for origin/main` names this spec.

Read every result with the `/statechart` skill: give it the spec and the config from `.out/<name>/`, and it shows a violation as its shortest path in plain words. Replay a path against the Swift, one step per action, in a publisher test over the fake session store and probe, a relay test, or a pm-sim scenario over `FakeMachine`.

## What it checks

Each property's comment in the spec says what it guarantees.

- `KeyAnswered`. Whenever Conduit's key is in the store, the helper and its relay run and the VPN publishes usable servers, every lookup is answered by Conduit or by the VPN's servers. Harm: every system-resolved name hangs (experiment 2 in the decision).
- `VPNKeyUntouched`. Nothing Conduit does writes the VPN's DNS key. Harm: Conduit fights the client over its own state, as the rewrite did.
- `NoLoopbackTarget`. The relay never fails a lookup over to a loopback server taken from the VPN's key. Harm: the lookup loops or reaches a server that is not the VPN's.
- `KeyWithdrawn`. Once the helper has handled every pending event (the owner's exit, the VPN's store notifications), Conduit's key exists only while its owner is alive and the VPN publishes usable servers. Harm: resolver #1 outlives Conduit or the VPN.
- `InternalNamesServed`. While the relay sends the key's lookups to a serving Conduit, and the helper has handled the VPN's last change, Conduit's live set is the VPN's current servers. Harm: internal names fail.
- `NoSelfReference`. The reading, the live set and a held set never hold `127.0.0.1`. Harm: the forwarder queries itself.
- `EventuallyWithdrawn` (liveness, under weak fairness of the helper's steps; the app and the client are not assumed fair). A key that a live, serving Conduit does not stand behind is withdrawn, unless Conduit serves again. Harm: the key lasts on failover alone.
- `KeyReturns` (liveness). While Conduit could serve (owner alive, armed servers matching the VPN's key, relay up, probe passing), a key that is gone, after a flap or a configd restart, is published again. Harm: the override silently stops.

## Mutants

Each must be caught. The `swift` text in `check.py` names the change in the code that it mirrors.

- `ov-no-per-query-failover` (`KeyAnswered`). The relay fails over only when a tick switches its mode.
- `ov-key-points-at-conduit` (`KeyAnswered`). The key names Conduit's forwarder instead of the relay.
- `ov-failover-to-loopback` (`NoLoopbackTarget`). The relay keeps a loopback server from the VPN's key.
- `ov-key-kept-after-owner-exit` (`KeyWithdrawn`). `NOTE_EXIT` stops the watch but leaves the key.
- `ov-no-note-exit` (`KeyWithdrawn`). No owner watch.
- `ov-no-republish-after-configd-restart` (`KeyReturns`). The helper does not watch its own key.
- `ov-writes-vpn-key` (`VPNKeyUntouched`). Publishing also writes `127.0.0.1` into the VPN's key.
- `ov-reads-own-key` (`NoSelfReference`). The parser reads Conduit's key as a pushed resolver.
- `ov-arm-before-live-set` (`InternalNamesServed`). The policy arms before the live set has the VPN's servers.
- `ov-set-dropped-before-disarm` (`InternalNamesServed`). A new set is applied while the key may be armed.
- `ov-unconfirmed-arm-kept` (`InternalNamesServed`). An arm whose reply was lost is not treated as armed.
- `ov-tick-ignores-refused`, `ov-tick-ignores-silent` (`EventuallyWithdrawn`). The probe streaks never withdraw.

Retired with the rewrite, because the combined design has no write to the client's key, no restore and no record file: `ov-release-no-compare`, `ov-apply-gone-no-compare`, `ov-removes-key-without-ipv4`, `ov-apply-no-service-check`, `ov-failed-restore-forgotten`, `ov-record-kept-at-start` (no record survives the helper); `ov-parser-no-substitution` (no substitution); `ov-same-servers-capped`, `ov-refusals-capped`, `ov-refusal-retries-at-once`, `ov-suspension-never-expires`, `ov-refusals-count-as-applies`, `ov-same-rewrite-kept`, `ov-confirmed-apply-uncounted`, `ov-hold-reads-live-set` (the caps, spacing, suspensions, rewrite detection and override hold are retired); `ov-held-set-applied-unchecked` and `ov-apply-before-status` (the app's pass is one step here, and a disarm is idempotent); `ov-exits-after-connection` (a relaunched app's arm replaces the owner, so the order no longer matters). Retired with them: the properties `NoClobber`, `NoServerlessDefault`, `ReleaseBeforeUnset`, `NoLoopbackWithoutService`, `ClientKeyKept` (now `VPNKeyUntouched`, which is stronger), `LandedNoted`, `OneRefusalPerTrigger`, `NeverSuspended`, `NeverLost` and `SuspensionEnds`, and the checks `override-flaps`, `override-same-rewrite`, `override-same-endless`, `override-suspension-expires`, `override-store-faults` and `override-store-faults-liveness`. A relay-stop mutant (`stop-dns-relay` leaving the key) is not kept: the app always disarms before it stops the relay, so no path reaches the helper's own withdrawal on stop.

## Residual risk

`KeyAnswered` assumes the helper is up, not hung, and its relay thread alive. A hung helper with its key published hangs every lookup until it is killed; the model has no hung helper. A dead relay thread (`relay = "dead"`) is exempt until the helper restarts it; a restart that cannot bind is left out. The resolver order itself is assumed: Conduit's key is resolver #1 while it exists (experiment 1 and configd's source), and a macOS change to it is reported by Conduit's check, not modelled. Lookups scoped to the tunnel's interface are outside the model.

## Bounds

Every check starts from `OVERRIDE_NONE` (one server list, no fault) and adds one class of trouble:

- `override-safety-client` (`OVERRIDE_CLIENT`): three lists, a disconnect, a gate flap, an IPv4 flap, a loopback list, a configd restart, a DNS Stop.
- `override-safety-process` (`OVERRIDE_PROCESS`): two lists, a disconnect, an IPv4 flap, an app exit, a helper crash or SIGTERM, a DNS Stop, a lost arm reply.
- `override-safety-relay` (`OVERRIDE_RELAY`): two lists, a disconnect, a gate flap, a loopback list, a relay death, a forwarder fault, a DNS Stop.
- `override-liveness` (`OVERRIDE_LIVE`): two lists, a disconnect, an IPv4 flap, a configd restart, an app exit, a relay death, a forwarder fault; checks both liveness properties.

`--full` adds a list to each safety check and an app exit or a configd restart; the liveness check adds a gate flap and a lost reply. Safety mutants run at `OVERRIDE_MUTANT`; the others at the bound named in `check.py`.

Measured on a 12-core laptop: the default tier (`--spec override --mutants`) took 81 s wall: client 1.4M distinct states in 8 s, process 0.4M in 3 s, relay 3.1M in 17 s, liveness 1.0M in 40 s, every mutant 1 s. The full tier (`--full=override --mutants`) took 16 min wall: client 7.9M in 30 s, process 3.2M in 13 s, relay 25.2M in 146 s, liveness 9.8M in 768 s, every mutant 1 s.

## Coverage record

Synced at 11ed34ad, the combined design's implementation. Move it forward only after you confirm, function by function, that the model still describes the code at the new commit.

| Model | Code |
| --- | --- |
| `vkey`, `svc`, `ver`, `ClientRewrite`, `ClientLoopback`, `ClientDelete`, `ClientPublishDNS`, `ClientPublishIPv4`, `ClientIPv4Flap`, `ClientIPv4Back` | the VPN client writing `State:/Network/Service/<id>/DNS` and `/IPv4` (another process) |
| `vgate`, `GateFlap`, `GateBack` | `SplitDNSVPNGate.entriesWanted` (its chain is `VPNDetection.tla`) |
| `okey`, `ConfigdRestart` | Conduit's temporary key in the helper's session store; configd dropping temporary keys on restart |
| `h.armN`, `h.owner`, `h.pub`, `h.seen`, `Ready`, `HSync`, `NoticesOwnKey`, `WritesVPNKey` | `Sources/ConduitShared/VPNDNSOverridePublisher.swift`: `hold` (Ready), `sync` (publish, withdraw, republish when `ownKeyExists` is false), `withdraw` (a refused removal closes the session); the store in `Sources/ConduitHelper/VPNDNSOverrideAdapters.swift`, whose notifications reach `HelperEventLoop`'s `storeChanged` |
| `HAccept` | `Sources/ConduitHelper/HelperDaemon.swift` `processRequest`: the publisher's `arm`, `disarm`, `relayStarted` from `startDNSRelay`, and `.stopDNSRelay` (`disarm(.relayStopped)`, then stop) |
| `HTick`, `h.probeOK`, `h.refused`, `h.silent` | `VPNDNSOverridePublisher.tick`: `relay.probe()`, `refusedTicksToWithdraw`, `silentTicksToWithdraw`, `relay.setMode` |
| `HOwnerExit`, `ExitPending`, `HelperFree`, `WatchOwner`, `WithdrawsOnExit` | `HelperDaemon.run`'s `loop.watchOwner(...)` and `.ownerExited`, calling `VPNDNSOverridePublisher.ownerExited`; `Sources/ConduitHelper/HelperEventLoop.swift` `ordered` |
| `HelperDown`, `HStart` | the helper killed or stopped (configd's `cleanupSession` removing its key); launchd starting it |
| `relay`, `RelayDies`, `HRelayRestart`, `FailoverTarget`, `FiltersLoopback`, `Answers`, `PerQueryFailover`, `KeyTargetsRelay` | `Sources/ProxyKernel/Network/DNSFailoverRelay.swift`: `DNSFailoverRoute` (mode, `setServers` through `VPNDNSOverrideValidation.failoverServers`), `DNSFailoverUDPRelay` (`receiveFromConduit`, `expire`), `DNSFailoverTCPRelay.serve`, `DNSFailoverRelay.restartDeadHalves` with `HelperDaemon.restartDeadFailoverHalves` and the publisher's `relayRestarted`; the key's `ServerPort` from `ownKey(port: relay.listeningPort)` |
| `ReadingOf`, `IgnoresOwnKey`, `AppRead`, `Snap` | `Sources/PlatformMac/PushedResolver.swift` `PushedResolverReading.parse` (Conduit's key skipped by `HelperConstants.vpnDNSOverrideServiceID`); `Sources/PlatformMac/PushedResolverMonitor.swift` |
| `Want`, `ServersInUse`, `MayArm`, `ReleasesUnconfirmed`, `AppPass`, `AppPoll` | `Sources/PlatformMac/VPNResolverOverridePolicy.swift` `decide`, `wanted`; `Sources/PlatformMac/VPNResolverOverrideController.swift` `mayArm`, `decide` (`unconfirmed ?? armed`), `pass`, `arm`, `disarm`, `status`, `confirm` |
| `AppTake`, `NewSet`, `HoldBeforeDisarm` | `Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift` `applyPendingSplitDNSDetection`; `Sources/ConduitRuntime/RuntimeHostVPNDNSOverride.swift` |
| `AppRestartRelay`, `AppStartDNS`, `AppStop`, `AppTdDisarm`, `AppTdRelay`, `AppCallFails` | `RuntimeHost.handleDNSHealthResult`, `startDNSModule`, `RuntimeHostLifecycle`'s DNS teardown; a call while the helper is down |
| `OwnerExit`, `AppLaunch`, `ForwarderFault`, `ForwarderRecovers` | the environment |

## Semantic choices

1. Each helper event is one step: the helper serves one event at a time, and each store call is atomic. The model's helper never interleaves with itself.
2. configd removes a dead session's temporary key as the session's port dies, in the same step as the helper going down. A gap between the two is left out; launchd's restart throttle is longer than it.
3. A removal of Conduit's key always succeeds: the publisher closes its session when the store refuses one.
4. The VPN's servers answer while the VPN publishes them (`VPNUsable`): its service is up and its key holds a list that is not loopback. A disconnect, a flap or a loopback-only list is the baseline's problem as much as the override's, so `KeyAnswered` does not ask for an answer then.
5. Per-query failover is abstracted to `Answers`: a lookup the relay sends to a Conduit that refuses or is silent is answered by the VPN's servers. Its timing (1 s, a 500 ms probe) and caps (1,024 pending queries, three servers) belong to the relay tests.
6. A healthy monitor reads only on a store notification; two changes between reads are one notification. Conduit's own key notifies it only in `ov-reads-own-key`.
7. Arming is intent: the helper accepts every arm, and publishing is its own decision. A lost arm reply leaves the app's arm unconfirmed (`unArm`) until a status.
8. The app's pass is one step, and a set that arrives while the key may be armed is held until the disarm returns.

## What it leaves out

Two VPN services and split tunnels; the primary-service lag behind a reading; fields other than `ServerAddresses`; the relay's port; reboots; a hung helper; a relay that cannot re-bind; the resolver order and the app's `not_first` check (`Sources/PlatformMac/ResolverOrder.swift`); the one-time legacy restore at helper start (`VPNDNSOverrideLegacyRestore`), which writes the VPN's key only when a helper from the rewrite left `127.0.0.1` in it; DoH and the forwarder's own routing.

One difference from `HAccept`: the model's arm takes `probeOK` from the forwarder's state at once, while the code probes through the relay, so an arm made before `start-dns-relay` publishes only after the next answered tick. It delays a publish and cannot publish a key the model would not.

## A real bug or a modeling error?

When a check fails, read the path with `/statechart`, then:

1. Map each step to the code through the coverage record. If a step does something the code cannot do, the model is wrong: fix the action and say why in the commit.
2. If every step is possible, replay it in a publisher test, a relay test or a pm-sim scenario. A replay that shows the harm is a bug: report it with the path in the code's words, and record it as a `bug-` entry with its fix in `OVERRIDE.fixes`. Do not weaken the property or the model to make it pass, and do not fix product code as part of a model change.
3. A path that is possible but harmless means the property is too strong for what the owner decided; ask the owner before changing it.

## When the code changes on purpose

Change the action that stands for the code, keep the property, and run `check.py --spec override --mutants`. Every mutant must still be caught; a mutant whose text no longer matches the spec makes `check.py` stop with the text it looked for. Each mutant's `swift` text in `check.py` names the change it mirrors, by function. Add a mutant for each bug you fix. Then update the coverage record and move the sync commit.
