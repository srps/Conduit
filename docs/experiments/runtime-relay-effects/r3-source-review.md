## Relay r3 review (`runtime-actor-relay-review-r3`, patch `41a53043…`)

**Verdict: Source ready.** Execution acceptance is a separate question and still depends on the full r3 run now in progress. I've drawn no conclusion from any run. I made no edits, built nothing, made no network calls and did not read the moving worktree.

### The delta is exactly what was described
- **Production and other tests unchanged:** every file except `AppStateActivationParityTests.swift` has the same git blob hashes as in r1 and r2. That covers `RuntimeHost`, `ProxyOrchestrator`, `PlatformWork`, PlatformMac `AGENTS`, `RelayReassertScenarios`, `BoundedRecordWriterTests`, `HeldCall`, `RelayLifecycleTests` and `RuntimeHostControlOwnerTests`. Production is still byte-identical to r1, and there is no live hook or API change.
- **The parity test changed in two places only** (post-image `be5f0da`, against r2's `d56e40e`):
  1. One setup barrier at `:413`: `await harness.settle("the drop's removal was refused") { !hostEvents(..."platform.split_dns_failed").isEmpty }`.
  2. The `quitJoiningHostDiagnostics` doc now states the scope correctly: a completed Quit joins a *bounded diagnostic flush attempt*; the queue may not have emptied, and records can stay queued or fail to write.
- **All six r2 hunks are unchanged:** each pre-Quit assertion, each post-Quit event check, the removed sleeps and polls, and the helper body. My r2 parity analysis stands as written.

### The barrier is causal, not a timing workaround
- **Pending is set before the event exists.** `SplitDNSEntryFileRepair.record` sets `pending` (`:179`) before it reports `platform.split_dns_failed` (`:180-187`), in one synchronous call on the owner. The events writer appends after the in-memory event. So a failure visible in `events.ndjson` means the repair is already pending, and every later preflight's `observeHelperForSplitDNS` call finds something to retry.
- **The count of six then follows by arithmetic:**
  - The barrier makes the first iteration's starting count at least 1.
  - Each iteration's settle requires the count to rise past its own starting value.
  - So five iterations give at least 6.
  - The file only grows, so the final disk-read assertion at `:419` holds once the last settle has passed.
- **A retry already in flight still counts.** Suppose a preflight is refused because a retry dispatched by the helper check is already out. That retry's refused removal still raises the count. Because the removal keeps failing, the repair never goes back to nil.
- **The fix matches the failing run.** That run's log showed `attempt=1 source=vpn_transition` satisfying the first iteration, then attempts 2 to 5: one short, exactly as the diagnosis predicts.
- **It follows an existing pattern.** The barrier mirrors the sibling preconditions at `:384` ("the removal was refused") and `:433` ("the new removal was refused"). It is a precondition on the drop's own failure, not a poll of the asserted value.
- **Nothing was weakened.** The `≥ 6` assertion and its message, the loop, the existing 1.5 s sleep at `:420`, and every later step (reconnect, refusing helper, new failure, fresh check, `trigger=helper_check`) are unchanged.

### Non-blocking notes
- The helper doc now says "the file assertions read after this detect any missing record" twice. The original "logical quiescence…" paragraph was kept after the new sentences. You noted this can be trimmed later.
- The `hostEvents` doc (`:715-716`) says a read "meant to cover everything the host did" follows the Quit. Given the bounded flush attempt, "everything" slightly overstates it, in the same way as the helper doc.

### Remaining limitations
- **Negative-artifact vacuity is still open.** If a drain times out, the post-Quit negative event checks can pass on a short file; a logically completed Quit does not close that gap. The credential test's snapshot read (`?? ""`), the `config.workflow` witness that the open's own startup event already satisfies, and the read inside the settings-flood loop are left for the diagnostics plan, as documented.
- **Relay r1 limitations are unchanged.** Relay commands can wait behind queued PlatformWork, a stuck helper holds the DNS slot for up to its transaction budget, and there is no blind relay stop at quit.
- **Out of scope here:** the control cluster is still MainActor; the logger, the whole-actor retag and the native work are not done.
- **Executed acceptance is pending** the full r3 run. The focused 6KO0zS run (327 tests plus both simulator scenarios) passed before the comment-only edit, so the final frozen bytes are covered only by the full run.