---
name: vpn-detection-model
description: Model-check Conduit's VPN detection chain (dynamic store, VPNStatusMonitor, VPNFlapTimer, SplitDNSVPNGate, RuntimeHost entry files, ProxyOrchestrator blind handling) with the TLA+ spec in formal/vpn-detection. Use when a change touches any file in its coverage record, when a VPN on/off bug is reported, or to show a race in that chain as a TLC counterexample.
---

# VPN detection model

The owner's requirement is that VPN detection, on or off, is never wrong. `formal/vpn-detection/VPNDetection.tla` models the chain from a dynamic-store notification to the `/etc/resolver` entry files. TLC checks every interleaving of the steps the model has, under small bounds: the monitor queue and its barrier, the host's unordered deliveries, the platform queue and the out-of-order resumption of the tasks waiting on it, Start and Stop, and the environment. The atomic steps are listed below with the Swift turn each stands for; an interleaving inside one of them, or of code the model leaves out, is not checked. `VPNFlapTimerModelCheckTests` covers the timer on its own; this model covers the interleavings around it, where the earlier bugs lived.

## Does my change touch it?

It does if it changes the behaviour of any function in the coverage record below, or adds a path that feeds the gate, writes entry files, or publishes a VPN verdict. Compare against the sync commit:

```sh
git diff --stat 59c4bcc8 -- Sources/PlatformMac/VPNStatusMonitor.swift Sources/PlatformMac/ObserverStopBarrier.swift \
  Sources/PlatformMac/StoreObserverClock.swift Sources/ProxyKernel/Network/StoreReadSchedule.swift \
  Sources/ProxyKernel/Network/VPNFlapTimer.swift Sources/PlatformMac/SplitDNSVPNGate.swift \
  Sources/PlatformMac/SplitDNSEntryFileRepair.swift Sources/ProxyKernel/Network/VPNObservationSequencer.swift \
  Sources/ProxyKernel/Network/VPNReactionHistory.swift Sources/ConduitRuntime/RuntimeHost.swift \
  Sources/ConduitRuntime/RuntimeHostLifecycle.swift Sources/PlatformMac/PlatformWork.swift \
  Sources/PlatformMac/ObserverDeliveries.swift Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift
```

`RuntimeHost.swift`, `RuntimeHostLifecycle.swift` and `ProxyOrchestrator.swift` are large; only the functions named below matter.

## Run it

```sh
python3 formal/vpn-detection/check.py             # what CI runs without the mutants
python3 formal/vpn-detection/check.py --mutants   # what CI runs: also each historical bug, caught
python3 formal/vpn-detection/check.py --only safety-core
python3 formal/vpn-detection/check.py --full      # the helper-outage checks at their larger bounds
```

It needs Java 11 or later. The first run fetches `tla2tools.jar` v1.7.4 from the TLA+ GitHub release into `formal/.tools/` and checks its SHA-256. Each check writes `formal/vpn-detection/.out/<check>/tlc.out`. CI runs it in the `vpn-detection-model` job of `.github/workflows/swift.yml`. Runtimes are in the PR and in the output; expect about ten minutes for `--mutants` on a laptop. A check's TLC state files can reach a few hundred MB while it runs and are removed after.

Read every result with the `/statechart` skill: give it the spec and the config from `.out/<check>/`, and it shows each violation as its shortest path in plain words, or charts the states when the check passes (make the bounds smaller first; the chart budget is small). Before you trust a path, replay it against the Swift, one step per action, in a `VPNStatusMonitorTests` or `RuntimeHost` test over `FakeTunnelStore` and `FakeStoreObserverClock`.

## What it checks

Safety, in every reachable state:

- `NoEntryFilesOffVPN`. Once the system settles, an entry file exists only while the proxy runs, the store reads, and a tunnel has an IPv4 address; after a Stop none exists. Harm: lookups under the managed domains, the VPN gateway's own name among them, go to servers no route reaches.
- `GateFollowsLastPublished`. Once the host has taken every report, `SplitDNSVPNGate` holds the verdict the monitor published last. Harm: a failure or a drop the monitor reported is never acted on.
- `NothingPublishedAfterStop`. After `VPNStatusMonitor.stop` returns, nothing of that session is published: no store-failure event, no verdict. Cancellation reports and the names are not modelled, so they are not covered. Harm: an obsolete verdict turns the retained gate and writes entry files.
- `WakeRecoversOnlyWhenSeeing`. A system wake never ends a flap while the monitor is blind. Harm: `VPNReactionHistory.recoverFlap`'s assert, and a verdict nobody read.
- `SweepsNotHeldWhenDefinite`. A definite connected or disconnected verdict the orchestrator can see never leaves the stranded-socket sweeps held. Harm: clients stall on sockets whose path is gone.
- `OrchestratorAfterEntryFiles`. The orchestrator hears of a report only after the entry-file operation that report's gate turn queued has run, the ordering the runtime-DNS-effects r2 acceptance records. Harm: its reprobe and sweeps act on a network whose resolvers are not there yet.
- `OrchestratorFollowsLastPublished`. Once no report is on its way, the verdict the orchestrator applied last is the one the monitor published last (#155). Harm: routing and the sweeps follow an older tunnel state.

Liveness, under the fairness in `Fairness`: code that has work runs, every task waiting on `platformWork` resumes, time passes, and the helper and the VPN client come back. Startup progresses: a Start whose surfaces are applied reaches `startObservers`, which assumes the DNS and tunnel member starts return. Nothing forces the store to heal, a Start or a Stop.

- `NoStuckUnknown`. While the proxy runs and the store can be read, the gate leaves `.unknown`.
- `FilesFollowVPN`. The entry files end up present exactly while the proxy runs, the store reads and the tunnel is up.
- `VPNReconnects`. A VPN that is down comes back: no entry file keeps the client from resolving its gateway (the bootstrap deadlock).

Known gap, expected to break until design unit U4 lands (`known-gap-u4`):

- `ApplyOnlyFromCurrentSession`. No entry file write is decided while the monitor is stopped. Today the gate survives Stop and Start (`tearDown` stops the monitor but keeps `splitDNSGate`), so `applyProxySurfaces` and its gate-moved correction write from the verdict the previous session left, before `startObservers`. If the VPN dropped while the proxy was stopped, the files go back. The removal waits for the Start to finish its DNS and tunnel members and reach `startObservers`, then for the new session's reading, its delivery and the platform queue. With the VPN gateway under a managed domain, reconnection stalls for that interval. A planned product fix resets the gate when the monitor stops, so a restart starts from `.unknown` like a cold start. Once it merges this check starts passing and `check.py` fails on it: move `ApplyOnlyFromCurrentSession` into the safety list then. A proxy-only Stop with another module still up keeps the monitor running (`tearDown`'s `remaining.union(modulesDown())` check); the model's lifecycle starts and stops every module together.

## Bounds

Every check runs two Starts (each with one Stop), one notified tunnel drop and one store outage, with the VPN client reconnecting after each. Each check adds one more kind of trouble: `safety-core` a refused subscription cancel and a consumer restart from inside `onEvent`; `-lost-notification` a store change whose notification never arrives, in place of the notified drop; `-helper-outage` a helper that stops answering; `-orchestrator` the orchestrator's reactions and one system wake. The budgets are in `check.py`.

The helper-outage checks are the exception, because there every operation's outcome can be recorded out of order and the places matter. By default `safety-helper-outage` runs one Start (30 s) and `liveness-helper-outage` one Start with no store outage (8 s). `--full` runs them at two Starts (34.5M states, 6 minutes) and at one Start with the store outage (3.6M states, 9 minutes) on a 12-core laptop. Run `--full` after a change to the repair, the platform queue or the start's correction.

The proxy launches on a readable store with the VPN up or down. A launch on an unreadable store is a `StoreBreak` before the first Start, and a tunnel that lost its address reads, to a new session, as no tunnel. A wake-up made stale by a newer one is dropped from the queue, because `wake` compares `wakeID` and does nothing. What a stopped session or a finished apply saw is cleared, because nothing reads it again. Report stamps and queue places are only compared with one another: stamps restart from 0 once no report is in flight, and after each record the places still held are renumbered 1..n in order. With no helper outage nothing is ever pending, so places stay 0 and a VPN operation's record, a no-op then, is folded into `PlatformRun`. Without the orchestrator, a report the gate will skip does nothing when it runs, so it is dropped when the newer one is taken. Each of these cuts states without removing a behaviour the code has; undo one if the code starts to read what it drops. One tunnel stands for the store, the flap windows are fixed, and real time is three marks per loss (inside `minVisible`, inside grace, past both).

## Coverage record

Synced at 59c4bcc8 (origin/main after #317). Move this forward only after you confirm, function by function, that the model still describes the code at the new commit.

| Model | Code |
| --- | --- |
| `store`, `Read`, `Notify`, `pendingCb`, `liveSubs` | `SystemTunnelStore` / `TunnelStoreReading.read`, `subscribe` (configd marks each subscription once; a cancelled session's queued callback may still run, `FakeTunnelStore.signalsQueuedBeforeCancelStillRun`) |
| `Settle`, `Outcomes`, `HasDeadline`, `NextLoss`, `AgeLoss` | `Sources/ProxyKernel/Network/VPNFlapTimer.swift`: `VPNFlapTimer.reconcile`, `settle` (blind gap per 0047) |
| `ReadDue` | `Sources/ProxyKernel/Network/StoreReadSchedule.swift`: `failed(at:)` retry, `succeeded(at:)` audit |
| `lc`, `IsCurrent` | `Sources/PlatformMac/VPNStatusMonitor.swift`: `LifecycleState`, `isCurrent` |
| `StartItem`, `HStartObservers` (start half) | `VPNStatusMonitor.start` and its `monitorQueue.async` block |
| `Attempt` | `VPNStatusMonitor.attempt` (subscribe, install under the lifecycle lock, read) |
| `StoreItem` | `VPNStatusMonitor.storeChanged` |
| `WakeItem`, `WakeFire`, `Arm`, `StaleWakes` | `VPNStatusMonitor.wake`, `arm` (one `Task` on `StoreObserverClock.sleep`, `wakeID`) |
| `Decide` | `VPNStatusMonitor.reconcile`, the part before `barrier.deliver` |
| `Enter`, `VerdictCheck`, `Call`, `EnterCheck`, `VerdictCheckOK` | `reconcile`'s `barrier.deliver` block: session, arm, events, names, `onChange` |
| `StopMonitor`, `StopWaitsForBarrier`, `BarrierPCs` | `VPNStatusMonitor.stop`, `Sources/PlatformMac/ObserverStopBarrier.swift` |
| `CallbackRestart` | a consumer calling `stop` and `start` from `onEvent` (`ObserverStopBarrier` is recursive) |
| `Call` (stamp and hop), `stamp`, `inbox` | `RuntimeHost.init`'s `vpnStatusMonitor.setOnChange` closure, `VPNObservationSequencer.next`, `ObserverDeliveries.deliver` |
| `HostDeliver`, `GateAdmits`, `HostTakesReports`, `Observing`, `OrchestratorAfterFiles`, `EntryOp`, `Wanted` | `Sources/ConduitRuntime/RuntimeHost.swift`: `handleVPNStateChange` (gate turn, then `await reconcileEntryFiles`, then the orchestrator), `reconcileEntryFiles`, `networkPathObserving`; `splitDNSGateOrder` (`VPNObservationOrder.admit`); `Sources/PlatformMac/SplitDNSVPNGate.swift`: `entriesWanted`, `update`, `action`, `entryFileOperation` |
| `HStartBegin` | `RuntimeHostLifecycle.runStartEffect` -> `RuntimeHost.applyProxySurfaces`: `vpnConnected`, `gateReportSeen`, `entryPlace`, the `platformWork.run` block |
| `RecordOutcome` (owner `start`, `correction`), `StartedAtSurfaces` | `applyProxySurfaces` after its block: `recordSplitDNS(.start)`, `runtimeStarted = true`, the `gateMoved` correction through `reconcileEntryFiles` and its record |
| `HStartObservers` | `RuntimeHostLifecycle.runAdmittedStart` after `applyProxySurfaces`: `startDNSModule`, `orchestrator.startTunnels`, then `startObservers` |
| `HStopBegin`, `RecordOutcome` (owner `stop`) | `RuntimeHostLifecycle.tearDown` (`vpnStatusMonitor.stop()`, `runtimeStarted = false`) and `tearDownProxy`'s `stopPlace`, `resolvers.clear` and `recordSplitDNS(.stop)` |
| `platQ`, `done`, `PlatformRun`, `files`, `helperUp` | `Sources/PlatformMac/PlatformWork.swift` `run`; `SplitDNSVPNGate.perform` -> `DNSManager.applyEntryFiles` / `clearEntryFiles` through the helper; `done` is the tasks `platformWork.run` has finished for and that have not yet resumed on `RuntimeActor` |
| `repair`, `NextPlace`, `RecordOutcome`, `RecordKeeps`, `Retry` | `Sources/PlatformMac/SplitDNSEntryFileRepair.swift` `queue`, `record` (the `startedAt < generation` guard), `desiredOperation`; `RuntimeHost.recordSplitDNS`, `observeHelperForSplitDNS`, `retrySplitDNSEntryFiles` |
| `OrchHandle`, `OrchAdmits`, `orch` | `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift` `handleVPNStateChange` up to its first suspension: `vpnObservations.admit`, the switch over the change, `startStrandedSweeps`, `holdStrandedSweeps`, `resumeStrandedSweeps` |
| `Change`, `Recorded`, `ConfirmsAfterBlind`, `React` | `Sources/ProxyKernel/Network/VPNReactionHistory.swift` `record` (`.blinded`, `.transition`, `.confirmed(afterBlind:)`, nil) |
| `SystemWake`, `WakeSeesStore` | `ProxyOrchestrator.handleSystemWake` -> `recoverStaleReassertingAfterWake`, `VPNReactionHistory.recoverFlap` |
| `VPNConnect`, `CanConnect` | the VPN client: it reaches its gateway only while no entry file captures the gateway's name |

`Observing` stands for `networkPathObserving`, which `startObservers` sets and `tearDown` clears when no module stays up. It equals `host.phase = "running"` only because the model starts and stops every module together; the `b3` mutant relies on that. The `blinded-keeps-sweeps` mutant removes `wasBlind ||` from `VPNReactionHistory.record`'s guard, the Swift change itself; the tunnel-replacement half of that guard is not modelled.

Each atomic step and why it is one:

- `MonStep` with `Decide`: one `monitorQueue` block up to `barrier.deliver`. Only the monitor thread touches `session`; a Stop on another thread between a check and the install is covered by a Stop before the step (the check fails) or after it (the publish check fails).
- `Enter`, then `VerdictCheck`, then `Call`: inside `barrier.deliver`. Another thread's `stop` cannot enter (`StopWaitsForBarrier`); only a callback can stop from inside, so the steps split where a callback runs.
- `HostDeliver`: one `RuntimeActor` turn. The gate's admit and update, the decision and the `platformWork.run` queueing happen with no suspension (`handleVPNStateChange`'s comment, `PlatformWork.run`). A report the gate skips still goes on to the orchestrator. When nothing is queued, `reconcileEntryFiles` returns without suspending and `orchestrator.handleVPNStateChange`, a `RuntimeActor` method, runs its order check, `VPNReactionHistory.record` and the sweep decision before its first suspension, so they are part of this turn. When an operation is queued, the task waits for it and calls the orchestrator in its `RecordOutcome`.
- `PlatformRun`, then `RecordOutcome`: the operation runs on the platform queue in queue order; the task that queued it resumes on `RuntimeActor` later, in any order against the other waiting tasks, and records it. `SplitDNSEntryFileRepair.record` drops an outcome queued before one already recorded. `recordSplitDNS` suspends again only to retry a failed intercept refresh, which the model leaves out, so the record and the rest of the task's turn are one step: the start's `runtimeStarted = true` and correction, or the orchestrator call.
- `HStartObservers`: a separate step, because `runAdmittedStart` awaits the DNS and tunnel member starts between `applyProxySurfaces` and `startObservers`. In between, the proxy's surfaces are up and no session of the new Start is reading; reports of the last session can still land.
- `HStopBegin`: `stop()` and `runtimeStarted = false` are one turn; the clear is queued after suspensions, but a report in between can queue only a removal, so one step stands for both.
- `Retry`: `retrySplitDNSEntryFiles`' decision turn (`planRetry` and the queueing). `observeHelperForSplitDNS` checked and set `splitDNSRetryInFlight` earlier; the model takes both at the decision, which is where the gate and `runtimeStarted` are read.

## What it leaves out

- The two-tunnel timer, Settings window changes, names (`connectedInterfaceName`, `liveInterfaceNames`), disconnect reasons and malformed keys: `VPNFlapTimerModelCheckTests` and `VPNStatusMonitorTests`.
- The attempt numbers that decide which failures emit `vpn.store_failed`: every failure is modelled as emitting.
- A Stop during a Start, lifecycle-lane supersession, the DNS and tunnel members (only the time their starts take, as `HStartObservers`), intercept resolver files and their refresh retry in `settleResolverSwitchBaseline`, residue, config reloads and the resolver switch, launch recovery, and files left by a crash.
- What `handleVPNStateChange` does after the orchestrator returns (`reconcileSystemDNSIfRunning`) and the orchestrator's work after its first suspension.
- The orchestrator's routing, probes and direct mode; only `VPNReactionHistory` and the sweeps are modelled, in their own check.
- `LiveSplitDNSDetection` and `PushedResolverMonitor` (decision 0044), which share the barrier but not this gate.
- A wake-up that re-reads an unchanged store does not fire (`WakeFire` needs `~ghost.fresh`). That is sound because a reconcile on the same reading is idempotent, which the timer tests check.

## A real bug or a modeling error?

When a check fails, read the path with `/statechart`, then:

1. Map each step to the code through the coverage record. If a step does something the code cannot do (two `monitorQueue` blocks at once, a Stop inside the barrier from another thread, a gate update and its queueing in two turns), the model is wrong: fix the action and say why in the commit.
2. If every step is possible, replay it in a test over `FakeTunnelStore`, `FakeStoreObserverClock` and the `RuntimeHost` harness. A replay that shows the harm is a bug: file it with the path in the code's words. Do not weaken the property or the model to make it pass, and do not fix product code as part of a model change.
3. A path that is possible but harmless means the property is too strong for what the owner decided; ask the owner before changing it.

## When the code changes on purpose

Change the action that stands for the code, keep the property, and run `check.py --mutants`. Every mutant must still be caught; a mutant whose text no longer matches the spec makes `check.py` stop with the text it looked for, so update its edit to the new spec. Add a mutant for each new bug you fix in this chain: the Swift change that reintroduces it, the same change in the spec, and the property that catches it. Then update the coverage record and move the sync commit.
