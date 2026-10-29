# R3 residual: can a diagnostic writer write into the root after its lease closes?

**Yes, but only in tests and pm-sim today, not in production.** The real exposure is the R3 AppStateHarness proof: it treats "the lease is free" as "the host's writes are done", and a late artifact job can still land after that. The permitted one-wrapper change is the smallest complete fix, and an existing fixture gives a regression test that fails on R3.

## What holds the session
- **The host:** `RuntimeHost.stateSession` (`RuntimeHost.swift:35, 398`). That is the only holder inside the runtime cluster.
- **Not the guards:** the events, snapshot, audit and recovery guards are built from `environment` plus the `writerLeaseFile` URL only (`RuntimeHost.swift:428-439, 468-474, 616-617, 1613-1614`). They become a plain value struct holding protected paths (`SystemRecordFileDestinationGuard.swift:28, 258-261`; `ProxyControlBridgeProtectedDiagnosticResources.swift:48-55`). The app-log and app audit guards are the same (`AppState.swift:129-130, 762`).
- **Not the writers:**
  - they keep themselves alive through their own queue, for example `queue.async { [self] in drainLoop() }`, which loops until nothing is pending (`SnapshotArtifactWriter.swift:222, 254-272`);
  - they write with a new temporary file and `rename` (`:309-337`), which needs no lease;
  - they hold the event log weakly (`SnapshotArtifactWriter.swift:168`, `RotatingLogFile.swift:110`, `RecordFileDestinationGuard.swift:102`).
- **Where it is pinned elsewhere:** production pins the session for the whole process. The app pins it in `PreparedAppLaunch.pinned` (`PreparedAppLaunch.swift:26, 81`), set once and never cleared. The daemon pins it in `ConduitDaemon.stateSession` (`ConduitDaemon.swift:31-32, 81`), documented "never cleared".
- **How a lease can close in-process:**
  - `releaseForTesting` (`StateRootSession.swift:55`), which is a fixture force-close and excluded here;
  - the lease's `deinit` on the last drop (`StateWriterLease.swift:137-143`), which only happens on the natural-drop paths: the R3 AppStateHarness and pm-sim's `releaseRoot`.

## A feasible late write after a new acquisition (no process exit, no force-close)
In AppStateHarness, the "new acquisition" is the harness's own production-bootstrap probe:
1. Teardown's final mutations call `emitSnapshotCoalesced`, which arms a 100 ms one-shot timer (`ProxyOrchestrator.swift:377-389`).
2. The Quit's `flushEvents` confirms the artifacts within that 100 ms, then `quitDidEnd` runs and `quitEnded` becomes true (`RuntimeHostLifecycle.swift:1018-1021`).
3. The timer fires. `flushPendingSnapshot` checks only its generation (`:399-405`), so it calls `onSnapshotChange`. That reaches `writeSnapshotFile` → `snapshotWriter.submit` (`RuntimeHost.swift:522-527, 1573-1575`). Nothing on this path is gated by `quitEnded`, and the host is still alive, held by the app until `dropOwnReferences`.
4. The harness drops its references. The host deallocates, and the lease's `deinit` closes the flock.
5. `rootReacquires` succeeds (`AppStateHarnessTests.swift:219-249`).
6. The writer's queued `drainLoop` then creates a temporary file and renames `snapshot.json` into the root, during or after `removeScratch`. That is the B1 failure class.

Late `eventLog` appends after the flush reach the events writer the same way. The same failure occurs if the artifact flush ended unconfirmed with a job still in flight. pm-sim pins the host on `!allConfirmed` (`RuntimeHostEffectsScenarios.swift:329-330` and each exercise). That covers unconfirmed flushes, but not the post-flush submission in steps 1-3.

**Production:** not feasible. Another process can acquire the root only after the pinned process exits, and 0017 `:31-32` explicitly accepts process exit as the release.

## Does this violate 0017?
- **Production does not.** The entry-point pins keep authority until process exit, which 0017 allows.
- **Scope:** diagnostic writers are not among the writers 0017 requires to share authority (`:35-36` names configuration, platform-preference and platform-journal). Their adoption only protects the lock file's path (`:102-109`). But the general rule (`:31`) covers "queued and started writes", and these are queued writes into the root.
- **The R3 harness does violate 0017.** It deletes the root on a lease proof that doesn't imply the writers have finished, against `:69`, "Join fixtures before deleting their state directories".
- **The host's own custody claim is incomplete.** "The host holds a reference, so the lease stays open while the host runs" is true of the host, not of its writers. Correctness currently depends on the entry-point pins.

**Verdict:** this is a correctness gap in the R3 custody claim. It is not acceptable to file it as a limit by default.

## Smallest boundary choice
**Recommended:** the permitted wrapper.
- One narrow PlatformMac `RecordFileDestinationGuarding` wrapper that retains the `StateRootSession` and delegates both `admit` calls to the existing guard.
- Apply it at the six lease-root compositions: `RuntimeHost.swift:428, 438, 616, 1613` and `AppState.swift:130, 762`.
- **Effect:** each writer holds its guard, so the lease now closes only when the host and every diagnostic writer's queued drain have released it. The lease proof then really implies the writers are done.
- It adds no queue, registry, raw lease accessor or public API. pm-proxy and pm-sim's `diagnosticDestinationGuard` calls take no lease and stay as they are.
- **Cost:** a writer stuck on hung I/O keeps the lease. That is what 0017 `:31-32` requires; in tests it fails loudly through `leaseCloseBound`.

**Insufficient alternative:** gating `writeSnapshotFile` on `quitEnded`. That covers only snapshot step 3, not late events, audit records or unconfirmed jobs.

**Regression test, existing fixtures only:**
- Reuse the app-log hold: `appLogHold` / `HoldingAppLogGuard` (`AppStateHarnessTests.swift:47-50, 256`) and `holdTheAppLogOpen`.
- Hold an app-log write, quit, then call `dropOwnReferences`. Assert `probeRoot()` returns `.failure(.busy)` while the write is held. Release it, then assert `rootReacquires`.
- **On R3:** the probe succeeds while the root write is still pending, so the test fails.
- **With the wrapper:** the held writer retains the session through `HoldingAppLogGuard` → authoritative guard → wrapper, so the probe reads busy.
- This tests the general mechanism (a pending diagnostic write keeps the lease), not the exact snapshot-timer sequence.

No Source was edited; full R3 is still the parent's gate.