# RuntimeActor prerequisite: diagnostics

Status: corrected Source passes all 41 workflow checks and independent review.
Production Release probes and optimized XCTest measurements also pass; hosted and native gates remain. The initial candidate also passed the workflow
but was not accepted: independent review found a write/close custody race. The runtime cluster is still MainActor; native and release acceptance
are separate. Official Claude Code implements and independently reviews through
the authenticated claude.ai subscription, with API fallback disabled.

## One physical output path

AppLogStore creates one entry and formatted sanitized line for file and console
admission; physical output no longer waits for UI history. Only the bounded
history handoff crosses MainActor, with one scheduled drain and amortized trim.
History eviction is separate from physical record loss.

The existing RotatingLogFile queue admits bounded records/bytes and supports an
asynchronous deadline drain through the existing single-slot waiter. Close
latches admission before its queue join; admitted work must finish first. The
store closes its current writer outside its lock, folds physical counters and
swaps it, without a retired-writer registry. It owns timeout counts so a wait
finishing after a swap is neither lost nor counted twice.

LogSink defaults an unsupported asynchronous drain to unavailable. The host
awaits logger output separately from artifact confirmation; the app drains its
final lines using its original total Quit deadline. Neither gets a fresh wait
past expiry. A typed lifecycle.log_flush_unconfirmed records finite source and
outcome values, mapped exhaustively to separate wire values. It is emitted
before its derived line; neither is claimed persisted after an unconfirmed drain.
Ready-file I/O uses the host's existing PlatformWork, before snapshot submission.

## Review and causal evidence

[The first workflow](experiments/runtime-diagnostics/r1-full-workflow.json)
passes all 41 checks, 3,727 tests (four existing skips), and all 103 simulator
scenarios on stable source. [Independent review](experiments/runtime-diagnostics/r1-source-review.md)
finds that admission could precede close while the drain enqueue followed it.
Close could then return before the admitted record settled, losing its counter
when the store folded and replaced the writer. Workflow success did not expose
that interleaving.

[The correction plan](experiments/runtime-diagnostics/r1-correction-plan.md)
moves the enqueue inside the admission lock; the operation only schedules work.
It also replaces the host test's elapsed-time guess with a positive logger-entry
witness. The retained concurrent custody test checks pending, written, dropped,
failed and actual file contents; stress alone does not deterministically force
the old race. Temporary controls and corrected execution are recorded separately.

[Review clarification](experiments/runtime-diagnostics/r1-deadline-and-waiter-clarification.md)
confirms that the artifact phase's post-expiry host custody is consistent with
the bounded app caller. It grants no extra app wait and may be cut short by exit.
The existing waiter suite already tests a drained wait whose retired timer keeps
capacity busy; no duplicate test or capacity increase is needed.


## Corrected verification

[Corrected full workflow](experiments/runtime-diagnostics/r2-full-workflow.json)
passes all 41 checks: 3,728 tests (four existing skips), all 103 simulator
scenarios, perf, packaging and standalone regressions. Source remained
`8fb4376aaa58a1d14b631b4c091c9d3a6de93fa732f487a27ac0e1ba496c8896`.
[Independent review](experiments/runtime-diagnostics/r2-source-review.md) accepts
Source and the measurement code, separating that verdict from execution.
[Production comparison](experiments/runtime-diagnostics/r2-production-comparison.json)
confirms the lock fix is the only production change from r1 across 404 files.

[The correction manifest](experiments/runtime-diagnostics/r2-correction-manifest.json)
records 568 focused tests and three passing scenarios. The widened-window control
observed 314 pending records after close and then 314 failed late records; the
corrected writer passed the same custody assertions. Two earlier controls missed
the window and are not witnesses. The blocking-flush control failed the stronger
host test because it never entered the asynchronous drain; the restored path
passed. No temporary controls remain. Ready-file content is tested; ordering
rests on the awaited code path, not on a filesystem timestamp comparison.


## Resource observations before isolation

[Raw Release records and summary](experiments/runtime-diagnostics/release/summary.json)
cover six fresh held-logger trials (three with and three without the sampler) and
three held-capacity pressure trials. Source and objects remained stable during
each run, with no output/privacy violation or unreleased scratch root. Under a
held logger, status maxima were 0.26–0.53 ms, Stop admission 0.25–0.73 ms and
completion 2.56–7.57 ms. The deliberately requested two-second drain took
2.028–2.116 seconds including timer/scheduler delay. Records after release were
fully accounted for; no loss or failure was observed.

The logger is probe-local over the real kernel writer, not AppLogStore. These
figures do not measure UI history, console/os_log cost or actual app RAM. Pressure
trials have zero connection rows: they are capacity/hold evidence, not full-list
capture evidence. No historical performance comparison is claimed.

[Three optimized XCTest trials](experiments/runtime-diagnostics/optimized-consumer-results.json)
pass 44 tests each, covering actual AppLogStore, file writer and the app observer's
10,000-row path. Each capture contains 3,006,968 encoded bytes over 47 pages, with
four revisions per trial; per-capture time was 0.741–0.763 seconds. Worst heartbeat
lateness was 0.471–0.476 seconds, including scheduling delay. Mapping collected
rows took 0.51–0.59 ms. These use Release optimization with testability enabled;
the unchanged raw output has historical debug labels, explicitly corrected by
the command/configuration metadata. The first wrapper time includes rebuilding.
They are not shipping UI latency or an app RAM bound. Full-capture Stop/status
fairness remains part of the actor move, paired against this baseline.

[Snapshot/workflow linkage](experiments/runtime-diagnostics/r2-snapshot-workflow-link.json)
compares all 741 included relevant files byte-for-byte and lists the 17 omitted
build resources; [test identity](experiments/runtime-diagnostics/r2-test-identity.json)
records the key new tests and four skips in the actual full run. Release's
separate fingerprint domain is [linked to the same worktree](experiments/runtime-diagnostics/release/source-link.json),
and [probe hashes](experiments/runtime-diagnostics/release/probe-snapshot-link.json)
match the independently reviewed experiment.

## Remaining acceptance

Finish exact-head hosted CI and native/machine acceptance. The experiment reuses the actual host and
framed clients over explicit fakes and owned scratch state. Encoded pending bytes
are custody limits, not preallocated or measured app RAM. Native UI history,
AppKit final-edit/Quit and real-helper timing remain separate. These changes do
not complete the whole RuntimeActor move or establish release readiness.
