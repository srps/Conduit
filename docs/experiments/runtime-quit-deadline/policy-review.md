**The documented contract is clear, so this is internal correctness, not a new owner decision.** The Source doesn't match what the docs and the R4 reviews claim. But the bound the user experiences still holds, so this doesn't have to block the release.

## What the Source does

- In the Quit path, `admitQuit` passes its deadline only to `flushEvents(loggerUntil: deadline)` (`RuntimeHostLifecycle.swift:1018`).
- Inside `flushEvents`:
  - the logger drain is cut to `min(cap, now + writerWait)` (`RuntimeHost.swift:1016-1020`);
  - the audit, events and snapshot drains then run in a new `DiagnosticFlushPhase()`. Its deadline is now + 6 s, regardless of the Quit deadline (`RuntimeHost.swift:1000`, `DiagnosticFlush.swift:15-16`).
- So the artifact phase can wait up to about 6 s after the Quit deadline has already passed.
- Two docs say otherwise:
  - the activation checkpoint (`:46`): "Logger drain precedes **one artifact flush within the original total Quit deadline**";
  - the diagnostics checkpoint (`:25`): "Neither gets a fresh wait past expiry".

  The R4 reviews claimed the same.

## Classification

- **Decision 0039:** the one total is "counted once … spend only that remaining time on … cleanup confirmation". Expiry ends waiting, not physical work: started writes keep their authority until they finish or the process exits (0017 and 0039).
- **So the correct behavior is:** the Quit's artifact phase should be bounded by the original Quit deadline. The ordinary flush has no deadline (`flushEvents()` at `RuntimeHost.swift:651`, and a quit admitted with `until: nil`), so it should keep its 6 s phase.
- **No owner decision or API choice is involved.** `flushEvents` and `DiagnosticFlushPhase` are package-internal. The wire format, the totals and the policy all stay the same.
- **No user-visible breach today:**
  - The app's wait ends at its total, because the client routine returns when its deadline expires.
  - In the app, the process then exits, which cuts off any later artifact waiting anyway.
  - The actual effect is that the host settles late, which surfaces as `unsettled` and as the CI failure you saw.
  - Please confirm from the CI log that the routine's own elapsed time is within its total plus the 200 ms final read. The test's 4.124 s probably includes setup; I haven't verified that.

## Minimal clamp, not to be implemented now

- Give `DiagnosticFlushPhase` an optional absolute cap: `init(budget: Duration = defaultBudget, cappedAt cap: ContinuousClock.Instant? = nil)`, with `deadline = cap.map { min($0, now + budget) } ?? now + budget`.
- In `flushEvents(loggerUntil cap:)`, pass the same `cap` to the phase.
- Then:
  - a passed deadline makes `nextDeadline()` return nil, so the remaining writers report the existing skipped/unconfirmed outcomes and the existing warning;
  - nothing is cancelled;
  - with no cap, behavior is unchanged.

**Causal test, with no fake-clock API:**
- Use the existing held-destination seam on the events writer, the one the logger-held tests already use.
- Record the `until` value its drain receives during a Quit with a short total.
- Assert that the recorded value is not later than the Quit deadline, and that a plain `flushEvents()` still receives now + `writerWait`.
- Negative control: with the cap removed, the recorded value is now + 6 s, so the test fails.
- This compares values the code computed, so it is deterministic.

## The fixture change from 3 s to 10 s

- **Acceptable as a test-only change:** it matches the shipping total, keeps the same assertions, and gives load slack.
- **Not sufficient alone:** it doesn't test the boundary, and it would hide the doc/Source mismatch. Even with the clamp, a host that settles exactly at the deadline can still read as `unsettled`, so that test stays a semantic check, not a timing proof.

## Recommendation

- **For this release (keeps the f3 product evidence valid):** take the 10 s fixture, and correct the two doc sentences. Suggested wording: "the logger drain is cut to the original Quit deadline; the artifact flush after it has its own ≤ 6 s phase. The app's wait still ends at its total, and process exit cuts any later waiting." Also file the clamp plus its causal test as a follow-up issue.
- **Alternatively:** implement the clamp now. It's small, but it changes product Source. That means a new Source review, full41, hosted CI, and a rerun of the profile's client-quit mode, so it's your scheduling call.

Either way, there's no architecture or owner decision here.

This was my last review in this session. I made no edits and no machine changes.