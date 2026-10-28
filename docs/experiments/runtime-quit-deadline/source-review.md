**Verdict: ACCEPT.** I don't require any fixes. This is a read-only review: I compiled and ran nothing, and I couldn't recompute the `manifest.json` hashes. The six files in the worktree do match the copies and the patch where I spot-checked them, for example `RuntimeHost.swift:1001`.

**The fix: Quit deadline passed through to the artifact flush**
- **`DiagnosticFlush.swift:17-19`:** the new init sets `deadline = cap.map { min($0, envelope) } ?? envelope`.
  - A cap can only cut the 6 s envelope, never extend it.
  - A cap that has already passed makes `nextDeadline()` return nil, through the existing `now < deadline` guard. The writers then report the existing `skippedBudget` and unconfirmed outcomes and the existing warnings. There's no new phase, outcome, wait or retry.
  - The per-writer `writerWait` limit is unchanged. Nothing is cancelled, so writes that have already started keep their authority.
- **`RuntimeHost.swift:997-1001`:** the same `cap` now goes to both the logger drain and the single artifact phase.
- **Only the control Quit passes a deadline:** `RuntimeHostControlOwner.swift:224` → `admitQuit` → `RuntimeHostLifecycle.swift:1018`. Every other caller keeps nil and the ordinary 6 s phase: the `shutdown()`/`stopRuntime(exitAfterStop:)` defaults, `ConduitDaemon` (134, 160), `RuntimeHost:651`, `pm-proxy:338`, `BoundedWriterScenarios` and the harness teardown flush.
- The Source now matches the two checkpoint sentences quoted in the policy review, so no doc change is needed.
- There's no wire change, public hook, clock protocol, mode, registry or duplicate flush path.

**The tests are causal and not timed**
- **`testAQuitPastItsDeadlineGivesTheArtifactFlushNoFreshWait`:**
  - The cap has already passed before the Quit is admitted, so every result is decided by computed values, whatever the machine load.
  - `.last` on the in-memory `eventLog` (and `typedEvents()`, which reads the same log) is deterministic.
  - With control A (propagation removed), the Quit's audit and events drains don't skip. Either no new `flush_timeout` appears, or one appears with a different detail, so the detail assertion fails either way. The snapshot assertion also stops matching.
  - The harness `tearDown` (`RuntimeHostInteractiveTests.swift:183-197`) then runs a nil-cap flush, so the files skipped at the Quit are confirmed and the harness's confirmation gate is unaffected.
- **pm-sim:**
  - The cap is `capStarted`, so it is ≤ now by the time it's checked. Under the existing guards (`deadline > now` for the logger, `now < deadline` for the artifact phase), equality counts as passed, so all four drains skip.
  - The later ordinary flush (`:306-308`) still needs `allConfirmed` and still finds both logger facts in the owned file. That holds because skipped drains record no drop or failure, and that flush drains the snapshot again.
- **Unit test:** the passed, near, far and none cases are right.
- **Negative controls:** I agree with the author's predictions. A should fail the host test and the pm-sim check while the unit test still passes. B should fail all three. Both are removal-only.

**Fixture and model changes**
- **3 s → 10 s:** only the `total:` literal changed in both no-stream tests. Every settled, persistence, teardown and custody assertion is intact. The 2 s held-unsettled test is unchanged.
  - That test still reads `unsettled` because teardown is held, not because of timing, so the bump doesn't hide that fault.
  - The deadline bound is now tested separately, which answers the policy review's point that the bump alone wasn't sufficient.
- **`ConfigurationStoreTests:1260,1263`:** the only change is `@RuntimeActor` on the two local helpers. The enclosing test is already `@RuntimeActor`, and no rule or assertion changed.

**Optional nits (not required)**
- `RuntimeHost.swift:993` wasn't reflowed after the inserted clause; the line breaks early at "The drain's own unconfirmed fact is".
- The near-cap unit case only fails if the thread stalls for more than 1 s between two adjacent lines. Any cap below `writerWait` gives the same equality, so a value near 1.9 s would roughly double the slack. The author already flagged this risk.

**Limits**
- The clamp doesn't make the d038 failure impossible. Teardown and store work aren't clamped, and a host that settles right at its deadline can still read `unsettled` at the routine's final read, 200 ms before the deadline. That's why the 10 s fixture is still needed.
- As noted, an `unsettled` read can also come from a failed or busy lookup, so I make no claim about which I/O step caused the CI failure.
- Under a client Quit that runs out its time, events recorded after the deadline now stay unpersisted in that Quit's own flush. That's the intended 0039 behaviour. I didn't audit the whole suite for tests that read `events.ndjson` after such a Quit, and the full41 run will settle it.
- I don't count any of your queued checks as passed yet, and the existing f3 evidence stays limited to the paths it covered.