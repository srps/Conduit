# RuntimeActor Stage B R3: final review

**I accept R3, with the limits below.** Every earlier finding is closed, and I found no new correctness defect. One new limit comes from the logger-first order: under the app's Quit deadline it can cost the final event and snapshot records. It sits within the order you selected, and I record it rather than ask for a change.

## Earlier findings

| Finding | R3 state |
|---|---|
| pm-proxy signals abort (P1) | Closed. Both handlers are `@Sendable` (`PMProxy.swift:197, 210`). One `@RuntimeActor @Sendable` reload closure (`:161-170`) serves both the control path and SIGHUP; the control path throws a rejection, and SIGHUP catches it and leaves the generation unchanged. The CLI scripts pass. |
| Tunnel resolver on the pool (P2) | Closed. It uses the host's single existing PlatformWork, with no default and no new queue. The fourth placement row (`RuntimeActorPlacementTests.swift:155`) also checks `removeDNS`, that no resolver file is left, and `tunnelsRunState == .stopped`. |
| Last-value hops (P3) | Closed, with causal tests (below). |
| Auth producers and log spam (R2) | Closed. `publishes` covers both producers, plus the never-admitted escape (`ProxyOrchestrator.swift:626-627`). It gates both transition lines and the snapshot write. The event stays unconditional, and the fallback line keeps only its rate gate. |
| Teardown custody chain | Closed. The logger drains first and its unconfirmed fact is recorded first (`RuntimeHost.swift:997-998`). `reportWriterLoss` follows, then one unchanged `DiagnosticFlush`. The harness proves the lease is closed before it removes anything. The preferences quit preflight landed in R2. |

**No new production hooks.** The only `+package` lines in the patch are signature retags. `mutateSnapshotForTesting` was already in the base source (R1 `ProxyOrchestrator.swift:421`); R3 only adds call sites.

## Resource custody
- **The lease proof is real.** The lease is `flock(LOCK_EX | LOCK_NB)` on a fresh descriptor (`StateWriterLeaseOS.swift:27-28`). flock locks belong to the open file, so a probe from the same process reads `busy` while the host's session is open.
- **The probe is honest.** It runs the production bootstrap off main with `createRootIfMissing: false`, retries only on `busy`, and releases its own session with an asserted `.released`. On timeout it fails and keeps the root (`AppStateHarnessTests.swift:203-249`).
- **The new held-work test is causal:**
  - with the Quit's teardown held, the root reads `busy`;
  - after release, it is acquired again (`:625-651`);
  - B1, which force-released the lease, would have failed it.
- **Why the proof is enough:**
  - quit end implies the logger's fact is inside the artifact flush;
  - the host's session closes only when the host deallocates, after its Quit tasks end;
  - once the flush is confirmed, no admitted record is left in any writer.
- **Residual gap:** if the artifact flush itself does not confirm, a writer that outlives the host can still write after the lease closes. This matches the manifest's gap-2 limit.
- **`joinDrained` is sound.** `drain` returns `.drained` whenever the group is empty, without checking the slot (`RecordDrainWaiter.swift:107`). One narrow window remains: a line logged in that pm-sim workflow host before the old notify block clears its owner could read `busy`.

## Test meaning
- **Tunnel session hop** (`RuntimePhysicalOrderingTests.swift:740`):
  - signal values no state holds (9, then 7) are published as the locked count;
  - after the Stop, a real `tryAcquire` publishes 0, which positively witnesses the admitted-Stop branch.
- **DNS metrics hop** (`:775`):
  - the first hop to land after the sentinel reads both real loopback queries;
  - after the Stop, the core is nil;
  - the restarted core counts from 0.
  - It blocks a pool thread for up to 10 s and is rightly kept out of strict mode.
  - As the manifest says, the skip-after-stop branch has no positive witness. Catching a regression back to queued values relies on FIFO landing order; the claim itself does not.
- **Auth tests** (`KerberosFallbackEventTests.swift:157-202`):
  - each hop's own write is its positive witness;
  - the all-stopped negatives read after a measured bound and say so;
  - the case with only tunnels stopped exercises the rule that the escape requires both epochs to be 0.
- **Held-Quit row:** it now runs with the main thread parked. It holds a teardown subprocess, not helper IPC, as the manifest states.

## New limit: logger-first order under the app Quit deadline

**Concrete order:**
1. The app log writer is backed up, and the Quit's teardown ends with less than 2 s (`writerWait`) left before the deadline.
2. `drainLogger` waits until the deadline (`RuntimeHost.swift:1019-1020`).
3. `DiagnosticFlush` starts only after that. Its phase is up to 6 s and is not capped by the Quit deadline (`DiagnosticFlush.swift:9-11`).
4. `quitDidEnd` (`RuntimeHostLifecycle.swift:1019`) therefore lands after the deadline.
5. `finishQuit` returns at the deadline, and AppKit's terminate then ends the process mid-flush.

**Result:** the final snapshot, the final events and the logger-unconfirmed fact itself can be lost. Under the B1 order, the artifacts were confirmed before the logger wait.

**Scope:** app-only. Daemon and SIGTERM quits carry no cap, so both phases run to completion.

**Option, if the parent wants it:** cut the logger drain so it ends no later than the cap minus the time the artifact phase needs. That is a budget choice, so I'm not asking for it. Otherwise, record this as the cost of the selected order.

## Other stated limits I accept as written
- **Auth:** an old run's outcome can still publish after a Stop followed by a restart, and `stopTunnels` doesn't clear the outcome.
- **Placement row:** the fixed loopback port 15053 can fail the row if another process holds it, and no baseline was run against the old pool-blocking manager.
- **InteractiveHostHarness** still uses `releaseForTesting`, but only after a confirmed settle and flush.
- **Leftover duplicates:** the `MainThreadPark` copies in Tests and pm-sim are unchanged.

Carried forward unchanged: GSS pool saturation (#250) and TSan (#118, pending). The parent's full41, TSan, optimized, profile31, native and CI gates remain separate.