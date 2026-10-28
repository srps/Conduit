## Relay r2 review (`runtime-actor-relay-review-r2`, patch `f5867a2d…`)

**Verdict: Source ready. I found no blocker.** The static acceptance of r1 carries over unchanged, and the only change is a sound test-side correction. I made no edits, built nothing, made no network calls and did not read the moving worktree. Execution evidence is the parent's separate call.

### Only one file changed, and it is a test
In both patches, every file carried over from r1 has the same git blob hashes on both sides of its `index` line:
- `RuntimeHost` `2a316bd..951b70f`
- `ProxyOrchestrator` `9d7c56d..b12d5c8`
- `PlatformWork`, PlatformMac `AGENTS`, `RelayReassertScenarios`
- `BoundedRecordWriterTests`, `HeldCall`, `RelayLifecycleTests`, `RuntimeHostControlOwnerTests`

Blob hashes are content-addressed, so those files' contents match r1 exactly. The only new hunk is `AppStateActivationParityTests.swift` (`5ad58d2..d56e40e`). The parent's own byte comparison still stands as the formal check.

### Assertion parity: nothing removed, nothing weakened
I checked all six tests in the diff:
1. **Listen host (the full-run failure):**
   - The proxy-host settle and the DNS run state, host and port checks are unchanged and stay before the Quit.
   - `config.proxy_restart == 1` and the empty `config.dns_restart` check move after it.
   - The values asserted are the same.
2. **DNS commands chain:** the ledger, saved-config and DNS-stopped assertions are untouched. The Quit is inserted just before the one negative events-file check.
3. **Typing back to the committed port:**
   - The 100 ms sleep is removed, and the `proxyPort` assertion stays before the Quit.
   - "nothing rebound" moves after it.
   - The quit's teardown first calls `reconciler.quiesceEffects()`, so any rebind still in flight would be recorded before the flush.
4. **Unholdable duration:** the Quit is inserted before the negative `10000000000` check. That check now also covers the Quit's own events, so it is stricter.
5. **Listener edit:** the events-file poll and the 100 ms sleep are removed. The positive `count == 1` now follows the drain, which is equivalent to the old poll and catches a duplicate rebind too.
6. **Update credential:** the `config.workflow` poll becomes an assertion after the drain. The `TOKEN-HOST-7` negative moves after it. The config-file non-vacuity check and the snapshot read are unchanged.

### The causal boundary checks out in the source, with the stated limit
- `admitQuit` (`RuntimeHostLifecycle.swift:1005-1018`) runs, in order:
  1. the teardown;
  2. the wait for idle lanes;
  3. the close of the quit-flush window;
  4. `workflow.waitUntilIdle`;
  5. `await flushEvents()`;
  6. `quitDidEnd()`.
- `RuntimeQuitFlush.settled()` (`:85-99`) returns true only when `quitDidEnd` arrives before the deadline. The control owner reports `completed(.quit)` only on that answer (`RuntimeHostControlOwner.swift:287`).
- The same `beginQuit` / `finishQuit` → `.settled(.completed)` pattern is already used elsewhere in the suite (`AppStateHarnessTests.swift:387-388`, `:503-504`). The harness teardown skips its own quit because `beginQuit()` then returns false (`:170`).
- No host reference, test hook, polling mirror or new sleep was added.

### Wording that overstates the guarantee
You've already flagged this; it does not block Source.
- A completed Quit means the **attempted**, bounded diagnostic flush ended before the deadline. A drain can time out (2 s cap), be busy, or be unavailable. It does not mean the writer's queue is empty or that every record was confirmed.
- Besides the manifest's `causal_boundary`, one test doc sentence overclaims the same way. It says "every event the host recorded before the Quit has then left the writer's queue" (patch `:722`). The sentences right after it qualify that correctly, so only that one sentence should be reworded.
- **Consequence for the negative checks:** if a drain times out, the file is short. The positive checks (`count == 1`, `contains("config.workflow")`) catch that. The negative-only checks (DNS commands chain, typing back, unholdable duration, the TOKEN absence) would then pass vacuously. That is still better than before, when nothing was joined at all, and closing it fully would need a host reference or a flush report this layer doesn't have.

### Remaining vacuity (out of scope; fixable in the diagnostics slice without resetting this freeze)
- The snapshot-file read in the credential test (`?? ""`), as the manifest records.
- The `old :136` count read inside the settings-flood loop.
- The `config.workflow` non-vacuity witness matches any `config.workflow.*` event. The open's own `config.workflow.observed` startup event already satisfies it, so it proves the file was written, not that the save's event was. The old poll had the same weakness; this change neither introduces nor fixes it.
- The other 100 ms sleeps in this file are untouched.

### Remaining limitations
- The relay r1 limitations still apply unchanged. Relay commands can wait behind queued PlatformWork, and a stuck helper holds the DNS slot for up to its transaction budget. There is no blind relay stop at quit. The control cluster is still MainActor; the logger, actor retag and native work are not done.
- Execution evidence is the parent's: the r1 full run's 40/41 with this one test failure, the focused wQ7SU4 run, and the full 41-check run now in progress. I have drawn no conclusion from any of them.