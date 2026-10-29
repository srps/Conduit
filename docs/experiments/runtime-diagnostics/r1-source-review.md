**Source verdict: accept, with one P2 fix needed first.** I read the AGENTS files, both briefs, the provenance and author manifests, the full `activation.patch` and the snapshot code it touches. I made no edits and ran no builds, Bash, Git or network calls, so I haven't checked the SHAs either.

## Findings

**P2: a write admitted just before close can be lost and counted nowhere.** This breaks the custody rule for physical records.
- **Where:** `Sources/ProxyKernel/Support/RotatingLogFile.swift:182-197` (`write`) against `:217-224` (`close`).
- **The gap:** `write` admits the record and sets `draining` while holding the lock. It then releases the lock and only afterwards calls `queue.async { drainPending() }` (`:197`).
- **How it fails:**
  1. A log line from an off-main (NIO) thread is admitted, and that thread is preempted before `:197`.
  2. On main, the Settings toggle reaches `AppLogStore.swift:150` and calls `close()`. It sets `closed`, then `queue.sync` runs first: it sets `terminal` and closes the descriptor.
  3. `AppLogStore.swift:158-163` then folds `written`, `dropped` and `failed` and swaps writers. The admitted record is still pending, and the fold doesn't count pending records.
  4. The late `drainPending` hits `append`'s `!terminal` guard (`:266`). That guard returns false without calling `fail()`, so it adds 1 to `failedRecords` on a writer nothing references any more.
- **Result:** the record isn't written, isn't in `AppLogStore.statistics`, never reaches `observability.writer_loss`, and has no event. That contradicts both the "writes admitted before the latch are still written" doc on `close()` (`RotatingLogFile.swift:215-216`) and the claim at `AppLogStore.swift:101` that the queue is empty once close returns. The store's own lock doesn't help, because `close()` never takes it.
- **Fix:** call `queue.async` inside the admission lock. It only enqueues and runs no callback, so every admitted record's drain block is guaranteed to be queued ahead of close's `queue.sync`. Both doc invariants then hold structurally, with no new mechanism. `BoundedRecordWriter.append` has the same shape but no `close`, which is why only this writer is exposed.
- **Test gap:** the close test (`testACloseWritesWhatItAdmittedThenRefusesAndNeverReopens`) only covers a write that is already inside storage, so it can't catch this.

## Checked and accepted
- **App-log guard:** `AppLogGuardEffect` is internal. Production and dev both use `.identity`, and `AppState.swift:129` always wraps the authoritative `diagnosticDestinationGuard(.appLog, …)`. `HoldingAppLogGuard` hands both protocol methods to that guard, and nothing in the tree downcasts the guard, so there's no authority bypass. That delegation is enforced by review, not by the type, which is the shape the brief asked for.
- **Quit tail:** the deadline is taken once in `beginQuit`. `drainQuitLog` runs after the quit's single return inside the same task, so every return path is covered. If the deadline has passed it records `skippedBudget` with no wait. The event comes first, then one derived line, and nothing waits after.
- **Host drain:** it waits at most `min(now + writerWait, quit deadline)` and never past it. The blocking `logger.flush` is gone from the owner. The logger result stays out of `allConfirmed`.
- **Timeout counting:** the store counts each timeout once and ignores the writers' own counts. `testATimeoutAcrossAToggleIsCountedOnceAndNoCounterGoesBack` would catch both losing the count and double-counting it.
- **`LogSink.flush` default `true` left unchanged:** this is acceptable as far as actual use goes. Nothing reads the result from a sink that would falsely claim success: the host no longer calls it, and the daemon/pm-* tools only call `ConsoleLogSink` and ignore the result. `AppLogStore` now implements `flush` honestly. `drain` defaults to `unavailable`, and every in-tree wrapper forwards it.
- **Typed event and wire:** the domain and wire enums are separate closed sets. The projection is exhaustive and sizing has the no-text case. `drained` and unknown sources are refused, and a newer type stays informational. The `events.md` row and the catalogue script are both updated.
- **UI history:** there's one bounded hand-off and at most one scheduled drain. Trimming is amortised, not O(n) per record. Main-thread logging drains pending entries before appending its own, and evictions are counted apart from record loss.
- **Snapshot privacy test:** the read is now required and comes after the Quit, the token-absence assertion is unchanged, and the config assertion stays before the Quit.
- **Ready file:** moving the physical write to PlatformWork creates no real acceptance gap. The status is captured before the suspension, and the `await` at `RuntimeHost.swift:644` guarantees the ready file lands before the snapshot is submitted. The app never calls `markReady`, so no Quit path is affected. The one new effect is a wider window between the `daemon.ready` event (`:643`) and the file landing, now subject to PlatformWork queue delay. No in-tree code reads the file on that event.

## Proof gaps (P3, no change required)
- **Ready-file test** (`DaemonRuntimeHostTests` `testTheReadyFileHoldsTheReadinessStatusAndLandsBeforeTheSnapshot`): comparing modification times with `<=` wouldn't reliably catch a ready-file write that wasn't awaited, and `processID` doesn't show the status was captured on the owner. The ordering rests on the code structure, not this test.
- **Control-owner held-drain test:** the 200 ms sleep stands in for "the drain is registered". If the artifact flush took longer than that, the old blocking code would also pass.
- **Single timer slot:** a drained wait's cancelled timer body can make the very next wait answer `busy` (`RecordDrainWaiter.swift:26-28`). Host drain followed by the app tail, or `markReady` followed by the daemon's next flush, could then record `log_flush_unconfirmed busy` with no real stall. The brief allows honest `busy`, but nothing tests this case.
- **pm-sim coverage:** the host witness uses a sim-local logger over the kernel writer, not `AppLogStore` or `ConsoleLogSink`. The app tail only has XCTest coverage, because pm-sim can't link the app target.
- **Outside this lane:** the artifact phase still starts its own 6 s budget rather than being cut to the Quit deadline. That predates this change and falls under decision 0039.

## Not covered by this review
Full41/full workflow (the parent's run isn't accepted yet), the focused run the author reports as green, shipping resource and latency measurements, native and real-helper acceptance, and the parent-owned docs (`design-runtime-host-contract.md` lacks `.logFlushUnconfirmed`).