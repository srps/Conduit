**Short answer:** the artifact phase's 6 s budget doesn't break the accepted 10 s total. The app never waits for it past the Quit deadline. If it runs past the deadline, that is host work that can outlive the caller and the process, and the code and decisions already document that. Separately, I was wrong to call the default one-slot retired-timer `busy` untested: `RecordDrainWaiterTests` already covers it, so no new test is needed.

## Timeline of a Quit (immutable snapshot)

1. **T0, the deadline is set once.** `AppState.beginQuit` sets D = now + `quitTotal` (10 s) at `AppState.swift:1307`.
2. **The client sends the Quit.** `RuntimeClientQuit.quit` gets `total = D − now` (`AppState.swift:1381`) and sends `.quit(total:)` (`RuntimeClientQuit.swift:80-84`).
3. **The host takes its own deadline.** When it admits the Quit it sets Dh = now + total, which is D plus in-process latency (`RuntimeHostControlOwner.swift:221`). `admitQuit` then starts two things:
   - a `RuntimeQuitFlush` timer to Dh (`RuntimeQuitFlush.swift:49-56`);
   - the quit work task (`RuntimeHostLifecycle.swift:1005-1023`).
4. **The host's quit work runs in order:**
   - teardown;
   - `waitUntilIdle`;
   - `flush?.closed()`, which returns at Dh at the latest (`RuntimeQuitFlush.swift:78-82, 103-106`);
   - `workflow.waitUntilIdle`;
   - `flushEvents`. Its artifact phase is a fresh `DiagnosticFlushPhase()`: 2 s per writer, 6 s envelope (`DiagnosticFlush.swift:15-26`). It is not cut to Dh. The new logger drain is cut to Dh.
   - `quitDidEnd`.
5. **Settlement is decoupled from the work.**
   - The operation is reported settled at whichever comes first: the work ending, or Dh. At Dh, `expire()` resumes `settled()` with false, which becomes `.failed(.cleanupIncomplete)`.
   - The operation only reports `quiesced` after the work has actually ended (`RuntimeHostControlOwner.swift:283-292`).
6. **The caller's wait is bounded by D.** `quitSettlement` returns on the settled frame or by D: a stream read past D aborts and the step stays unsettled, and with no stream `keepCaller` holds only until D (`RuntimeClientQuit.swift:233-246, 262-269`).
7. **The app tail is bounded by the same D.** `drainQuitLog` waits under D, and records `skippedBudget` without waiting if D has passed (`AppState.swift:1334`). `AppDelegate` then replies terminate (`AppDelegate.swift:72-75`), and process exit ends any host work still running, because the host is in-process.

## How this maps to 0015 and 0039
- **The 10 s caller wait holds.** Steps 6 and 7 never wait past D. The artifact phase only counts toward the app's wait when the quit work finishes before Dh, and then it finished within the budget by definition.
- **Host work after logical expiry is permitted and documented:**
  - 0039 (lines 30-34): "The host retains physical authority while its started work runs; process exit and next-launch recovery keep the selected semantics."
  - 0015 (lines 50-51): "Started writes may complete; cancellation is not a physical rollback."
  - `RuntimeQuitFlush.swift:12-13`: "A quit past its deadline is reported as such while its work still runs and still owns the root, until it ends."
- **No app-owned wait gets a fresh budget.** The only app-owned step after the client returns is `drainQuitLog`, which uses D.
- **One limit, stated without proposing a change:** if teardown or the store join runs past Dh, the host's `flushEvents` can begin after logical expiry. That includes a snapshot submission and artifact waits under the fresh phase. It is host-owned diagnostic custody that nobody waits for, not a config write, durable disable, retry or replacement writer. It fits the documented semantics, but process exit can cut it short, so nothing claims it was confirmed.

**Correction to my saved review:** my "outside this lane" note about the 6 s artifact phase should not be read as a 0039 violation. It is documented post-expiry host custody.

## One-slot retired-timer `busy`: already covered
- `RecordDrainWaiterTests.swift:153-184` (`testDrainedCallerReturnsWhileAHeldTimerBodyKeepsCapacityBusyUntilItEnds`) uses the default one-slot waiter. It holds the cancelled timer body after a drained return, asserts the next non-empty wait is `.busy`, then releases the body and asserts capacity comes back.
- The table row `(1, [.drainedHeld], .busy, …)` in `testProbeOutcomeAfterEachHistory` (`RecordDrainWaiterTests.swift:256`) covers the same case.
- `RotatingLogFile` builds the same default waiter, `RecordDrainWaiter(group:)` at `RotatingLogFile.swift:163`, and `ConsoleLogSink` forwards to the writer's existing waiter. So the store and Quit behaviour follows from that tested primitive. Only the end-to-end appearance (a `log_flush_unconfirmed busy` with no real stall) has no dedicated test, and it doesn't need a duplicate.