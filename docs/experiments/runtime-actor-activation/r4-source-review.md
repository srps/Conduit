# R4 final review: the diagnostic-writer authority wrapper

**I accept R4 as the core final change.** It closes the R3 authority residual for every diagnostic writer under a leased root. I found no new causal defect; the limits that remain are below.

## The wrapper
- **Shape:** `retainingAuthority(_:)` returns `any RecordFileDestinationGuarding` backed by a private immutable struct that holds the session strongly plus the wrapped guard (`StateRootSession.swift:59-64, 91-103`).
- **Behaviour:** both `admit` calls delegate unchanged, so the protected-resource and alias policy is identical. That includes refusing the lease file.
- **No new surface:** the concrete type is hidden, and there is no raw lease accessor, queue, registry or budget.
- **No cycle:** the session still owns only its lease, and every writer holds the event log weakly.

## Six composition sites (complete)
- **Host:** events, snapshot, audit and config-less recovery (`RuntimeHost.swift:429, 439, 616, 1613`). `makeAuditSink` now takes the session (`:595-621`).
- **App:** the app log (`AppState.swift:131`) sits inside `appLogGuard.wrap`. So fakes such as `HoldingAppLogGuard` wrap a guard that already holds the session, and the harness hold sits outside the authority, in the writer's own guard path.
- **App export** (`:764`) is a synchronous admission and harmless.
- **Untouched by design:** pm-proxy's and pm-sim's `diagnosticDestinationGuard` calls take no lease, so they stay path-only.

## Ownership reaches through each physical queue
- **Events and audit:** `BoundedRecordWriter.append` queues `[self] in drain()` (`BoundedRecordWriter.swift:93`). The writer holds its `write` closure (`:36`), which captures the `RotatingRecordFile` (`RuntimeEventFileWriter.swift:35-36`, `StandardConnectionAuditSinks.swift:96-97`). The file holds the wrapper (`:157`).
- **Snapshot:** the writer holds the wrapper (`SnapshotArtifactWriter.swift:166`) and queues `[self]` (`:222`). This covers the post-flush coalesced-snapshot sequence I traced in the authority review.
- **App log:** `RotatingLogFile` holds the wrapper (`:107`) and queues `[self]` (`:198`).
- **Journal and store writes:** these go through awaited `PlatformWork`. Every cluster `Task` either captures `[self]` or binds a strong local after `guard let self` before awaiting, so the host, and with it the session, outlives them.

## The test is not vacuous
`testAHeldDiagnosticWriteKeepsTheRootLeasedAfterEveryOwnerLetGo` (`AppStateHarnessTests.swift:657-679`):
- **Hold placement:** the hold sits in the diagnostic writer's guard at file open (`holdTheAppLogOpen`, `:1116-1122`), not in the Quit's platform work. The Quit settles `.completed`, then the harness drops its references and the AppState is confirmed released.
- **Fails on R3:** the R3 baseline (`QMc8CJ` and `sj6DfB`) acquired the root while the write was held. That proves no host, app, harness or test-local reference was still holding it. The second run also showed the root coming free before the held line reached the file.
- **Passes on R4:** the probe reads busy while the write is held, and the root re-acquires after release. The held line is on disk before the root came free.
- **Scope:** it witnesses the general mechanism through the app log, not the exact snapshot-timer sequence. The manifest says so.

## Remaining limits (honest scope)
1. **Logger-first under the app Quit deadline.** When the logger is backed up and less than 2 s is left, the artifact flush starts at the deadline. AppKit's terminate can then lose the final snapshot, the final events and the logger-unconfirmed fact. This is app-only and is the cost of the selected order.
2. **Force-close harnesses.** InteractiveHostHarness and DaemonHarness still use `releaseForTesting` after a confirmed settle and flush. A force-close ignores any holder, so the wrapper can't help there, and a post-flush late artifact job can still race their scratch removal. That is a flake risk in tests only. A natural drop plus the existing re-acquire proof would close it, but that is not required for this cut.
3. **Hung I/O.** A diagnostic write stuck on I/O keeps the lease until it ends or the process exits. 0017 requires this, and in tests it fails loudly. Production is unchanged in effect, because both entry points pin the session for the process.
4. **Test limits carried forward:**
   - the auth negatives read after a measured bound;
   - the DNS skip branch after a Stop has no positive witness;
   - the placement row binds the fixed loopback port 15053;
   - the held-Quit row holds a subprocess, not helper IPC;
   - the DNS counter test blocks a pool thread and stays out of strict mode.

**Carried forward:** #250 (GSS pool saturation) and #118 (TSan, pending).

**Not covered by this acceptance:**
- R4's full41, which is still running (R3's pass is not R4 evidence);
- TSan;
- the optimized runs;
- Profile/full31;
- native checks;
- CI.