# Resource review: full-capture owner turn versus selected control fairness

**This is material.** It is a selected requirement that is still uncompleted. It is not a defect in the accepted Stage B Source, which stands. The simplest cohesive fix needs no owner decision, as long as it stays inside the existing 0038 bounds.

I can only read files in this session, so the parent needs to save this as a separate resource-review report; I haven't touched the Source acceptance report.

## What the three optimized trials show

| Trial | Projection turn | Status after issue | Stop after issue | Status after the turn ended | Max UI heartbeat lateness |
|---|---|---|---|---|---|
| 1 | 0.485 s | 0.488 s | 0.488 s | 3.6 ms | 3.4 ms |
| 2 | 0.481 s | 0.484 s | 0.484 s | 3.8 ms | 4.0 ms |
| 3 | 0.630 s | 0.634 s | 0.634 s | 3.8 ms | 7.0 ms |

- **Status and Stop wait for the whole projection.** Their latency equals the turn length to within about 4 ms. Admission and the framed path add only milliseconds.
- **The UI is fine.** No heartbeat was late by more than 16 ms. The RuntimeActor move achieved this; on MainActor the same turn blocked the UI.
- **Retained custody is within bounds:** two row sets of about 6.0 MB, against the 8 MiB ceiling.
- **Scope:** a fake owner with the production projection, core and framing. This is not a physical Stop or app RAM measurement.

## Why it is a selected, uncompleted requirement
- **0031** names it directly: "short owner turns" (`:60`) and "responsive Stop/status under slow effects" (`:117-118`). At `:244-245`: "The full-list baseline still shows a long current-owner turn, so whole RuntimeActor and full-capture control fairness remain required". At `:261`: "verify owner fairness".
- **0038** requires "Keep Stop/status independent under pressure" (`:71-72`).
- **Measured:** Stop/status latency during a capture is O(rows) and equals the turn, so they are not independent.

## Cause in the code
- **One synchronous owner turn:** `pageSource` → `.needsCapture` → `captureCurrent` → `owner.projectedRows` (`RuntimeServiceCore.swift:546-590`).
- **What it does:** it sorts every connection (`RuntimeSnapshotControlProjection.swift:101-106`), then maps and measures each row through `budget.measure` (`:86-87`, `:134ff`). Over 10,000 rows that is about 48 µs per row.
- **Its input is already a value:** `orchestrator.snapshot` is a copy-on-write value (`RuntimeHostControlOwner.swift:188-189`), so the expensive part is a pure function of it.

**Why "material" and not just a one-off spike:** whenever a list is being refreshed, the app observer reads pages back to back. Each newer snapshot or stale reply triggers one more pass (`RuntimeObserver.swift:246-262, 288-298`). While churning connections keep changing the revision, each pass needs a fresh capture. So control latency of about 0.5 s can repeat for as long as the list stays visible under load. That is inferred from the code; nothing measured it.

## Recommended fix: project off the owner, commit on the owner (no owner decision)
1. **In the page round:** take the value snapshot, revision, total and budget. Start at most one off-owner projection per kind (single flight, so later page requests join it), as a CPU task on the cooperative pool. Not PlatformWork, where helper calls of up to 40 s could queue ahead of it.
2. **While it runs:** the page wait parks through the existing `RuntimeWaitGate` park and wake path that stream pulls already use, bounded by the request's own deadline. This adds no transport primitive.
3. **On completion:** one owner hop calls `collections.capture(revision:…)` and wakes the parked waiters. Captures are revision-qualified, so rows from a snapshot that has since moved on are still correct and are served as stale; there is no freshness hazard.
4. **Custody:** reserve the in-flight capture against the existing 4 MiB capture budget at start, and release it on commit, failure or shutdown. Single flight keeps the extra custody to one capture. The 10,000-row, 4 MiB and 8 MiB bounds are unchanged.
5. **Quit and Stop:** an in-flight projection is abandoned at service shutdown and commits nothing afterwards.
6. **Acceptance, causal and with no timing number:** flip the existing capture fairness test. Status and Stop issued during the projection must be answered before it exits (`statusAt < exited`) under a normal pool. Under the one-thread strict pool it stays inconclusive.

**Optional on top:** make each row's measurement cheaper. That reduces CPU, but on its own it does not remove the O(n) wait.

## Alternatives (not recommended)
- **Chunked projection inside the owner, with yields:** this needs partial-capture state and invalidation mid-capture, the owner's total CPU is unchanged, and fairness then depends on priority interleaving.
- **Lower the 0038 bounds:** this needs an owner decision and only shrinks the O(n) turn.
- **Throttle observer refreshes:** this changes how fresh the displayed list is, which is a product choice and needs an owner decision. It isn't needed if the recommended fix lands.

## Owner decision
- **Not needed** for the recommended fix. It implements the already-selected 0031 fairness requirement without changing 0038 bounds, semantics or deadlines.
- **Needed** only to set a numeric latency budget, lower the bounds, or throttle refreshes.

## Status
- Stage B Source acceptance is unaffected.
- 0031's full-capture fairness stays open until this lands. A release-readiness claim should not cite owner fairness before then.
- Carried forward unchanged: #250, the logger-first deadline tradeoff, and Profile31 in its own lane.