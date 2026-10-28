The artifact flush is now cut to the Quit deadline, the same way the logger drain already was. I haven't compiled or run anything; you run all of it.

**What changed**
- **Clamp:** `DiagnosticFlushPhase` takes an optional absolute cap. With a cap, the phase ends at whichever comes first: now + 6 s or the cap. With no cap it keeps the ordinary 6 s.
- **Propagation:** `RuntimeHost.flushEvents` passes the same `loggerUntil` cap to its one artifact phase, after the logger drain.
- Nothing else changed: no extra phase, budget, mode, clock seam, public access or test hook, and no started write is cancelled. `pm-proxy` and the other `DiagnosticFlushPhase()` callers keep the 6 s phase.

**Files**
1. `Sources/ProxyKernel/Support/DiagnosticFlush.swift`: the new `init(budget:cappedAt:)` and its doc comment.
2. `Sources/ConduitRuntime/RuntimeHost.swift`: `DiagnosticFlushPhase()` → `DiagnosticFlushPhase(cappedAt: cap)` in `flushEvents`, plus one doc-comment clause.
3. `Tests/ConduitTests/DiagnosticDrainPhaseTests.swift`: new `testACapCutsThePhaseDeadlineAndNeverExtendsIt`.
   - A passed cap gives no wait.
   - A 1 s cap is the deadline exactly.
   - A 60 s cap, like no cap, gives the ordinary 2 s writer wait, bounded before and after.
   - It compares computed values only and never sleeps.
4. `Tests/ConduitTests/RuntimeHostControlOwnerTests.swift`:
   - **New `testAQuitPastItsDeadlineGivesTheArtifactFlushNoFreshWait`**, next to `testAQuitWhoseDeadlinePassedAdmitsNoFlush`.
     - It first checks that a plain `flushEvents()` still drains events.
     - It then runs the actual `shutdown(reservingFlushUntil: now − 1 s)`.
     - It reads the outcomes the Quit's own flush recorded: `observability.flush_timeout` with detail `auditFlushed=false eventsFlushed=false audit=skipped_budget events=skipped_budget`, `observability.snapshot_flush_unconfirmed` with `outcome=skipped_budget`, and the logger's `skippedBudget` fact. It also checks that the teardown still ran.
     - Nothing in it is timed.
   - **The two no-stream completion tests** go from `.seconds(3)` to `.seconds(10)`, as a literal naming 0039, because this suite's convention is explicit fixture values rather than app constants. Their doc comments are updated; every settled, teardown and persistence assertion is unchanged.
   - **The 2 s held-teardown test is unchanged.**
5. `Sources/pm-sim/RuntimeHostEffectsScenarios.swift`: the existing held-logger/passed-cap step gains one check, "a passed cap gives the artifact phase no fresh wait either", which requires audit, events and snapshot to all be `skippedBudget`. Its comment and note text are updated. Nothing outside the file pins that text.

The `ConfigurationStoreTests` annotations stay as they were.

**Filters**
- `xcrun swift test --filter 'DiagnosticDrainPhaseTests'`
- `xcrun swift test --filter 'RuntimeHostControlOwnerTests/(testAQuitPastItsDeadlineGivesTheArtifactFlushNoFreshWait|testAQuitWhoseDeadlinePassedAdmitsNoFlush|testTheClientQuitFlushesBothDeclaredSavesWhenItsSubscriptionIsRefused|testTheClientQuitFlushesItsDeclaredSaveWhenItsStreamEndsEarly|testTheClientQuitKeepsItsCallerToTheTotalDeadlineWhileAnUnobservedTeardownIsHeld|testAHeldLoggerDrainLeavesStatusReadsAndStopAdmissionAnswered)'`
- `swift run pm-sim runtime-host-effects`

The two 10 s tests each take about 9.8 s now, because the no-stream path waits until 200 ms before its deadline.

**Negative control A (cap propagation only), the old mismatch:**
```diff
--- a/Sources/ConduitRuntime/RuntimeHost.swift
+++ b/Sources/ConduitRuntime/RuntimeHost.swift
@@ func flushEvents
         var report = await DiagnosticFlush.run(
-            phase: DiagnosticFlushPhase(cappedAt: cap),
+            phase: DiagnosticFlushPhase(),
             audit: orchestrator.auditSink,
```
- **Should fail:** the new host test's `flush_timeout` and snapshot detail assertions, because the Quit's artifacts drain instead of skipping, and the new pm-sim check.
- **Should still pass:** `DiagnosticDrainPhaseTests`.

**Negative control B (the clamp itself):**
```diff
--- a/Sources/ProxyKernel/Support/DiagnosticFlush.swift
+++ b/Sources/ProxyKernel/Support/DiagnosticFlush.swift
@@ init(budget:cappedAt:)
         let envelope = ContinuousClock.now.advanced(by: budget)
-        deadline = cap.map { min($0, envelope) } ?? envelope
+        deadline = envelope
```
- **Should fail:** the new unit test (a passed cap is not nil; a 1 s cap is not the deadline), the host test and the pm-sim check.

**Risks to watch in the full run**
- Any existing test that reads `events.ndjson` after a Quit that overran its own deadline will now find the late events unconfirmed in the file. The in-memory log is unaffected. I found no such test, but I didn't audit all of them.
- A single stall of more than 1 s between two lines of the new unit test would break the exact-equality assertion. That's unlikely.
- I make no claim about which I/O step was slow in the d038 CI run. An unsettled read can also come from a final lookup that failed or was busy.

These files are frozen.