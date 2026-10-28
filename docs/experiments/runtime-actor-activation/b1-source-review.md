# RuntimeActor Stage B (B1): remaining-area Source review

**I don't accept Source B1.** The parent's signal repro is a real Stage B defect that the earlier pm-proxy review missed, and it decides the verdict. My review adds one P2 placement gap and widens the P3 last-value scope from two sites to three. The XCTest teardown failure is also explained: Stage B's concurrency exposed three existing faults.

Everything else in my scope holds; see the coverage ledger at the end. Throughout, "the actor" is the shared RuntimeActor that now runs the control cluster (the owner). I read only the snapshot, the patch, the provenance/manifest files, the prior reviews and the parent's repro files, and ran nothing.

## P1: pm-proxy signal handlers abort (confirmed by the repro)

**Evidence:** `runtime-actor-stageb-signal-repro`: `ready: true`, `exit_after_hup: -6`, `rejection_recorded: false`. stderr ends with `Incorrect actor executor assumption; expected 'ProxyKernel.RuntimeActor' executor.`

**Mechanism:**
- The whole pm-proxy body now runs inside `Task { @RuntimeActor in … }` (`PMProxy.swift:62`).
- Dispatch's `setEventHandler` parameter is not `@Sendable`. In Swift 6 a closure literal passed there takes the isolation of where it is written, so the handlers at `:188` and `:201` become `@RuntimeActor` closures with an executor check at entry.
- The sources fire on `.main` (`:187`, `:200`), so the check fails and the process aborts.
- Before Stage B the enclosing task was `@MainActor` and the queue was `.main`, so the same check passed. The build stays green because the compiler infers this isolation rather than flagging it.

**Exact scope.** Two sites, and graceful stop is broken as well as reload:
- `PMProxy.swift:188`: the SIGINT/SIGTERM handler aborts the same way.
- `PMProxy.swift:201`: the SIGHUP handler (the repro).

**Fix:** write both closures as `{ @Sendable in … }`. That is the existing idiom on the orchestrator timers (`ProxyOrchestrator.swift:385, 3023, 3355`) and on the pm-proxy status timer (`PMProxy.swift:497`).
- The SIGHUP body mutates the captured `var configGeneration`, which a `@Sendable` closure can't do.
- So define one `@RuntimeActor @Sendable` reload closure, pass it as `reloadHandler` (`:168-177`), and have the SIGHUP handler call it from `Task { @RuntimeActor in try? await reload() }`.
- That also deletes the duplicated reload body at `:203-216`.

**Audit of other Dispatch callbacks written inside isolated code** (non-`@Sendable` `setEventHandler`/`setCancelHandler`, `pathUpdateHandler`, notification and termination blocks): nothing else is affected.
- `ConduitDaemon.swift:143` is written in `@MainActor main` and fires on `.main`, so it is safe today. It would break the same way if `main` were ever moved to RuntimeActor; adding `@Sendable` there is optional hardening.
- `ControlSocketServer.swift:53/56` runs in a nonisolated class (`:8`), and so do `HealthChecker.swift:114`, `TunnelForwarder.swift:144`, `NetworkMonitor`, `WorkspaceSystemWakeObserver`, `NetworkLocationMonitor` and `CommandRunner`.
- pm-sim's only timer is already `@Sendable` (`Main.swift:176`), and the tests contain no `setEventHandler`.

**Regression witnesses already exist; no new test is needed:**
- `scripts/test-security-boundaries.py:155-161`: SIGHUP with an invalid config must be rejected while the proxy keeps serving.
- `scripts/test-status-stream.py:53-72`: SIGHUP and then SIGTERM must exit 0. Expect this one to be red on B1 as well.

## P2: the tunnel resolver blocks a cooperative-pool thread

This is the effect the prior review said had no witness at all. It also violates 0031 `:58` ("blocking effects remain on PlatformWork") and `:260`.

**Concrete job order:**
1. An owner job (a tunnels Start, Stop or reconcile) awaits `tunnelForwarder.start`, `stop` or `reconcile` (`ProxyOrchestrator.swift:1855-1857, 1900, 1998`).
2. `TunnelForwarder` is a nonisolated class, and the package uses default Swift 6 semantics (`Package.swift`: no `NonisolatedNonsendingByDefault`). Those async methods therefore run on the cooperative pool.
3. There, `resolver.cleanupStale/applyAll` (`TunnelForwarder.swift:438-439`) and `removeAll` (`:453`) call `privilegeClient.execute` synchronously (`TunnelResolverManager.swift:27-38`).
4. That call is a helper transaction with a 40 s budget (`HelperPrivilegeClient.swift:223-249`). Its AppleScript fallback for `applyDNS` is an admin password prompt bounded at 600 s, one per hostname (`HelperPrivilegeClient.swift:70, 101-108`).

**Impact:**
- On MainActor this blocked a pool thread while the owner stayed on main. Now it takes a thread from the owner's own executor.
- On a normal pool that is one lost thread, because the tunnel lifecycle serializes these calls.
- On a one-thread pool (the strict gate) the owner gets no thread at all, so status reads and Stop admission stall until the helper returns.
- Stage B already applied the same rule elsewhere: the relay was moved onto PlatformWork (`RuntimeHost.swift:470-482`) and the stranded-socket scan off the pool (`ProxyOrchestrator.swift:2503`). The resolver is still wired directly to the privilege client (`RuntimeHost.swift:457-461, 487`).

**Fix, mirroring the relay:**
- Make the `TunnelResolverApplying` requirements async (`TunnelResolverApplying.swift:16-30`).
- `TunnelForwarder` then awaits them.
- `RuntimeHost` wraps the existing `TunnelResolverManager` so each call runs on its existing `platformWork`. A synchronous manager still satisfies async requirements, so the direct manager tests in `TunnelDNSResponderTests` and `TunnelForwarderTests` don't change.
- Update the stale comment at `HelperPrivilegeClient.swift:225-229`.
- **Design choice:** PlatformWork rather than a global-queue continuation. It orders resolver writes with the split-DNS `/etc/resolver` writes, at the queueing cost the relay already accepts.

**Regression row:**
- Add a fourth row to `heldEffects` (`RuntimeActorPlacementTests.swift:138`): one proxied `TunnelDefinition`, operation `.applyDNS`, trigger `.start(.tunnels)`, stop `.tunnels`.
- `makeInteractiveHarness` needs a `tunnels:` passthrough; `makeHarness` already accepts it at `RuntimeHostInteractiveTests.swift:225`.
- Line 184 also needs a `.tunnels` module revision.
- On B1 the row should fail at `:191` and `:193` (not on the platform-work queue; on the pool). That failure is the test-first evidence.

## P3: last-value hops (three sites, not two)

| Hop | Reset it can overwrite | Correction |
|---|---|---|
| Session count `:1341-1347` | `:1781, 1798, 1813, 1871, 2052` | Read `sessionTracker.totalActiveSessions` inside the hop, and skip unless the tunnel lifecycle admits running |
| DNS metrics `:1141-1148` | `:1728-1730, 1744-1746` | Skip unless the DNS lifecycle admits running |
| **Auth outcome `:620-640`** (new) | `:1589-1591`; `:781` on an auth config change | Keep the event and log line, but skip the snapshot write unless the proxy lifecycle admits running |

The auth hop is unguarded. The documented Stop reset (`:1580-1588`) exists to stop a previous cycle's outcome from carrying over, and a lower-priority hop that runs after Stop undoes it.

**Regression shape (no FIFO assumption):** for each site, run the Stop to completion, then invoke the production callback (`sessionTracker.onChange`, the metrics callback, `reportAuthOutcome`). Assert the field stays reset for a bound that a positive control in the same test proves is long enough for a hop to land, using the emission-count pattern from `KerberosFallbackEventTests`. A guard-removal control should make the negative assertion fail.

## The XCTest failure (AppStateHarness teardown)

**Causal chain:**
1. `ConfigSaveGateTests.swift:108-119` leaves an over-limit `browserTestURL` draft that was refused and is still unsaved.
2. The harness's teardown Quit declares a preferences final save for it (`AppState.swift:1489-1500`). Its producer throws in `makePreferencesRequest` (`PrivateConfigurationBridge.swift:87-88`). The declared flush is never admitted, so the host holds its window open to the 10 s deadline (`RuntimeClientQuit.swift:56-57`).
3. The Quit settles `cleanupIncomplete` at the deadline while its work continues; the host keeps the root until it quiesces (`RuntimeHostControlOwner.swift:283-292`).
4. Past the deadline, `flushEvents` confirms the events flush first and only then calls `drainLogger`, which records `lifecycle.log_flush_unconfirmed` (`RuntimeHost.swift:993-1007, 1017-1020`). That record goes to the events writer after its flush was confirmed: this is the late `events.ndjson` child.
5. Meanwhile teardown force-closes the lease the host still holds and deletes the root (`AppStateHarnessTests.swift:182-183`).

On MainActor, the host's remaining Quit job could not run during that synchronous teardown. On RuntimeActor it runs concurrently. Stage B exposed this; it did not cause it.

**Corrections (no production test hook, no policy loosened):**
- **a. Harness, required.** Don't force-release a lease the host still holds; `releaseForTesting` is the custody violation. Instead:
  - drop `appState` and the harness's own session reference;
  - prove the lease closed by re-acquiring the root, bounded, which is pm-sim's existing `leaseReacquires` pattern;
  - only then remove the scratch directory;
  - if re-acquisition never succeeds, fail and keep the directory.

  The host holds the session until its Quit tasks end, so re-acquisition is the causal signal. `AppState.control` is private (`AppState.swift:85`), so the stream end isn't reachable without widening it.
- **b. Host ordering, required for causality.** In `flushEvents`, drain the logger first and then run `DiagnosticFlush`. The Quit's confirmed flush then covers its own last event, so "Quit ended" also means nothing is pending in the root. `AppStateHarnessTests.swift:1032-1034` currently has to poll for that late event even after a completed Quit; after the fix it can assert immediately, which becomes the regression check.
- **c. App, recommended (existing user-visible behaviour).** The preferences branch of `finalSaves` should apply the same ceiling check as the configuration branch (`AppState.swift:1456-1475`) and follow the rule at `:1437-1438`. It would not declare the save and would record `config.edit_discarded trigger=quit reason=resource_limit field=browserTestURL`. Today any Quit with such a draft takes the full 10 s. Regression: this test quits explicitly and asserts `.settled(.completed)`, `preferences == .notDeclared`, and the discard event.

## The two rows the prior review requested
- **Tunnel resolver:** it needs the P2 Source fix first; as a test alone it fails.
- **Helper-held Quit with a parked main:** not needed as a new row.
  - The lease is pinned for the process (`PreparedAppLaunch.swift:81`, `ConduitDaemon.swift:32`), and only tests release it (`StateRootSession.swift:55`).
  - The journal write and the no-admin-prompt property don't depend on which executor the owner uses.
  - `RuntimeHostControlOwnerTests.swift:1510` already holds a teardown through the client Quit on RuntimeActor.
  - If the parent wants it anyway, wrap that test's body in `MainThreadPark` and add an `isParked` assertion.

## Ordering challenge
- **Language vs implementation:** in-order delivery for `Task { @RuntimeActor in }` depends on two runtime behaviours, not on the language: Swift 6's `Task.init` enqueuing directly onto the actor, and the default actor keeping FIFO order within a priority. MainActor relied on the first of those as well.
- **Open/close callbacks:** these run as plain event-loop work. There is no NIO task-executor use, and no `Task` anywhere in `HTTPProxyHandler` or `SOCKS5Server`. A close on a peer loop is still causally after its open, at the same priority. I found no new invariant failure there.
- **`ObserverDeliveries.drain()`:** it counts in-flight deliveries (`ObserverDeliveries.swift:84-105`), so it doesn't depend on order.
- **Limit for #250, not a B1 defect:**
  - CONNECT auth handshakes run as pool tasks that call GSS synchronously behind one process-wide lock (`CONNECTHandler.swift:351, 422`; `GSSInitiatorGate.swift:50`; `KerberosAuth.swift:141`).
  - Up to 512 can be admitted (`CONNECTHandler.swift:32`).
  - With the KDC unreachable they can occupy the whole pool for one KDC timeout.
  - The framed transport already needed the pool before Stage B. Admitted teardowns, timers and deliveries now need it too.

## Coverage ledger
- **Service core:** has no `await` at all, so each method is one owner turn.
- **Transport:**
  - its exchange path is nonisolated and reaches the owner only through `scheduling.hop`;
  - `incarnation` reads are immutable `let`s;
  - the private-update effect re-checks `stands()` after the store await (`RuntimePrivateEditor.swift:747, 751`).
- **Gate:** a locked phase machine that re-checks the deadline at claim time (`RuntimeTransportGate.swift:444`).
- **Workflow, store, lifecycle, stopped effects:**
  - retags and comments only;
  - the Quit keeps the host alive through `Task { [self] }` (`RuntimeHostLifecycle.swift:1005`).
- **Daemon SIGTERM:**
  - `exit(0)` now runs inside the owner job;
  - concurrent signals are serialized, and the first `exit` holds the actor.
- **pm-sim:**
  - the parked-main park is bounded by the 120 s watchdog;
  - the network-location burst in one owner turn is sound.
- **Tests:**
  - no XCTestCase class is tagged `@RuntimeActor`, and no synchronous `@RuntimeActor` test method exists;
  - `releaseAll`, the Kerberos emission witness, and the placement and fairness rows are meaningful.
  - **Limits:**
    - the capture-row assertion (`RuntimeActorFairnessTests.swift:262`) follows from the owner being serial, so its real content is "answered, admitted, page whole";
    - the backlog row (`:157`) assumes the test task resumes before about 6,000 yield jobs drain;
    - the held private transfer is held before the frame is sent, so it witnesses lane separation, not owner fairness.
- **Not reviewed:**
  - the two profile experiment files (as instructed);
  - the moving worktree;
  - runtime thread-priority (QoS) measurements.

Full41, TSan, native, Release and the probes remain the parent's gates.