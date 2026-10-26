# Candidate runtime service profile: test-only evidence (2026-10-25)

Identity: this is the runtime-service-profile experiment, the test-only evidence for the candidate profile. It is not the earlier display
probe in `docs/experiments/runtime-display-codec`, and it is not the earlier checkpoint whose 11-failure display run belongs to that probe.
Those records are not edited here. This experiment's only failing run is attempt 1, below.

TEST-ONLY evidence for a coherent candidate profile, gathered before the owner selects one. Nothing here is a shipping default.
No admission, config acceptance, product value, host, store or Start/API wire changes. The candidate is built through the actual
`RuntimeServiceLimits` initializer, which is the only judge of its bounds. Its refusals would be reported, never clamped. None
happened: the candidate constructs.

Owner-selected values this profile follows: 64 KiB reply and stream frames (decision 0030). The private 8 MiB configuration channel
and v1 are unchanged. The display policy (decision 0029) is measured through the actual projection and is not copied here.

## Files

- `Tests/ConduitTests/RuntimeServiceProfileEvidenceTests.swift`: construction and refusal boundaries of the candidate, every current call's
  request frame at its widest legal form, and 64 KiB page packing through the actual `ControlPagePacker` and codec. It also holds the shared
  candidate builder and kernel fixtures (typical, mixed-escape, all-NUL).
- `Tests/ConduitTests/RuntimeServiceProfileProjectionTests.swift`: the actual projection at typical scale, count and byte bounds for connection
  rows, the byte boundary for mixed-escape and all-NUL rows, and two resource probes (projection-only on a retained kernel, and construction-only).
- `Tests/ConduitTests/RuntimeServiceProfilePressureTests.swift`: capacity, Stop and status pressure through the production transport under the
  candidate lanes, plus the ninth subscription through the public framed client. Counts only, no timeouts.
- `known-event-inventory.md`: read-only inventory of event families, with finite-cap and loss-free-bound kept distinct.
- `results/stdout-excerpt-run1.txt`: the first run's failing output, kept verbatim.
- `results/stdout-excerpt-run2.txt`: the run-2 output, verbatim, grouped by test (before the sanitizer change).
- `results/stdout-excerpt-run4.txt`: the run-4 output after the sanitizer change, verbatim, with the comparison basis.
- `results/stdout-excerpt-pass7.txt`: the current pass-7 output, verbatim.
- `kernel-sanitizer-release/`: the parent's standalone Release probe of the direct sanitizer before and after the change. Its README gives
  the method and limits. It is linked here and is not part of this experiment's code or claims.

## Running resource diagnostics

The two log-only process-memory probes are opt-in. They measure Debug XCTest
process observations and assert no memory budget; ordinary tests retain all
projection, count/byte/frame bounds and pressure assertions.

```sh
CONDUIT_RUNTIME_RESOURCE_PROBES=1 DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcrun swift test --filter 'RuntimeServiceProfileProjectionTests.testProjectionOnARetainedKernelIsSampledWithoutACallerPool|RuntimeServiceProfileProjectionTests.testFreshKernelConstructionAloneIsSampledForComparison'
```

Historical results below describe their original explicit runs. They are not
installed-app memory measurements or shipping profile selections.

## Candidate values (as passed to `RuntimeServiceLimits`)

| Bound | Value | Bound | Value |
| --- | --- | --- | --- |
| `maxRequestBytes` | 4,096 | `ringCapacity` / `ringByteCapacity` | 512 / 1,048,576 B |
| `maxReplyBytes` | 65,536 | `maxEventBytes` | 8,192 B (**provisional**) |
| alias count / bytes per partition | 64 / 16,384 B | `ingressCapacity` / `ingressByteCapacity` | 64 / 262,144 B |
| `ordinaryPendingCapacity` | 8 | `drainItemsPerTurn` / `drainBytesPerTurn` | 16 / 65,536 B |
| `outcomeCapacity` / `outcomeByteCapacity` | 128 / 262,144 B | `controlLogCapacity` / bytes | 128 / 262,144 B |
| `retentionAge` / `janitorBatch` | 60 s / 16 | `replayChunkItems` / `replayChunkBytes` | 32 / 32,768 B |
| ordinary / read / stream lanes | 8 / 8 / 8 | `collectionRowCapacity` | 10,000 (capture count, not a connection limit) |
| `stopLaneCapacityPerModule` | 2 | `collectionByteCapacity` (per capture) | 8,388,608 B (**provisional**) |
| `subscriberLimit` | 8 | `collectionRetainedByteCapacity` | 16,777,216 B |
| `subscriberRecordBytes` | 80 (`MemoryLayout<RuntimeSubscriberRecord>.size`, read through `@testable`) | proof cap / row revisions per kind / row retention | 8 / 2 / 60 s |
| `latestSnapshotByteCapacity` | 57,344 B | `retainedByteCeiling` (aggregate) | 33,554,432 B |

The constructor derives the rest: `laneCount` 30 (8+8+8+2×3 modules), `operationCapacity` 14, the alias, operation, proof and lane totals,
and `retainedByteBudget` 31,942,548 B, which is 1,611,884 B under the ceiling.

## Verification status

- **Pass 7 (current, exit 0).** The exact wrapper, with a 180 s bound, passed: 68 filtered tests executed, 0 failures, and the event catalogue
  check passed (218 names). Output is in `results/stdout-excerpt-pass7.txt`. The current source and test tree is the one this pass ran.
- **Aborted attempts 5 and 6 (not passes).** Both stopped in the ninth-subscription test. Attempt 5 was initially suspected to stall in teardown; the parent
  sampled and terminated its task-owned XCTest process. Source inspection later
  located the earlier stream-opening ordering defect described below. Its sample is archived at `runtime-profile-checks-attempt5/stall-sample.txt`. Attempt 6 stopped
  in the same test after the teardown fix. Its logs are archived as attempt 6. Diagnosis: `parkStreamPulls` started each stream's pull in the same
  loop as the next stream's open. The next open then waited behind a queued pull, which the manual scheduler could not drain before the open's own
  await. That is a test-helper ordering defect, not a product defect. Pass 7 opens every stream first and starts the pulls afterwards. Teardown
  also changed: it cancels unfinished tasks first, releases stream registrations, pumps the owner in a bounded wait, and awaits only tasks that
  recorded their end. The launch classification changed too. A rejected admission is a host failure with its code, and an accepted or joined
  admission is an answer.
- **Run 4 (exit 0, superseded by pass 7; kept for provenance).** The exact wrapper, with the sanitizer change in `sanitize`, passed: 68 filtered tests executed, 0 failures.
  The event catalogue check passed. Output is in `results/stdout-excerpt-run4.txt`. Earlier logs are archived as attempts 1 to 3. Attempt 3
  was the `observableTarget`-only pool, which is not the approved location.

- **Run 1 (failed, preserved).** The filtered run reported one failure: the ninth subscription returned a stream without throwing at open. The
  test expected a refusal, and its assertion was wrong. Its logs are archived as `runtime-profile-checks-attempt1`, and the failing output is
  in `results/stdout-excerpt-run1.txt`.
- **Run 2 (exit 0, superseded by pass 7).** The exact wrapper passed end to end: build; 15 filtered tests executed, 0 failures (Evidence 5, Projection 6,
  Pressure 4); import check, event catalogue check (218 names) and decision check PASS; `pm-sim` service and display scenarios completed.
  Output is in `results/stdout-excerpt-run2.txt`.
- These results describe the measurement checkpoint based on `1d3a129`; the experiment and service foundations are now merged. The candidate remains test-only. See [the current roadmap](../../../ROADMAP.md) for integration and shipping status.

## Repairs between run 1 and run 2

1. **Ninth subscription through the public client.** `makeFramedRuntimeClient` opens the stream and `subscription.next` is asserted to throw
   exactly `RuntimeClientError.wire(.subscriberLimit)` at the first pull. The open itself returns a stream, because the transport answers the
   refusal as the stream's first frame (`RuntimeServiceCore.openSubscription` → `openOutcome(.response(.failure))`). The eight parked pulls and
   the subscriber count are unchanged.
2. **Resource probe separated.** The projection-only probe holds one retained 1,000-connection kernel and rebuilds nothing per iteration. A
   separate construction-only probe builds and releases the kernel each iteration, and projects nothing. The 101-capture extension is gated on
   the projection-only probe being flat (under 1 MiB across the first eleven).
3. **Strongest string-field row added.** The former rotated fixture is now called *mixed-escape* and is not a maximum. A new *all-NUL* fixture
   puts a 1,025-byte NUL run in each of the four displayed connection text fields, with `Int.max` byte counts. It runs through the kernel,
   the Bridge projection, the byte-bounded capture, and the packer. The fit count is derived as the byte cap divided by the one row size, and
   measured by search. The NUL escape is checked in the encoded row.
4. **Comments corrected.** The fixtures call 1,025 bytes "over" each 512-byte cap, not "one past" it. This is a comment-only change.

## Measured in run 2

**Construction and budget.** The candidate constructs. The constructor accepts exactly its budget and refuses one byte less. It also
refuses a subscriber charge one byte under the measured record. Derived values: `admissionWorstBytes=70`, `requestIDWorstBytes=38`,
`fingerprintBytes=32`, `aliasRecordWorstBytes=140`, `operationRecordBytes=38`, `laneRetainedBytes=4,177,920`,
`firstFrameRetainedBytes=524,288`, `snapshotRetainedBytes=114,688`, `subscriberRecordRetainedBytes=640`, `collectionProofBytes=24`,
`baselineFrameOverheadBytes=303`.

**Request frames, widest legal form, against the 4,096 B request cap.** Every current call fits. The largest is `submit-test-upstream` at
389 B. The rest are 135 to 340 B.

**64 KiB pages through the actual packer.**

| Sample | Rows | Pages | First page rows | Largest frame (B) |
| --- | ---: | ---: | ---: | ---: |
| typical | 1,000 | 5 | 217 | 65,256 |
| mixed-escape | 64 | 7 | 10 | 62,474 |
| all-NUL | 64 | 13 | 5 | 64,169 |

**Encoded-row boundary at the 8 MiB collection cap** (through kernel, Bridge, byte-bounded capture and packer):

| Shape | Row bytes | Largest fit | First refused | Encoded total at fit (B) | Derived fit (cap ÷ row) |
| --- | ---: | ---: | ---: | ---: | ---: |
| all-NUL (strongest string-field shape measured) | 12,768 (all equal) | **657** | 658 | 8,388,576 | 657 |
| mixed-escape (not maximum) | 6,214 (all equal) | 1,349 | 1,350 | 8,382,686 | — |

(The run-2 log prints the label `all-nul encoded-maximum`. That label predates this qualification, and the claim is now the one in finding 3.)
The all-NUL fit matches the derived count exactly, and it lands near the brief's ~660 expectation. The mixed-escape figure is not a
maximum and should not be used as one. The all-NUL shape is the strongest string-field shape this run measured, not a universal maximum.

**Typical connections** (Debug XCTest process; elapsed times are observations, not deadlines):

| Connections | Encoded total (B) | Row bytes mean / p95 / max | 64 KiB pages | Largest frame (B) | Projection elapsed |
| ---: | ---: | --- | ---: | ---: | --- |
| 1 | 268 | 268 / 268 / 268 | 1 | 551 | 0.09 ms |
| 64 | 18,820 | 294 / 304 / 304 | 1 | 19,167 | 4.2 ms |
| 256 | 75,817 | 296 / 306 / 307 | 2 | 65,206 | 17.2 ms |
| 1,000 | 297,676 | 297 / 307 / 308 | 5 | 65,256 | 67.1 ms |
| 10,000 | 3,006,968 | 300 / 310 / 311 | 47 | 65,314 | 642.0 ms |

The projection's total equals the sum of its rows' encodings at every count. The 10,001st typical connection is refused whole by count.

**Pressure under the candidate lanes** (production transport, manual owner hops):
- Ordinary flood of 12 with 8 lanes: 8 answered and 4 refused, with or without a full stream lane (8 streams held).
- All three module Stops answered, with or without a full stream lane.
- Status reads of 12: 8 answered and 4 refused, with or without a full stream lane.
- Dns Stop lane: 3 attempts gave 2 answered and 1 refused. The other two modules' Stops answered.
- Ninth subscription: refused as `RuntimeClientError.wire(.subscriberLimit)` at its first pull. The subscriber count stayed at 8.
- Event flood: after 600 drained events, the ring kept positions from 89 on. A further 100 undrained events gave high water 665, one loss
  marker past the 64-slot ingress. After 40 snapshot changes the generation was 40, at 1,330 B against a 57,344 B bound. A Stop was admitted.

**Resource probes** (log-only observations, test process, Debug, no caller autorelease pool; malloc in-use from `malloc_zone_statistics` with a nil zone, which the SDK header defines as all zones). Nothing asserts on these figures. The 1 MiB value is an observation gate that decides whether the retained-kernel probe extends to 101 captures, not a pass or memory claim:

| Probe | Before first (B) | Iteration 1 (B) | Iteration 11 (B) | Growth, iteration 1 to 11 (B) (the gate) | Extended to 101 |
| --- | ---: | ---: | ---: | ---: | --- |
| construction only, fresh 1,000-connection kernel each capture | 1,826,784 | 2,576,720 | 10,108,944 | **7,532,224** | not run (not flat) |
| projection only, retained kernel, projection plus packing | 2,882,208 | 2,882,272 | 2,883,488 | **1,216** | yes; iteration 101 at 2,883,552 |

Growth is measured from iteration 1, which is the gate's own definition. The baseline column is the sample before the first capture, so it
is not part of the growth figure. The two probes ran in one process in alphabetical test order, construction first.

The construction probe ran first. Its growth was released by the time it returned: the projection probe's baseline is 2,882,208 B, below the
construction probe's last sample. Peak RSS rose to about 124 MB during the construction probe and to about 216 MB by the projection probe. It is
a monotone process high-water and does not show the in-use growth.

## Findings

1. **The earlier 7.5 MB growth is in fresh kernel construction, not in projection or packing.** Construction alone reproduces the growth in run 1
   (7,532,224 B against 7,531,584 B earlier). The projection probe, on the same kernel size and with the kernel held, is flat (1,216 B over 11 captures,
   and about 1.3 KB over 101). That run isolated construction but did not prove the function-level cause. The
   subsequent correction and direct Release control are recorded below.
2. **The growth is released after its test returns, which is consistent with deferred release.** The in-use bytes fell from 10,108,944 to 2,882,208
   once the construction test ended. That pattern fits autorelease-style or test-scoped deferred release better than a monotone leak. It does not
   prove the mechanism.
3. **The largest row measured here is about 12.8 KB, against the mixed fixture's 6.2 KB.** It is the strongest string-field shape this run
   exercised: four NUL runs over the cap, with `Int.max` byte counts. It is not a universal per-row maximum. Other scalar encodings were not
   exercised: the timestamps are fixed values, the UUIDs are fixed width, no finite-Double extreme is encoded, and no other field shape was run. Under the 8 MiB collection cap, this row limits a capture to
   657 rows. A 10,000-row capture of worst rows is refused whole by its byte bound, as designed.
4. **The 8 MiB collection cap is provisional.** Typical rows at about 300 B are far below it. Worst rows reach it at about 657 rows. Whether that is
   acceptable is the owner's decision; this stage gives no recommendation.
5. **Event size is not proven.** The legacy `ControlRuntimeEvent.detail` has no finite bound at its type. The 8 KiB `maxEventBytes` is a finite cap with
   explicit loss, not a loss-free bound. See `known-event-inventory.md`.
6. **`task_info` residency is not sampled here.** The test target is Swift 6, and the imported `mach_task_self_` global is a concurrency diagnostic.

## Construction-growth correction: implemented in `sanitize`, measured in run 4

The Debug comparison alone is trace-supported rather than a function-level control. `ActiveConnectionInfo.init` (`ProxyKernel/Models/ProxyStatus.swift:147`) sets
`destination = SensitiveValueSanitizer.observableTarget(destination)`, and no other sanitized field. `observableTarget` is the one-line
delegate `sanitize(redactSuffix(value))`. `sanitize` calls four `NSRegularExpression` operations, and `URLComponents` for URL matches. Those
calls create Objective-C temporaries, and the probe loop has no pool to drain them. The construction probe grows, and the projection probe on a
retained kernel does not, which fits that path.

Change (`ProxyKernel/Support/SensitiveValueSanitizer.swift`): `sanitize` returns early for an empty value, then runs the one private
implementation, `sanitizeContent`, inside a synchronous `autoreleasepool` under `#if canImport(ObjectiveC)`. Other platforms call it
directly. `observableTarget` is unchanged, so every entry point that reaches `sanitize` gets the same scope, including the direct RuntimeEvent
and log callers. The result is the same ordinary Swift `String`, so no copy, access, import, or output changes.

Measured, from one wrapper pass (`results/stdout-excerpt-run4.txt`):
- Construction probe, iteration 1 to 11: growth 1,216 B. Run 2 without the fix measured 7,532,224 B.
- Projection probe, iteration 1 to 11: growth 1,216 B, flat. It extended to 101 captures, ending at 5,530,832 B.
- Output contracts: `ObservableTargetRedactionTests` (4), `ConnectFailureEventTests` (9), `AuditRegressionTests` (16), and
  `RuntimeEventTypedTests` (24) passed. `pm-sim` service and display scenarios and the event catalogue check passed.

Limits on the comparison. The run-2 baseline came from a 15-test process, and run 4 from a 68-test process that runs the sanitizer tests first.
The construction baseline moved from 1.8 MB to 5.2 MB. No same-filter run without the fix exists, so the 7.5 MB to 1.2 KB change mixes the fix
with the process state. This Debug comparison alone is not a function-level control. The separate
[direct Release before/after probe](kernel-sanitizer-release/README.md) runs the
actual pinned baseline and corrected sanitizer on identical short inputs without
a caller pool: all four baseline cases grow, and all four corrected cases stay
flat through 101 batches with matching output checksums. Its reproduction was
also run successfully. That supplies the narrower function-level lifetime evidence;
it does not establish steady-state app RAM or a universal allocation bound. The `pm-sim` `ObservableTargetScenarios`
was not part of the wrapper pass. The full 40-step workflow and performance gates are not run here.
An earlier pass that put the pool only in `observableTarget` (attempt 3) is archived. It is not the approved location and is not the result above.

## Limits of this evidence

- Debug XCTest process, one Mac, one run. Times are single observations, not percentiles or deadlines.
- Growth is malloc in-use, not RSS or app memory. No steady-state app memory claim is made.
- Rows in the mixed fixture share bodies, so summed per-row bytes do not equal physical memory. The all-NUL body is shared too.
- Future Start and private workflow payloads are not on the current wire and were not measured.
- Pressure counts come from the production transport and manual hops. The actual host's Stop and status latency, and its scheduling, were not measured.
- Known-event coverage is inventory only. No bounded typed-lifecycle fixture has run through the Bridge or ingress yet.
