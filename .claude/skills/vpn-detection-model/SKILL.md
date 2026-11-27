---
name: vpn-detection-model
description: Model-check Conduit's VPN detection chain (dynamic store, VPNStatusMonitor, VPNFlapTimer, SplitDNSVPNGate, RuntimeHost entry files, ProxyOrchestrator blind handling) with the TLA+ spec in formal/vpn-detection. Use when a change touches any file in its coverage record, when a VPN on/off bug is reported, or to show a race in that chain as a TLC counterexample.
---

# VPN detection model

The owner's requirement is that VPN detection, on or off, is never wrong. `formal/vpn-detection/VPNDetection.tla` models the chain from a dynamic-store notification to the `/etc/resolver` entry files. TLC checks every interleaving of the steps the model has, under small bounds: the monitor queue and its barrier, the host's unordered deliveries, the platform queue and the out-of-order resumption of the tasks waiting on it, Start and Stop, and the environment. The atomic steps are listed below with the Swift turn each stands for; an interleaving inside one of them, or of code the model leaves out, is not checked. `VPNFlapTimerModelCheckTests` covers the timer on its own; this model covers the interleavings around it, where the earlier bugs lived.

## Does my change touch it?

It does if it changes the behaviour of any function in the coverage record below, or adds a path that feeds the gate, writes entry files, or publishes a VPN verdict. List the covered files changed since the sync commit:

```sh
python3 formal/vpn-detection/check.py --changed 54f49441
```

It prints the files in `COVERED` in `check.py` that differ from the commit, and the model's own files (`VPNDetection.tla`, `check.py`, this skill), together with those of the 0049 override spec (skill `vpn-dns-override-model`, `OVERRIDE_COVERED`). `COVERED` is the one list of this spec's covered files: CI reads it through `check.py --full-for`, which names the specs whose files changed, to choose each spec's tier, so a file added to the coverage record table must be added there too, and `--changed` fails if a listed file no longer exists.

`RuntimeHost.swift`, `RuntimeHostLifecycle.swift` and `ProxyOrchestrator.swift` are large; only the functions named below matter.

## Run it

```sh
python3 formal/vpn-detection/check.py --mutants          # the default tier: every check, each historical bug caught
python3 formal/vpn-detection/check.py --full --mutants   # the full tier: larger bounds, the `--full` checks and their mutants
python3 formal/vpn-detection/check.py --only safety-core # one check or mutant (a `--full` one runs at its full bounds)
```

It needs Java 11 or later. The first run fetches `tla2tools.jar` v1.7.4 from the TLA+ GitHub release into `formal/.tools/` and checks its SHA-256. Each check writes `formal/vpn-detection/.out/<check>/tlc.out`. A check's TLC state files can reach a few GB while it runs and are removed after.

CI runs it in the `vpn-model (detection)` job of `.github/workflows/swift.yml`, beside a parallel `vpn-model (override)` job. Every pull request and push to main runs this spec's default tier (`--spec detection`, which also limits a local run to this one). The full tier (`--full=detection`) runs nightly on main when the spec's covered or model files changed since the last green nightly run, when the workflow is started by hand, and in `release.yml` on a tag, where it gates the draft release. CI does not run it for a pull request, so run it yourself when `check.py --full-for origin/main` names this spec, and always after a change to the repair, the platform queue, the start or its correction. Timings are under Bounds.

Read every result with the `/statechart` skill: give it the spec and the config from `.out/<check>/`, and it shows each violation as its shortest path in plain words, or charts the states when the check passes (make the bounds smaller first; the chart budget is small). Before you trust a path, replay it against the Swift, one step per action, in a `VPNStatusMonitorTests` or `RuntimeHost` test over `FakeTunnelStore` and `FakeStoreObserverClock`.

## What it checks

Safety, in every reachable state:

- `NoEntryFilesOffVPN`. Once the system settles, an entry file exists only while the proxy runs, the store reads, and a tunnel has an IPv4 address; after a Stop none exists. Harm: lookups under the managed domains, the VPN gateway's own name among them, go to servers no route reaches.
- `GateFollowsLastPublished`. Once the host has taken every report, `SplitDNSVPNGate` holds the verdict the monitor published last, or `.unknown` if the monitor stopped since (`RuntimeHost.stopVPNMonitor`, #324). Harm: a failure or a drop the monitor reported is never acted on, or a stopped session's verdict outlives it.
- `NothingPublishedAfterStop`. After `VPNStatusMonitor.stop` returns, nothing of that session is published: no store-failure event, no verdict. Cancellation reports and the names are not modelled, so they are not covered. Harm: an obsolete verdict turns the retained gate and writes entry files.
- `WakeRecoversOnlyWhenSeeing`. A system wake never ends a flap while the monitor is blind. Harm: `VPNReactionHistory.recoverFlap`'s assert, and a verdict nobody read.
- `SweepsNotHeldWhenDefinite`. A definite connected or disconnected verdict the orchestrator can see never leaves the stranded-socket sweeps held. Harm: clients stall on sockets whose path is gone.
- `OrchestratorAfterEntryFiles`. The orchestrator hears of a report only after the entry-file operation that report's gate turn queued has run, the ordering the runtime-DNS-effects r2 acceptance records. Harm: its reprobe and sweeps act on a network whose resolvers are not there yet.
- `OrchestratorFollowsLastPublished`. Once no report is on its way, the verdict the orchestrator applied last is the one the monitor published last (#155). Harm: routing and the sweeps follow an older tunnel state.
- `ApplyOnlyFromCurrentSession`. No entry-file write is decided while the monitor is stopped, from a verdict a stopped session left: a Start's apply and its gate-moved correction read a gate that `stopVPNMonitor` reset to `.unknown`, fenced against every report the stopped session stamped. Harm: if the VPN dropped while the proxy was stopped, the files come back, and with the gateway under a managed domain reconnection stalls until the new session's first reading lands. This was the U4 gap, fixed by #324; the `u4-gate-kept-at-stop` and `u4-no-fence-at-stop` mutants put it back.

Liveness, under the fairness in `Fairness`: code that has work runs, every task waiting on `platformWork` resumes, time passes, and the helper and the VPN client come back. Startup progresses: a Start whose surfaces are applied reaches `startObservers`, which assumes the DNS and tunnel member starts return. Nothing forces the store to heal, a Start or a Stop.

- `NoStuckUnknown`. While the proxy runs and the store can be read, the gate leaves `.unknown`.
- `FilesFollowVPN`. The entry files end up present exactly while the proxy runs, the store reads and the tunnel is up.
- `VPNReconnects`. A VPN that is down comes back: no entry file keeps the client from resolving its gateway (the bootstrap deadlock).

## Bounds

Every check runs two Starts, each with one Stop, one of which may take the proxy alone down and keep the monitor running. Each also has one notified tunnel drop and one store outage, with the VPN client reconnecting after each. Each check adds one more kind of trouble: `safety-core` a refused subscription cancel and a consumer restart from inside `onEvent`; `-lost-notification` a store change whose notification never arrives, in place of the notified drop; `-helper-outage` a helper that stops answering; `-orchestrator` the orchestrator's reactions and one system wake. The budgets are in `check.py`.

The helper-outage checks are the exception, because there every operation's outcome can be recorded out of order and the places matter. The default tier runs `safety-helper-outage` at one Start and `liveness-helper-outage` at one Start with no store outage. The full tier runs them at two Starts and at one Start with the store outage; the store outage is the case where the repair must remove the files while the proxy runs and the gate stays `.unknown`. It also runs `liveness-restart-helper-outage`: two Starts with the helper outage and no store outage, where a report landing after a Stop of the proxy alone queues the next Start's correction and the helper fails it. With the store outage as well, that check ran past 70 minutes and 12 GB of TLC state on 12 cores without finishing, so it is left out.

Measured at 54f49441 plus this model, on a 12-core laptop:

| Tier | `TLC_WORKERS` | Wall time |
| --- | --- | --- |
| default (`--mutants`) | auto (12) | 7 min 30 s |
| full (`--full --mutants`) | 4 | 44 min |

The full tier's largest checks are `liveness-helper-outage` (6.4M states, 23 min with 4 workers), `safety-helper-outage` (35.1M states, 7 min) and `safety-orchestrator` (43.5M states, 7 min). A 4-core CI runner is slower per core, so expect about 20 minutes for the default tier and 60 to 80 for the full tier there; the job's timeout is 120 minutes.

The proxy launches on a readable store with the VPN up or down. A launch on an unreadable store is a `StoreBreak` before the first Start, and a tunnel that lost its address reads, to a new session, as no tunnel. A wake-up made stale by a newer one is dropped from the queue, because `wake` compares `wakeID` and does nothing. What a stopped session or a finished apply saw is cleared, because nothing reads it again. Report stamps and queue places are only compared with one another: stamps restart from 0 once no report is in flight, and after each record the places still held are renumbered 1..n in order. With no helper outage nothing is ever pending, so places stay 0 and a VPN operation's record, a no-op then, is folded into `PlatformRun`. Without the orchestrator, a report the gate will skip does nothing when it runs, so it is dropped when the newer one is taken, or at the Stop that fences it. Each of these cuts states without removing a behaviour the code has; undo one if the code starts to read what it drops. One tunnel stands for the store, the flap windows are fixed, and real time is three marks per loss (inside `minVisible`, inside grace, past both).

## Coverage record

Synced at 54f49441 (origin/main after #324). Move this forward only after you confirm, function by function, that the model still describes the code at the new commit.

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
| `HostDeliver`, `GateAdmits`, `HostTakesReports`, `OrchestratorAfterFiles`, `EntryOp`, `Wanted` | `Sources/ConduitRuntime/RuntimeHost.swift`: `handleVPNStateChange` (no guard; gate turn, then `await reconcileEntryFiles`, then the orchestrator), `reconcileEntryFiles`; `splitDNSGateOrder` (`VPNObservationOrder.admit`); `Sources/PlatformMac/SplitDNSVPNGate.swift`: `entriesWanted`, `update`, `action`, `entryFileOperation` |
| `HStartBegin` | `RuntimeHostLifecycle.runStartEffect` -> `RuntimeHost.applyProxySurfaces`: `vpnConnected`, `gateReportSeen`, `entryPlace`, the `platformWork.run` block |
| `RecordOutcome` (owner `start`, `correction`), `StartedAtSurfaces` | `applyProxySurfaces` after its block: `recordSplitDNS(.start)`, `runtimeStarted = true`, the `gateMoved` correction through `reconcileEntryFiles` and its record |
| `HStartObservers` | `RuntimeHostLifecycle.runAdmittedStart` after `applyProxySurfaces`: `startDNSModule`, `orchestrator.startTunnels`, then `startObservers` |
| `ObserversRunning` | `RuntimeHost.networkPathObserving`: set in `startObservers` beside `vpnStatusMonitor.start()`, cleared in `tearDown` beside `stopVPNMonitor()` |
| `HStopBegin`, `RecordOutcome` (owner `stop`) | `RuntimeHostLifecycle.tearDown` (`stopVPNMonitor()` when every module goes down, `runtimeStarted = false`) and `tearDownProxy`'s `stopPlace`, `resolvers.clear` and `recordSplitDNS(.stop)`. `HStopBegin(_, FALSE)` is a Stop of the proxy alone, with DNS or tunnels staying up: the monitor and the gate's verdict stay |
| `GateForgetsAtStop`, `FenceAtStop`, `ghost.forgot` | `RuntimeHost.stopVPNMonitor`: `splitDNSGate = SplitDNSVPNGate()`, `splitDNSGateOrder.skip(through: vpnSequencer.issued)` (`VPNObservationOrder.skip`, `VPNObservationSequencer.issued`) |
| `platQ`, `done`, `PlatformRun`, `files`, `helperUp` | `Sources/PlatformMac/PlatformWork.swift` `run`; `SplitDNSVPNGate.perform` -> `DNSManager.applyEntryFiles` / `clearEntryFiles` through the helper; `done` is the tasks `platformWork.run` has finished for and that have not yet resumed on `RuntimeActor` |
| `repair`, `NextPlace`, `RecordOutcome`, `RecordKeeps`, `Retry` | `Sources/PlatformMac/SplitDNSEntryFileRepair.swift` `queue`, `record` (the `startedAt < generation` guard), `desiredOperation`; `RuntimeHost.recordSplitDNS`, `observeHelperForSplitDNS`, `retrySplitDNSEntryFiles` |
| `OrchHandle`, `OrchAdmits`, `orch` | `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift` `handleVPNStateChange` up to its first suspension: `vpnObservations.admit`, the switch over the change, `startStrandedSweeps`, `holdStrandedSweeps`, `resumeStrandedSweeps` |
| `Change`, `Recorded`, `ConfirmsAfterBlind`, `React` | `Sources/ProxyKernel/Network/VPNReactionHistory.swift` `record` (`.blinded`, `.transition`, `.confirmed(afterBlind:)`, nil) |
| `SystemWake`, `WakeSeesStore` | `ProxyOrchestrator.handleSystemWake` -> `recoverStaleReassertingAfterWake`, `VPNReactionHistory.recoverFlap` |
| `VPNConnect`, `CanConnect` | the VPN client: it reaches its gateway only while no entry file captures the gateway's name |

`ObserversRunning` is `networkPathObserving`: `startObservers` sets it in the turn that starts the monitor, and `tearDown` clears it in the turn that calls `stopVPNMonitor`, only when every module goes down, so it is `lc.started` and stays set through a Stop of the proxy alone. The `b3-failure-before-stop-dropped` mutant puts back `guard networkPathObserving else { return }` at the top of `handleVPNStateChange` (the 179b477f shape, `HostTakesReports`), which returns from the whole handler: the gate and the orchestrator both miss a report that lands after a whole-host Stop. Since #324 the gate refuses such a report anyway, so the guard no longer harms the entry files; it harms the orchestrator, which `handleVPNStateChange` tells of every report, a gate-refused one included. A store failure published just before the Stop, its delivery still on its way, leaves the orchestrator on the last definite verdict while the monitor last published `.unknown`, so the history never goes blind; `OrchestratorFollowsLastPublished` catches it in `safety-orchestrator`. The `blinded-keeps-sweeps` mutant removes `wasBlind ||` from `VPNReactionHistory.record`'s guard, the Swift change itself; the tunnel-replacement half of that guard is not modelled.

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
- A Stop of DNS or tunnels alone (the model's Stops take down everything, or the proxy alone), a Stop during a Start, lifecycle-lane supersession, the DNS and tunnel members (only the time their starts take, as `HStartObservers`), intercept resolver files and their refresh retry in `settleResolverSwitchBaseline`, residue, config reloads and the resolver switch, launch recovery, and files left by a crash.
- What `handleVPNStateChange` does after the orchestrator returns (`reconcileSystemDNSIfRunning`) and the orchestrator's work after its first suspension.
- The orchestrator's routing, probes and direct mode; only `VPNReactionHistory` and the sweeps are modelled, in their own check.
- `LiveSplitDNSDetection` and `PushedResolverMonitor` (decision 0044), which share the barrier but not this gate. The 0049 override that builds on them is its own spec, `VPNDNSOverride.tla` (skill `vpn-dns-override-model`). That includes `stopVPNMonitor`'s `splitDNSDetection.vpnObserverStopped()` and `applyPendingSplitDNSDetection()`, so `LiveSplitDNSDetection.swift` is not in `COVERED`.
- A wake-up that re-reads an unchanged store does not fire (`WakeFire` needs `~ghost.fresh`). That is sound because a reconcile on the same reading is idempotent, which the timer tests check.

## A real bug or a modeling error?

When a check fails, read the path with `/statechart`, then:

1. Map each step to the code through the coverage record. If a step does something the code cannot do (two `monitorQueue` blocks at once, a Stop inside the barrier from another thread, a gate update and its queueing in two turns), the model is wrong: fix the action and say why in the commit.
2. If every step is possible, replay it in a test over `FakeTunnelStore`, `FakeStoreObserverClock` and the `RuntimeHost` harness. A replay that shows the harm is a bug: file it with the path in the code's words. Do not weaken the property or the model to make it pass, and do not fix product code as part of a model change.
3. A path that is possible but harmless means the property is too strong for what the owner decided; ask the owner before changing it.

## When the code changes on purpose

Change the action that stands for the code, keep the property, and run `check.py --mutants`. Every mutant must still be caught; a mutant whose text no longer matches the spec makes `check.py` stop with the text it looked for, so update its edit to the new spec. A mutant that names a check (`check=` in `check.py`) runs at that check's bounds in each tier, so one named for a `--full` check runs only with `--full`. When a code change makes a mutant's bug harmless to one property, check it against every property its change can reach before you remove it: #324 made `b3` harmless to the gate and the entry files, but not to the orchestrator. Remove a mutant only when no property can catch it, say why in the skill and the commit, and do not keep one that cannot fail. Add a mutant for each new bug you fix in this chain: the Swift change that reintroduces it, the same change in the spec, and the property that catches it. Then update the coverage record and move the sync commit.
