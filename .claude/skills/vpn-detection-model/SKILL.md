---
name: vpn-detection-model
description: Model-check Conduit's VPN detection chain (dynamic store, VPNStatusMonitor, VPNFlapTimer, SplitDNSVPNGate, RuntimeHost entry files, ProxyOrchestrator blind handling) with the TLA+ spec in formal/vpn-detection. Use when a change touches any file in its coverage record, when a VPN on/off bug is reported, or to show a race in that chain as a TLC counterexample.
---

# VPN detection model

The owner's requirement is that VPN detection, on or off, is never wrong. `formal/vpn-detection/VPNDetection.tla` models the chain from a dynamic-store notification to the `/etc/resolver` entry files, with every interleaving of the monitor queue, the host's unordered deliveries, the platform queue, stops, restarts and the environment, under small bounds. TLC checks it. `VPNFlapTimerModelCheckTests` covers the timer on its own; this model covers the interleavings around it, where the earlier bugs lived.

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
```

It needs Java 11 or later. The first run fetches `tla2tools.jar` v1.7.4 from the TLA+ GitHub release into `formal/.tools/` and checks its SHA-256. Each check writes `formal/vpn-detection/.out/<check>/tlc.out`. CI runs it in the `vpn-detection-model` job of `.github/workflows/swift.yml`. Runtimes are in the PR that added it and in the output; expect a few minutes for everything on a laptop. A check's TLC state files can reach a few hundred MB while it runs and are removed after.

Read every result with the `/statechart` skill: give it the spec and the config from `.out/<check>/`, and it shows each violation as its shortest path in plain words, or charts the states when the check passes (make the bounds smaller first; the chart budget is small). Before you trust a path, replay it against the Swift, one step per action, in a `VPNStatusMonitorTests` or `RuntimeHost` test over `FakeTunnelStore` and `FakeStoreObserverClock`.

## What it checks

Safety, in every reachable state:

- `NoEntryFilesOffVPN`. Once the system settles, an entry file exists only while the proxy runs, the store reads, and a tunnel has an IPv4 address; after a Stop none exists. Harm: lookups under the managed domains, the VPN gateway's own name among them, go to servers no route reaches.
- `GateFollowsLastPublished`. Once the host has taken every report, `SplitDNSVPNGate` holds the verdict the monitor published last. Harm: a failure or a drop the monitor reported is never acted on.
- `NothingPublishedAfterStop`. After `VPNStatusMonitor.stop` returns, nothing of that session is published: no event, no verdict. Harm: an obsolete verdict turns the retained gate and writes entry files.
- `WakeRecoversOnlyWhenSeeing`. A system wake never ends a flap while the monitor is blind. Harm: `VPNReactionHistory.recoverFlap`'s assert, and a verdict nobody read.
- `SweepsNotHeldWhenDefinite`. Once the orchestrator has taken every report, a definite connected or disconnected verdict never leaves the stranded-socket sweeps held. Harm: clients stall on sockets whose path is gone.

Liveness, under the fairness in `Fairness` (code that has work runs, time passes, the helper and the VPN client come back; nothing forces the store to heal, a Start or a Stop):

- `NoStuckUnknown`. While the proxy runs and the store can be read, the gate leaves `.unknown`.
- `FilesFollowVPN`. The entry files end up present exactly while the proxy runs, the store reads and the tunnel is up.
- `VPNReconnects`. A VPN that is down comes back: no entry file keeps the client from resolving its gateway (the bootstrap deadlock).

Known gap, expected to break until design unit U4 lands (`known-gap-u4`):

- `ApplyOnlyFromCurrentSession`. No entry file write is decided while the monitor is stopped. Today `applyProxySurfaces` and its gate-moved correction read the gate the previous session left, before `startObservers`. If the VPN dropped while the proxy was stopped, the files go back until the new session's first reading removes them. When U4 delivers the first verdict before surfaces are applied, this check starts passing and `check.py` fails on it: move it into the safety list then.

## Bounds

Every check runs two Starts (each with one Stop), one notified tunnel drop and one store outage, with the VPN client reconnecting after each. Each check adds one more kind of trouble: `safety-core` a refused subscription cancel and a consumer restart from inside `onEvent`; `-lost-notification` a store change whose notification never arrives, in place of the notified drop; `-helper-outage` a helper that stops answering; `-orchestrator` the orchestrator's reactions and one system wake. `liveness-helper-outage` runs one Start: the retry is what it checks, and with two Starts TLC's liveness pass takes over five minutes. The budgets are in `check.py`.

The proxy launches on a readable store with the VPN up or down. A launch on an unreadable store is a `StoreBreak` before the first Start, and a tunnel that lost its address reads, to a new session, as no tunnel. A wake-up made stale by a newer one is dropped from the queue, because `wake` compares `wakeID` and does nothing. What a stopped session or a finished apply saw is cleared, because nothing reads it again. Each of these cuts states without removing a behaviour the code has; undo one if the code starts to read what it drops. One tunnel stands for the store, the flap windows are fixed, and real time is three marks per loss (inside `minVisible`, inside grace, past both).

## Coverage record

Synced at 59c4bcc8 (origin/main after #317). Move this forward only after you confirm, function by function, that the model still describes the code at the new commit.

| Model | Code |
| --- | --- |
| `store`, `Read`, `Notify`, `pendingCb`, `liveSubs` | `SystemTunnelStore` / `TunnelStoreReading.read`, `subscribe` (configd marks each subscription once; a cancelled session's queued callback may still run, `FakeTunnelStore.signalsQueuedBeforeCancelStillRun`) |
| `Settle`, `Outcomes`, `HasDeadline`, `NextLoss`, `AgeLoss` | `Sources/ProxyKernel/Network/VPNFlapTimer.swift`: `VPNFlapTimer.reconcile`, `settle` (blind gap per 0047) |
| `ReadDue` | `Sources/ProxyKernel/Network/StoreReadSchedule.swift`: `failed(at:)` retry, `succeeded(at:)` audit |
| `lc`, `IsCurrent` | `Sources/PlatformMac/VPNStatusMonitor.swift`: `LifecycleState`, `isCurrent` |
| `StartItem`, `HStartApplied` (start half) | `VPNStatusMonitor.start` and its `monitorQueue.async` block |
| `Attempt` | `VPNStatusMonitor.attempt` (subscribe, install under the lifecycle lock, read) |
| `StoreItem` | `VPNStatusMonitor.storeChanged` |
| `WakeItem`, `WakeFire`, `Arm`, `StaleWakes` | `VPNStatusMonitor.wake`, `arm` (one `Task` on `StoreObserverClock.sleep`, `wakeID`) |
| `Decide` | `VPNStatusMonitor.reconcile`, the part before `barrier.deliver` |
| `Enter`, `VerdictCheck`, `Call`, `EnterCheck`, `VerdictCheckOK` | `reconcile`'s `barrier.deliver` block: session, arm, events, names, `onChange` |
| `StopMonitor`, `StopWaitsForBarrier`, `BarrierPCs` | `VPNStatusMonitor.stop`, `Sources/PlatformMac/ObserverStopBarrier.swift` |
| `CallbackRestart` | a consumer calling `stop` and `start` from `onEvent` (`ObserverStopBarrier` is recursive) |
| `Call` (stamp and hop), `inbox` | `RuntimeHost.init`'s `vpnStatusMonitor.setOnChange` closure, `VPNObservationSequencer.next`, `ObserverDeliveries.deliver` |
| `HostDeliver`, `GateDropsOlder`, `HostTakesReports`, `EntryOp`, `Wanted` | `Sources/ConduitRuntime/RuntimeHost.swift`: `handleVPNStateChange`, `reconcileEntryFiles`; `VPNObservationOrder.admit`; `Sources/PlatformMac/SplitDNSVPNGate.swift`: `entriesWanted`, `update`, `action`, `entryFileOperation` |
| `HStartBegin`, `HStartApplied` | `RuntimeHostLifecycle.runStartEffect` -> `RuntimeHost.applyProxySurfaces` (apply, `runtimeStarted`, `gateMoved` correction) -> `startObservers` |
| `HStopBegin`, `HStopDone` | `RuntimeHostLifecycle.tearDown` (`vpnStatusMonitor.stop()`, `runtimeStarted = false`) and the proxy teardown's `resolvers.clear` |
| `platQ`, `PlatformRun`, `files`, `helperUp` | `Sources/PlatformMac/PlatformWork.swift` `run`; `SplitDNSVPNGate.perform` -> `DNSManager.applyEntryFiles` / `clearEntryFiles` through the helper |
| `repair`, `Retry` | `Sources/PlatformMac/SplitDNSEntryFileRepair.swift` `record`, `desiredOperation`; `RuntimeHost.observeHelperForSplitDNS`, `retrySplitDNSEntryFiles` |
| `OrchHandle`, `orch` | `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift` `handleVPNStateChange`; `Sources/ProxyKernel/Network/VPNReactionHistory.swift` `record`; `startStrandedSweeps`, `holdStrandedSweeps`, `resumeStrandedSweeps` |
| `SystemWake`, `WakeSeesStore` | `ProxyOrchestrator.handleSystemWake` -> `recoverStaleReassertingAfterWake`, `VPNReactionHistory.recoverFlap` |
| `VPNConnect`, `CanConnect` | the VPN client: it reaches its gateway only while no entry file captures the gateway's name |

Each atomic step and why it is one:

- `MonStep` with `Decide`: one `monitorQueue` block up to `barrier.deliver`. Only the monitor thread touches `session`; a Stop on another thread between a check and the install is covered by a Stop before the step (the check fails) or after it (the publish check fails).
- `Enter`, then `VerdictCheck`, then `Call`: inside `barrier.deliver`. Another thread's `stop` cannot enter (`StopWaitsForBarrier`); only a callback can stop from inside, so the steps split where a callback runs.
- `HostDeliver`: one `RuntimeActor` turn. The gate update, the decision and the `platformWork.run` queueing happen with no suspension (`handleVPNStateChange`'s comment, `PlatformWork.run`).
- `HStopBegin`: `stop()` and `runtimeStarted = false` are one turn; the clear is queued after suspensions, but a report in between can queue only a removal, so one step stands for both.
- `HStartApplied`: the correction after the apply and the observers' start are separate turns; a report can land on either side, which the model allows before and after this step.

## What it leaves out

- The two-tunnel timer, Settings window changes, names (`connectedInterfaceName`, `liveInterfaceNames`), disconnect reasons and malformed keys: `VPNFlapTimerModelCheckTests` and `VPNStatusMonitorTests`.
- The attempt numbers that decide which failures emit `vpn.store_failed`: every failure is modelled as emitting.
- A Stop during a Start, lifecycle-lane supersession, the DNS and tunnel members, intercept resolver files, config reloads, launch recovery, and files left by a crash.
- The orchestrator's routing, probes and direct mode; only `VPNReactionHistory` and the sweeps are modelled, in their own check.
- `LiveSplitDNSDetection` and `PushedResolverMonitor` (decision 0044), which share the barrier but not this gate.
- A wake-up that re-reads an unchanged store does not fire (`WakeFire` needs `~ghost.fresh`). That is sound because a reconcile on the same reading is idempotent, which the timer tests check.

## A real bug or a modeling error?

When a check fails, read the path with `/statechart`, then:

1. Map each step to the code through the coverage record. If a step does something the code cannot do (two `monitorQueue` blocks at once, a Stop inside the barrier from another thread, a report the host takes in two turns), the model is wrong: fix the action and say why in the commit.
2. If every step is possible, replay it in a test over `FakeTunnelStore`, `FakeStoreObserverClock` and the `RuntimeHost` harness. A replay that shows the harm is a bug: file it with the path in the code's words. Do not weaken the property or the model to make it pass, and do not fix product code as part of a model change.
3. A path that is possible but harmless means the property is too strong for what the owner decided; ask the owner before changing it.

## When the code changes on purpose

Change the action that stands for the code, keep the property, and run `check.py --mutants`. Every mutant must still be caught; a mutant whose text no longer matches the spec makes `check.py` stop with the text it looked for, so update its edit to the new spec. Add a mutant for each new bug you fix in this chain: the Swift change that reintroduces it, the same change in the spec, and the property that catches it. Then update the coverage record and move the sync commit.
