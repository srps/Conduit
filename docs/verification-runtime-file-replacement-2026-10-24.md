# Verification: runtime configuration verified replacement (2026-10-24)

Scope: one physical building block for the future configuration store, on branch
`codex/verified-runtime-file-replacement`, rebased onto merged PR228 (`9c13d8a`). It is unwired. Nothing
calls it at startup, in the host, in AppState or in a store. It adds no intent
generation, no receipt, no expected-prior check, no sidecar or journal cap, no
fallback and no external-edit policy. It is not the mixed-apply hold of
[0025](decisions/0025-hold-mixed-configuration-apply.md), which is still planned.

## Source changes

- `ProxyKernel/Support/ProxyConfigPersistence.swift`: package `writeStagedRuntimeFile(_:to:)`
  wraps the existing private `writeData`. `save(_:to:)` calls it, so the legacy save and the
  adapter share one physical write path.
- `ProxyKernel/Support/ConfigurationFileReader.swift`: package `read(at:limit:)`
  delegates to the three-argument reader with `Darwin.close`. The approved 8 MiB precondition
  and the existing entry points are unchanged.
- `PlatformMac/StateFileAccess.swift`: `RuntimeFileWriteError`, the `StateFileAccessing` protocol
  over a resolved `StateRootFile`, the package factory `StateFileAccess.operatingSystem()` and the
  internal OS adapter. The error keeps a closed code only: `writeFailed(errno:)` for a positive POSIX
  code that fits `Int32`, `cocoaFailed(code:)` for a Cocoa error with no usable POSIX cause, and
  `unclassified` for anything else. The classifier is `OSStateFileAccess.writeError(for:)`. It follows
  the `NSUnderlyingError` chain for at most four links, and it never retains a domain, description,
  path, bytes or user info. An unusable POSIX code (outside `Int32`, or not positive) is never
  converted or called `EIO`: under an outer Cocoa error the outer Cocoa code is kept, and under any
  other error the result is `unclassified`. No failure is mapped to `EIO` for lack of information.
  These mapping cases are synthetic witnesses of the classifier's input contract, not a claim that
  each shape occurs on this OS.
- `PlatformMac/VerifiedRuntimeFileReplacement.swift`: the operation, its refusals, its
  unknown reasons and its outcome. The outcome carries no bytes and no path.
- `PlatformMac/PlatformFakes.swift`: `FakeStateFileAccess`, a low-level fake with scripted
  reads and writes, external edits before and after a write, and an observation log.
- `pm-sim/ScenarioRuntimeFileReplacement.swift`, registered in `pm-sim/Main.swift` as
  `runtime-file-replacement`.
- Tests: `VerifiedRuntimeFileReplacementModelTests.swift`,
  `VerifiedRuntimeFileReplacementOSTests.swift` and `StateFileAccessWriteErrorTests.swift`, the last
  one a synthetic-witness test of the write-error classifier that writes no file.

## Algorithm

1. Refuse before any I/O: a role other than `.config`, a path outside the leased root, or staged
   bytes over the 8 MiB budget.
2. Pre-read at the 8 MiB budget. A missing file is an absent prior. Any other failure is
   `notStarted`: no write, and not an unknown commit.
3. Replace through the shared atomic write. Keep the error if it throws.
4. Read back with limit `max(staged length, observed prior length)`. The reader adds its single
   probe byte. Use the observed prior, not a re-stat, so the bound matches what the pre-read saw.
5. Classify. Read-back equal to the staged bytes is `verifiedPersisted`, even if the write threw.
   A read-back failure other than missing is `unknown`. A thrown write with a read-back equal to
   the observed prior, or to an absent prior when the read reports missing, is
   `verifiedNotPersisted`. Anything else is `unknown`.

Two rulings. A prior that already holds exactly the staged bytes is content identity, so a thrown
write there is `verifiedPersisted`, not `verifiedNotPersisted`. The verdict follows the
observer's knowledge: a read that reports missing counts as absent even when the disk holds the
staged bytes. That is what the decision rules say, and the model and a witness pin it.

## Model and fixture bounds

The model and the production operation run over `FakeStateFileAccess`. The expected results come
from a model written from the rules, not from the production classifier.

- Matrix: 432 cases = 4 stored priors (absent, same as staged, small, larger) × 3 pre-read modes
  (actual, missing, failed) × 3 write modes (lands, fails before landing, lands then fails) × 4
  external edits after the write (none, other bytes, removed, 128-byte file) × 3 read-back modes
  (actual, missing, failed). 288 cases reach the write; 144 stop at a failed pre-read.
- Each case checks the outcome, every call in order with its budget or byte count, and the stored
  bytes afterwards.
- Hand-written witnesses: ten expectations that pin rules the model must not bend, including
  throw-after-landing, an unchanged larger prior after a failed write, an external edit before a
  failed write, and a missing read-back with the staged bytes on disk. Three refusals, each with
  no call made.
- Adapter-level mutants, test-only: four breaks of the access contract (a thrown write reported as
  success, a failed read reported as missing, an unbounded read-back, a read-back that echoes the
  staged bytes). Each must produce at least one mismatching case, and the first is printed as its
  witness.
- Fake bounds: scripts up to 8 entries per kind, an observation log of 16, and 8 stored paths. Each
  is enforced by a precondition, not a growing array. Bytes per file are not capped, so a fixture
  can hold oversize bytes to exercise a refusal.

This is a fixed-matrix model of one replacement. It is not a temporal store model: it has no
concurrent callers, no queue, no caller deadline, no Stop or Quit, and no generation ordering.

## Real OS scope

Scratch directories with real leases on canonical roots. Cleanup releases the lease first, and the
directory is removed only after a confirmed release. An unconfirmed release keeps the directory on
disk, since its lock may still be held, and fails the test or the scenario verdict. An acquisition
that was attempted and returned busy or failed also keeps its directory, because no authority was
confirmed. Only a failure before any attempt removes the fresh scratch directory. The scenario checks
its cleanup in its verdict, not only in a printed message. Its verdict holds at most 32 assertions and
8 notes, and a run past either bound traps. Covered: create, overwrite with a larger and a smaller prior, a
symbolic-link config written at its resolved target, a foreign root and a wrong role refused with
no file created, a directory prior not started, a read-only directory that refuses the write with
a 64-byte prior kept unchanged (skipped under root), and the budget exactly and one byte over. A
failed restore of the directory mode is a test failure, not a silent drop.

## Limits

- No power-loss durability is claimed. Verification compares identity.
- No expected-prior freshness: a caller that needs one checks it in the future store.
- No exclusion of nonparticipating external editors. The lease excludes cooperating writers only.
- `StateWriterLease` has no held-state query, so the operation checks only the lease's root. The
  caller proves that the lease still holds.
- Fake throw-after-landing is a model of a write error, not an OS reproduction. The OS tests cover
  only the failures a read-only directory can produce.
- Sidecars, the journal, startup, host and AppState adoption and the intent allocator are not
  covered. No sidecar or journal cap is introduced.

## Recorded future work, not implemented

Platform and preferences staging and verification; the browser URL bound in normal preferences;
sidecar physical budgets and grammar acceptance; writer lease adoption in startup and the journal;
total shutdown; and the actual client, store and model engine.

## Results

Wrapper: `bash /private/tmp/conduit-runtime-stage1-20261024/verify-runtime-replacement.sh`, run
once on the frozen source. Logs are under
`/private/tmp/conduit-runtime-stage1-20261024/runtime-replacement-checks`.

Final run on the frozen source (the write-error mapper with the unusable-POSIX fallback to the outer
Cocoa code, the read-back doc and the ADR 0021 wording): the wrapper exited 0 and printed
`PASS: runtime replacement focused checks`. An earlier run predates the fallback change and is superseded.
The counts below are from the run on this source.

- `build.log`: `Build complete`.
- `tests.log`: the filter `State|Writer|Replacement|ConfigurationFile|ConfigSaveGate|Duration`
  executed 439 tests with 0 failures. That includes `StateFileAccessWriteErrorTests` (8 tests, new
  in this change), `VerifiedRuntimeFileReplacementModelTests` (4 tests) and
  `VerifiedRuntimeFileReplacementOSTests` (7 tests, none skipped: the test user is not root).
  Its `probe:` lines are existing diagnostic output from the OS probe tests. One of them reports that
  an atomic write through a symbolic-link leaf replaces the link, which is why the operation writes
  the resolved target.
- `imports.log`: the kernel import and `Process` fence passed over 103 Swift files.
- `events.log`: the event catalogue passed, with 207 product event names.
- `decisions.log`: the decision records passed, including history and supersession links.
- `replacement-sim.log`: `pm-sim runtime-file-replacement` passed all 17 assertions. Each assertion
  is listed in the NDJSON line, and the cleanup assertions are part of the verdict.
- `file-sim.log`: `pm-sim config-file-boundary` passed.

Model and fixture bounds from the same run:

- Matrix: 432 cases, 288 reaching the write and 144 stopped by the failed pre-read. Outcomes:
  `notStarted` 144, `unknown` 216, `verifiedNotPersisted` 54 and `verifiedPersisted` 18.
- Ten hand-written witnesses plus three refusals, each with no call made.
- Adapter mutants, test-only. The oracle caught each one with a printed witness:
  `hideWriteFailure` 192 of 432, `readFailureAsMissing` 265 of 432, `unboundedReadBack` 288 of 432 and
  `echoStagedOnReadBack` 288 of 432.
- Fake bounds: 8 scripts per kind, 16 observations and 8 stored paths, each enforced by a
  precondition. Stored bytes are not capped.

Warnings present in the logs are pre-existing: the `as` test in `readRuntimeFile` at
`ProxyConfigPersistence.swift`, which this change does not touch, and warnings in existing DNS
scenario and test files.

Earlier runs of this wrapper stopped at three problems, and all three were fixed before the run
recorded here: a pm-sim compile error, from an internal `StateRootFile` initializer that the scenario
now avoids by taking its files from `StateRootLayout`; one wrong expectation for a foreign path in the
no-I/O refusal test; and a test-target access error on the scratch lease. A cleanup change also
followed: the scratch root is now removed only after a confirmed lease release, in both the scenario
and the OS tests. A final change keeps the root when an acquisition was attempted and returned busy
or failed, and bounds the scenario verdict at 32 assertions and 8 notes. The run recorded above is the
one on that final source, and it exited 0.

## Final complete workflow

All 39 checks corresponding to `.github/workflows/swift.yml` passed on final source
head `e5b8874612574266c709cf332a71893888c36cf8`. The source fingerprint before and
after the run was identical:
`6a258680505170a169ab3bb75088fe1ce150f124f17266a514f2e736046c7957`.
Subsequent evidence edits are Markdown only.

Full Swift suite: 2865 tests, two skips, zero failures. `pm-sim all`: 93 result
records, all passed. The existing 100-connection performance gate passed at 10.24 s
wall and 34,488,320 bytes maximum RSS. That is the existing synthetic proxy traffic
workload, not a worst-case configuration memory bound. The complete run also
passed the policy/mutation checks, signed updater stand-ins and HTTP/status/DNS
regressions. Logs/results are retained locally under
`/private/tmp/conduit-runtime-stage1-20261024/runtime-replacement-full-gates`.

The earlier immutable ff7dc2a run also passed 39 checks before review refinements;
it is archived separately. Independent Claude review checked classification,
read bounds and cleanup, and prompted the corrected error taxonomy/comment.
Its initial traversal concern was withdrawn after verifying internal initializer
access and the sole canonical-layout production constructor. Codex checked the
corrected mapping, synthetic witnesses and actual final workflow evidence.
Implementation and both Claude reviews used the owner's claude.ai Max subscription;
API credentials were disabled. No serving app/helper was stopped or installed,
and no VPN access was needed. Hosted CI and release readiness are not inferred.

Sidecar policy is now selected separately in 0026 on the parallel implementation
branch; it is not added by this runtime-only primitive. The sole writer/store,
client engine, AppState adoption and runtime isolation remain open.
