# Runtime service engine: checkpoint (2026-10-25)

Status: **combined local integration, verification pending.** The retained-page/service foundation (5920ae6 plus its evidence) and observation/replay work (d963333) are combined over merged PR234. Earlier counts below identify their separate checkpoints. The combined source needs focused checks, independent review and all-workflow gates. The service is unadopted: no RuntimeHost command owner or AppState client uses it. Display-text policy awaits the owner; no shipping resource values are chosen.

Branch: `codex/runtime-service-engine`, based on `ff7d859` over merged PR232. Local checkpoint; nothing pushed or installed. Source identity and parent verification are in [the verification note](verification-runtime-service-pages-2026-10-25.md).

## Verification record

- Latest run: the exact wrapper `bash /private/tmp/conduit-runtime-stage1-20261024/verify-runtime-service.sh` printed `PASS: runtime-service focused checks; logs under /private/tmp/conduit-runtime-stage1-20261024/runtime-service-checks`. Its filter selects `RuntimeCollection|RuntimeRowBudget|RuntimeService|ControlService|AdmissionLedger|Subscription|Replay|ControlTransport|ControlCollectionRetention|FramedRuntimeClient|RuntimeClient|ControlRuntime|RuntimeSnapshotProjection`.
- Filtered `swift test`: **267 tests, 0 failures** (fresh `tests.log`, after the review fixes below). The parent's run before those fixes was 262. The checkpoint before that ran 240, so the earlier net change was +22. `RuntimeCollectionLedgerTests` now runs 32 tests, and `RuntimeServiceTransportTests` runs 12.
- The build and the test logs contain no warnings. The two unnecessary `try` warnings in `ScenarioRuntimeServiceWire.swift`, which this slice owns, were removed.
- Imports fence, event catalogue (207 names), decisions check, decisions tests, `pm-sim framed-runtime-client` and `pm-sim runtime-service-wire` all pass under `set -e`.
- **Parent source-variant runs followed this worker checkpoint.** The gate probe detected under-lock release; a restricted-kind scan hit a production invariant; a reversed eviction tie-break produced a three-action model counterexample. All original source bytes were restored. Exact provenance and limitations are in [the verification note](verification-runtime-service-pages-2026-10-25.md). No historical-commit fail-before claim is made.
- Not run in this slice: the full `swift.yml` workflow, `pm-sim all`, `scripts/perf-gate.sh`, and any review gate. The parent's independent recheck and final review follow.

## M2B observation slice (local, 2026-10-25)

Built on `53a050e`, which includes the retained-page foundation. Source is frozen for parent review. Nothing is committed, pushed or installed. The parent's base fixes are now integrated; their separate evidence is retained below.

### What changed

- `RuntimeSubscriptionTable.swift` (new): the subscriber records, each with its cursor and its one parked wait, the subscriber limit, and exactly-once removal. A removal returns the held wait, and the caller wakes it after the mutation. The buffered first frame stays in `RuntimeStreamHandle` and is not copied here.
- `RuntimeSnapshotSlot.swift` (new): one latest safe snapshot, its measured encoded size, and a private delivery generation that starts at zero. Exhaustion is checked first. Once the slot is sticky, every offer is refused, including one equal to the held state, so an owner that returns the held value cannot recover it. An offer is measured before it is retained. An equal snapshot advances nothing. A different body under the same presentation revision is `conflict`. A lower revision is `regressed`. An incarnation mismatch, an unencodable snapshot and an over-bound snapshot are refused with a closed fault, and nothing is retained. When the generation cannot advance, the slot is sticky: each subscriber ends with `resyncRequired`, and an open or a read fails as `internalFailure`.
- `RuntimeServiceCore.swift`: `ownerDidChange()` captures `owner.snapshot()` once in the owner turn and offers it to the slot. A subscribe and a `readSnapshot` capture the same way, so a baseline is the owner's state in its own turn. `peekFrame` alternates one coalesced snapshot with the ordered log frames while live, and it sends no snapshot during replay. The snapshot generation and the alternation bit are committed with the observation cursor, and only when the wait gate wins.
- `RuntimeInMemoryTransport.swift`: a snapshot read answers `internalFailure`, or `frameTooLarge` when the snapshot does not fit the caller's frame. A baseline that does not fit is a typed `frameTooLarge` first frame, and its subscriber is released. Neither is reported as an invalid reply or as a disconnect.
- `ControlCommandOwner.swift`: four closed faults are added: `snapshotNotEncodable`, `snapshotOverBound`, `snapshotRevisionConflict` and `snapshotRevisionRegressed`. An incarnation mismatch reuses `snapshotIncarnationMismatch`.
- `RuntimeObservationLog.swift`: `RuntimeSubscriberCursor` gains `seenSnapshotGeneration` and `lastWasSnapshot`.
- `RuntimeServiceLimits.swift`: two new explicit inputs. `latestSnapshotByteCapacity` is a payload bound. `subscriberRecordBytes` is an in-memory charge per subscriber, and it is labelled as such. The derived terms are `baselineFrameOverheadBytes` (measured), `snapshotRetainedBytes = 2 × latestSnapshotByteCapacity` (the held snapshot plus one refresh scratch) and `subscriberRecordRetainedBytes = subscriberLimit × subscriberRecordBytes`. Both enter the checked budget, which is the encoded payload plus these in-memory charges. The subscriber charge is not an encoded size.
- No Shared wire change. `ControlRuntimeFrame.snapshot` is used as it exists.
- `pm-sim runtime-service-wire`: five Shared assertions are added, for the resync end, the refused baseline, the internal failure and the `frame_too_large` code. There is no runtime import.

### Limits derivation

- The baseline overhead is measured with the codec at the worst cursor (`RuntimeObservationLog.maximumPosition`), with the widest replay range `(from, through)` equal to it. The snapshot inside the frame encodes to the same bytes as standalone, so the overhead is the frame metadata alone. Measured: **303 B**. The same overhead for a live baseline is 226 B, and the difference is the cursor digits and the replay range.
- The constructor refuses unless `maxReplyBytes ≥ latestSnapshotByteCapacity + baselineFrameOverheadBytes` and `subscriberRecordBytes ≥ MemoryLayout<RuntimeSubscriberRecord>.size`. The record size is a conservative in-memory stand-in charged into the checked budget beside the encoded payload, and nothing is claimed about its encoded size.
- The event boundary is split. `testAMaximalEventFrameHasAnExactRawCodecBoundary` checks the codec alone: the exact size encodes, and one byte less fails. `testTheServiceReplyCapIsTheExactBoundOfItsLargerTerm` uses a coherent service profile, where the snapshot bound is the largest one the event term allows. Both terms then meet at one exact cap, and each side is decided by construction.
- A caller's narrower cap can still refuse a baseline or a snapshot read as `frameTooLarge`. Not every tiny caller limit is promised to work.

### Sizing evidence (printed by `RuntimeServiceSizingEvidenceTests`, no threshold)

| sample | profile UTF-8 bytes | snapshot payload | snapshot frame + LF | baseline frame + LF |
| --- | ---: | ---: | ---: | ---: |
| empty profile | 0 | 1305 | 1426 | 1531 |
| plain profile `Corp` | 4 | 1309 | 1430 | 1535 |
| `"\` repeated 64 times | 128 | 1561 | 1682 | 1787 |

These are samples, not maxima. The projection's text bounds are not exercised, NUL and control characters are not measured, and no fully populated maximal profile has been built.

### Tests and models

- `RuntimeServiceObservationTests` (19, including the ingress loss and the sticky-exhaustion regression): the baseline captures a silent owner change, coalescing, an identical state, the conflict, regression, incarnation and oversize faults, generation exhaustion, exactly-once removal with one wake, the subscriber limit, an uncommitted pull, alternation under a flood, one kind delivered alone, two subscribers at different generations, replay before any snapshot, a refused baseline over a narrow caller frame, a framed snapshot read, and a full read lane that leaves the stop and ordinary lanes reservable.
- `RuntimeServiceObservationModelTests` (2): an independent bounded array model of the live rules is driven against the production core. It runs on every sequence of depth 1 to 4 over nine actions (**7,380 sequences**, shortest counterexample first), and on **100 seeded SplitMix64 walks** of 25 actions (seeds 1 to 100). Publication stops at 12 events, so the ring never evicts. There are two subscriber slots and batches of four. It does not cover replay, control outcomes, gaps, wait gates or the transport. Both pass. No source mutant of these rules was run, so the pass is not sensitivity evidence.
- `RuntimeServiceSubscriptionTableTests` (8): table opening and its limit, exactly-once removal, one wait per subscriber with token-checked release, taking the waits, absent commits, and the slot's refusal order with unchanged state, replacement with verbatim stamps, and exhaustion stickiness.
- `RuntimeServiceWorkTests`: the exact-sum budget now includes the two new terms. The event boundary split is described above.

### Verification record

- `bash /private/tmp/conduit-runtime-stage1-20261024/verify-runtime-observation.sh` printed `PASS: runtime-service focused checks`, under `runtime-observation-checks/`.
- Filtered `swift test`: **293 tests, 0 failures**. The branch base ran 262, so 31 are new.
- Both `pm-sim` scenarios pass: `runtime-service-wire` (17 passing assertions) and `framed-runtime-client` (10). The import fence, event catalogue, decisions check and decisions tests pass under the wrapper.
- Not run: the full `swift.yml`, `pm-sim all`, `scripts/perf-gate.sh` and any review gate.

### Gaps, exact

1. Ingress preflight, partly done. `ingest` refuses an event whose own text (kind, event and detail, in UTF-8 bytes) already exceeds `maxEventBytes`, as a loss, before any encoding. A JSON string encodes to at least its UTF-8 bytes, so that sum is a sound lower bound. An event under the text bound is still encoded in full, since the encoded size is what the ring and queue count. Its `typed` field is not part of the bound, and no allocation has been measured.
2. The sizing is not a maximum, as stated above.
3. The exact `readSnapshot` contract. `ControlRuntimeCall.readSnapshot` has no payload and no expected incarnation, and the request was never given one. The read answers the owner's current snapshot after one capture in its own turn, or `internalFailure`. It never answers `changedIncarnation`, and no wire policy was added. A snapshot that does not fit the caller's frame is `frameTooLarge`.
4. A snapshot that does not fit a caller's narrower frame ends the stream with `resyncRequired`. The end is explicit and nothing is skipped silently. It is a policy choice for the parent.
5. Replay, control-log, gap and eviction rules are modelled at the log level (`RuntimeServiceReplayModelTests`, below) and exercised through the core (`RuntimeServiceReplayTests`). The model is written from the design, but in the same work as the production rule, so it is not an independent specification of the protocol. No source mutant of these rules has been run.
5a. Populated sizing and fake-owner pressure metrics are measured (section M2C, below). Not done: a Bridge-capped text profile, because the Bridge does not cap free text, and any shipping profile.
6. No source mutant was run against the table, the slot or the alternation rule.
7. Custody, corrected. The subscription table stores each subscriber's cursors and at most one parked wait, and it holds no snapshot. The latest snapshot is held once, in the slot. The per-subscriber first frame is budgeted in the existing baseline term and is not part of M2B's new state. No per-subscriber snapshot custody is claimed or measured.
8. The base-53 page-path concerns are not handled here. `captureCurrent` and `pageSource` are unchanged, and the current-proof total invariant after row aging and release, the invariant branch that must not claim over-budget, and the page reply fallback classification are left to the parent's base fix. The new snapshot and open paths classify their own failures as closed faults and typed refusals, not as over-budget or as disconnect.
9. Host adoption, the production v2 socket, the owner adapter in the actual host, and any shipping profile are still open.

## M2C replay, populated sizing and pressure metrics (local, 2026-10-25)

Built on the M2B source. Verified by the exact wrapper: **305 filtered tests, 0 failures**, and both pm-sim scenarios pass. The M2B counts above are superseded by this run.

### A defect found and fixed

- A replay started its outcome cursor at the live `controlNext`. So an outcome that finished inside the replay's range was never delivered. `RuntimeObservationLog.controlStart(forEvent:)` now chooses the first retained outcome whose boundary is at or after the replay start. If an evicted outcome may have been in that range, it returns nil. The replay is then refused at the baseline as `expiredHistory`, which is conservative and explicit.
- Every frame kind is now checked against the caller's `fits`. Before, only events were. An outcome or a caught-up mark that does not fit ends the reader as `resyncRequired`, and the cursor does not move. A stream end that does not fit is an `invalidReply`, once. No refusal is substituted, since a `frameTooLarge` refusal is never larger than an end (both are 139 bytes for `resyncRequired`).
- No wire witness of "baseline fits, then an outcome does not" can be built from real values. The smallest baseline measured is 1,531 B. I did not measure a real outcome against it, and the largest outcome shape is a bounded enum list. The rule is therefore witnessed at the log level (`testAnOutcomeThatDoesNotFitEndsTheReaderWithoutConsumingIt`), and not on the wire.

### Replay model (`RuntimeServiceReplayModelTests`)

- The reference model is an array model. Positions are events or losses, the ring keeps the newest `ringCapacity` positions, and the outcome log keeps the newest `controlCapacity` entries. Its readers, deliveries and refusals are written from the rules, not from production code.
- It runs against `RuntimeObservationLog` directly, with a ring of 3, an outcome log of 2 and chunks of 2. Each step compares every pull, the retained window and the outcome window.
- **Exhaustive**: every sequence of depth 1 to 5 over seven actions (event, loss, outcome, open live, open replay, and pull on each of two slots): **19,607 sequences**, shortest counterexample first.
- **Seeded walks**: **200** SplitMix64 walks of 40 actions (seeds 1 to 200).
- Both pass. No source mutant was run.

### Core replay tests (`RuntimeServiceReplayTests`, 6)

- A replay delivers each outcome after the events it follows, then the caught-up mark.
- Event eviction during a catch-up ends with a resync, and a later replay from before the ring is refused as expired history.
- Outcome eviction during a catch-up ends with a resync.
- A replay that may have lost an outcome is refused at the baseline as expired history.
- A replay across a loss is refused as `observationLoss`, and a replay after the loss is clean.
- A stream end that does not fit is an invalid reply, once, and a fitting end is the reply.

### Service pressure metrics (`RuntimeServicePressureMetricsTests`, fake owner)

The owner is stalled, so hops are queued. Lane reservations and answers are counted. The read lane is held as parked stream pulls would hold it, with reservations, so this is an emulation.

| row | ordinary answered/attempted | Stop modules answered | status answered/attempted |
| --- | --- | --- | --- |
| ordinary flood | 2 / 6 (4 refused) | 3 / 3 | 2 / 4 |
| ordinary flood, read lane held | 2 / 6 (4 refused) | 3 / 3 | **0 / 4** |

- **Finding, resolved in M2D below.** Streams and status reads shared the `.read` lane, so a full stream lane refused every status read. M2D gives stream pulls their own lane.
- Event and snapshot floods: 40 events, each drained, give a high-water mark of 40 and a first retained position of 25 (ring of 16). A flood of 20 more events with no drain collapses into one loss marker past the ingress capacity of 8, and the high-water mark becomes 49. Forty snapshot changes give generation 40, and the held snapshot is 1,310 B. A Stop is admitted during both floods.
- No latency is asserted. The metrics are counts only, and no RSS or steady-state claim is made.

### Populated sizing through the Bridge (`RuntimeServiceSizingEvidenceTests`)

Eight free-text fields (profile, active upstream, health summary, proxy error, DNS error, tunnel error, VPN interface, and auth fallback reason) hold the same 513 bytes of raw text. Counters and revisions are `Int.max`, and the sample passes through `RuntimeSnapshotControlProjection`.

| sample | snapshot payload | snapshot frame + LF | worst baseline frame + LF |
| --- | ---: | ---: | ---: |
| escaped: quote, backslash, NUL, 2-byte and 4-byte characters | 8,890 | 9,011 | 9,193 |
| plain ASCII, same raw length | 5,698 | 5,819 | 6,001 |

- Escaping adds 3,192 B to the payload on the same raw length.
- **The Bridge does not cap free text.** It sanitizes text and does not truncate it. So the snapshot bound depends on what the owner puts in those fields, and a shipping bound needs an owner-set text policy. The 8 × 513 B sample is a caller-chosen length, not a bound.
- The worst baseline equals the populated payload plus the measured 303 B overhead, which agrees with the constructor.

### Open after M2C

- Lane partition for status against streams (above). This is a parent decision.
- A Bridge-capped text policy, and any shipping profile.
- A source mutant of the replay and table rules.
- Integration with the PRIMARY base fixes, which the parent will do.

## M2D stream lane, end classification, real outcome witness and text inventory (local, 2026-10-25)

Verified by the exact wrapper: **309 filtered tests, 0 failures**, and both pm-sim scenarios pass. The decision record check passes. The source is frozen at this run.

### Stream lane

- `RuntimeLane.stream` is new. Each stream pull reserves it, and each pull holds one reservation until its wait ends. Lookups, pages, status reads and subscription opens stay on `.read`. Stop keeps one lane per module, and ordinary commands keep theirs.
- `RuntimeServiceLimits.streamLaneCapacity` is an explicit constructor input. It is counted in `laneCount` and in `laneRetainedBytes`, so the checked aggregate covers it. No shipping value is chosen. The fixture uses 2.
- The physical cleanup is unchanged: timer, hop and waiter parts still hold the reservation until they end.
- Witnesses through the production transport (`RuntimeServicePressureMetricsTests`). Two real stream subscriptions park a pull each, holding both stream-lane reservations.

| row | streams held | ordinary answered/attempted | Stop modules answered | status answered/attempted |
| --- | ---: | ---: | ---: | ---: |
| ordinary flood | 0 | 2 / 6 | 3 / 3 | 2 / 4 |
| ordinary flood, stream lane full | 2 | 2 / 6 | 3 / 3 | 2 / 4 |

- A third pull with the lane full is refused as `transportBusy`, and it ends no subscription (`testAPullBeyondTheStreamLaneIsBusyAndNonTerminal`). The earlier emulation with bare reservations is gone.
- Existing lifetime tests that measure stream pulls now measure `.stream`. The checks on generic waits and opens still measure `.read`.

### End classification

- A stream end that does not fit the caller's frame is a **bounded disconnect**, `failed(.sent(.disconnected))`, once. The subscription was already released. It is no longer `invalidReply`, and there is no refusal substitution or retry.
- This is a direct seam (`RuntimeInMemoryTransport.streamEndOutcome`), tested with measured sizes. The real wire cannot reach it with the same cap, because the baseline that opened the stream is always larger than an end.

### Real outcome witness (framed client, production transport)

- A real `ControlCompletion(.testUpstream, .upstreamProbe(ControlUpstreamProbe))` is built by the fake owner. The probe name is 400 × `"` and NUL, and the endpoint is 200 bytes.
- With a 2,048-byte caller frame, the baseline is delivered first, so it fits. The outcome does not fit, so the stream ends with `streamClosed(.resyncRequired)`, the subscription is released, and the outcome is still recoverable by lookup (`testAnOutcomeLargerThanTheCallersFrameEndsTheStreamAsAResyncAndTheOutcomeStaysRecoverable`).
- The same stream delivers a small probe, and it stays open (`testAnOutcomeThatFitsTheCallersFrameIsDeliveredOnTheSameStream`).
- The probe name and endpoint are not capped by the codec, which the witness shows. Nothing is measured beyond what the test asserts.

### Text inventory (no implementation; owner decision needed)

Current bounds on the ordinary v2 wire:

- `ControlDisplayText.bounded` sanitizes, then cuts at a character boundary. It is used only by `ControlUnknownEventDisplay`, at kind 64, event 128 and detail 512 bytes.
- The snapshot projection and every collection row call `ControlDisplayText.sanitize`, which is not capped.
- Known events carry their `kind`, `event` and `detail` uncapped. The only bound is the ingress `maxEventBytes` service limit, which has no shipping value.

Free-text fields on the wire, and their approved configuration bound (decision 0021, `DomainResourceLimits`):

| source | field | config bound |
| --- | --- | --- |
| snapshot | `profileName` | `displayText` 1,024 |
| snapshot | `activeUpstream` (an upstream name, if the kernel passes configured names) | not verified in this inventory |
| snapshot | `healthSummary`, `proxyError`, `dnsError`, `tunnelsError`, `lastAuthFallbackReason`, `vpnInterfaceName`, `tunnelDNSOverride.unavailableReason` | none (kernel or OS text) |
| upstream row, probe | `name` | `displayText` 1,024 at config |
| upstream row, probe | `endpoint` | `urlText` 16,384 when a URL, `DomainNameSyntax` for hosts |
| connection row | `destination`, `upstream`, `method`, `authMethod` | none for `method`/`destination` |
| tunnel binding row | `label` | `displayText` 1,024 |
| tunnel binding row | `localHost`, `remoteHost` | host syntax |
| DNS host row | `hostname` | `DomainNameSyntax` |
| known event | `kind`, `event`, `detail` | none beyond the ingress service limit |

Measured (`RUNTIME-SIZING-TEXT`, `profileName` through the Bridge, base payload 1,305 B):

| raw bytes | plain payload | quote/NUL payload (half and half) |
| ---: | ---: | ---: |
| 64 | 1,369 | 1,561 |
| 256 | 1,561 | 2,329 |
| 1,024 | 2,329 | 5,401 |

- Plain text costs exactly its raw length. A quote costs 2 encoded bytes and a NUL costs 6. The 1,024-byte mix is 4,096 encoded bytes.
- All-NUL, measured: 512 raw bytes encode to 4,377 − 1,305 = 3,072 bytes, and 1,024 raw bytes encode to 7,449 − 1,305 = 6,144 bytes. That is 6 encoded bytes per NUL.
- The eight-field sample covers eight scalar text fields only, at 513 raw bytes each. It encodes to 8,890 B. It is not a full maximum: the collection rows, the bindings and the tunnel DNS reason are absent. Eight 1,024-byte all-NUL fields would be 8 × 6,144 = 49,152 encoded bytes, which exceeds the 16 KiB fixture snapshot bound, so a bound decision is required.

Work and retention are different caps:

- `sanitize` is linear in the input, so the input's length is the work cap. The sanitizer must see the whole input before any cut, because a cut before redaction can leave half a credential or a URL query. So the input cap belongs at the producer, which is config for names and kernel code for diagnostics.
- Retention is the encoded size of the output. That is the cap the snapshot bound and the frame cap govern.

Earlier options, superseded by the policy follow-up below:

- **A. Cut by encoded length.** Bound each field's encoded JSON length, not its raw length, so the retention cap is exact. Recommended. It needs a per-field indicator for truncation.
- **B. Two tiers.** 1,024 encoded bytes for config-derived names, which the approved bound already covers. A smaller bound for kernel diagnostics and probe endpoints, for example 256 encoded bytes. Also recommended, combined with A.
- **C. Explicit refusal.** An oversize field makes the snapshot unavailable. Not recommended for daily use, because one long name would blank the status.
- **D. Leave uncapped.** The baseline would then exceed any fixed frame bound, and the failure would be `frameTooLarge` on open. Not acceptable as a default.

Indicator shape, which is a wire decision for the owner: a per-field `truncated` flag, one `truncated` flag on the snapshot, or silent cut with no indicator. Silent cut is not recommended, because the caller could not tell a cut name from a full one.

Triggers to revisit: a new free-text field; a change to `displayText` or `urlText`; a shipping snapshot bound; a shipping frame cap; any measured baseline above the bound.

### Policy follow-up (recommendation; no implementation; owner decision)

- **Units.** The approved configuration bounds are raw UTF-8 byte caps. `DomainResourceMeasure.utf8Bytes` measures `displayText` (1,024: profile, upstream and tunnel names), `urlText` (16,384) and `hostText` (`DomainNameSyntax.maxLength`). None of them bounds the encoded size. A raw 1,024-byte all-NUL name encodes to 6,144 bytes, measured. So a raw cap bounds input and configuration, while the wire retention needs a separate encoded budget.
- **Upstream endpoint source, traced.** `UpstreamProxy.endpoint` is `displayName`, which is `"\(host):\(port)"`. The host is the configured host, bounded by `hostText`, and the port is numeric. The status endpoint and the probe endpoint both come from it (`ConnectionPool` builds `UpstreamRuntimeStatus.endpoint`, and `RuntimeSnapshotControlProjection.upstreamRow` displays it). It is not a URL, and nothing here claims a 16 KiB bound for it.
- **Collection rows are already encoded-bounded.** `ControlRowBudget` measures each row by its encoded bytes against `collectionByteCapacity`, so an oversize row is refused, not cut. The gap is the scalar snapshot text, which has no bound at all.
- **Work before sanitization.** `sanitize` is linear in the input, and it must see the whole input before any cut, because a cut can leave half of a redacted URL. So the work bound belongs at the producer, not in the sanitizer. Recommended: if the raw input is over a producer cap, replace the whole field with a fixed redacted omission marker, and do not cut it. Only an input at or under the cap is sanitized and then cut with `ControlDisplayText.bounded`.
- **Options.**
  - R1, recommended. Raw caps: 1,024 for config-derived names (`displayText`), 512 for kernel diagnostics and endpoints. Oversize input becomes the omission marker. Encoded worst case per field is 6 × the raw cap, so a constructor check of the summed worst case is required. Tradeoff: it matches the approved display bound, and it keeps one cut policy. The worst case is 8 × 6,144 = 49,152 bytes if all eight fields are config-sized and all-NUL, so the snapshot bound must be sized for it, or the cap must drop.
  - R2, all raw 512. Worst case 8 × 3,072 = 24,576 bytes. Tradeoff: smaller, but config names lose half their approved length.
  - R3, cut by encoded length. Exact retention, but it needs a second cut algorithm, which the approved design does not use. Not recommended.
  - Refuse oversize snapshots (no truncation). Rejected: one long name would blank the status.
- **Indicator shape (a wire decision).** (a) A closed list of truncated or omitted field names on the snapshot, recommended: it says which field, and the list is fixed. (b) A single `textTruncated` flag: cheap, but it cannot say which field. (c) Marker text only: no wire change, but the marker is ambiguous with a real value. The owner chooses. Silent cut is not recommended.
- **Rough cost, R1 with (a).** Route each scalar text through the bounded helper, add the omission marker and the producer check, add the closed field list to the snapshot, and add the constructor's summed worst case. A few hundred lines and tests. The only public-shape change is the indicator.
- **Triggers to revisit.** A new free-text field; a change to `displayText`, `urlText` or `hostText`; a shipping snapshot bound or frame cap; a measured baseline above the chosen bound; the parent's adoption of the Bridge.

Nothing in this inventory is implemented. The Bridge and the rows are unchanged.

## Bounded model counts (fresh log)

- **Single-kind ledger model** (`testTheLedgerMatchesItsLogicalModelOnEveryBoundedSequenceAndSeededWalk`): 12 actions. Exhaustive depth 1 to 4, **22,620 sequences**, then **100 seeded walks** of 25 actions (SplitMix64, seeds 1 to 100). The test asserts `checked == 22,720`, and it passes. It covers one kind, uniform row sizes, a fixed janitor batch of 2 and fixed cursors. It never refuses a capture for the per-capture bound.
- **Cross-kind ledger model** (`testTheCrossKindLedgerMatchesItsModelOnEveryBoundedSequenceAndSeededWalk`): 16 actions. Two kinds (`upstreamHealth`, `tunnelDNSHosts`), two revisions per kind, three size classes (one, forty and three hundred characters), with the largest refused by the per-capture bound. Two advances (30 s and 60 s, which straddle the 60 s age) and janitor batches of 1 and 3. Exhaustive depth 1 to 4, **69,904 sequences**, then **100 seeded walks** of 25 actions. The test asserts `checked == 70,004`, and it passes. Its bounds: a retained bound of two accepted sets (`2 × captureCap − 1`), three proofs per kind, two row sets per kind, and a row age of 60 s. It claims those bounds only. It does not claim more kinds, more sizes, more revisions, or longer walks.
- Both models were written from the same design as the production ledger. They are not an independent specification. Their representations differ. The single-kind model is a flat list with a per-entry held flag, and it recomputes byte totals by reduction. The cross-kind model is also a flat list in capture order, with totals recomputed each time, and it has no per-kind table, no running counter and no janitor rotation. Physical release is modelled only by the logical rules, and the drain checks the end state. Both share the test harness and the codec size.
- Tie order: eviction takes the earliest capture instant, and a tie across kinds goes to the kind earlier in `ControlCollectionKind.allCases`. The production ledger and the cross-kind model use this same rule, and it is written in the ledger's doc comment.

### Harness issue, recorded (not a production defect)

- The first cross-kind run failed on the shortest trace `[capture(kind 1, revision 1, size 0), advance 60]`. The drain budget was computed from the two modelled kinds, `crossKinds.count × proofs`. The production janitor rotates over every `ControlCollectionKind` case, `allCases.count × proofs`. A drain of the modelled count ended before the slot of kind 1 was visited, for the kind indices used here.
- The fix is in the harness: the drain now uses `ControlCollectionKind.allCases.count`, as the single-kind replay already did. The logical expiry rule and the production janitor were not changed, and the counterexample was not relaxed. The fixed harness passes all 69,904 sequences and the 100 walks.

## What changed in this slice

### Known total on the unavailable page reply

- `ControlPageReply.unavailable(kind, reason, knownTotal:)` carries `knownTotal: ControlCount?`. Encoding writes the key only when present. Decoding reads an absent key as nil, so replies from before the total still decode. A present key must be a valid count, and `null`, negative values and non-integers are refused.
- Sources: an over-budget current revision and the snapshot's unavailable reference use the snapshot's exact total for the current collection. An expired revision uses the total its proof recorded. A revision with no proof reports nil, and no total is borrowed from another revision.

### Closed read failures on the wire

- `ControlRuntimeErrorCode` gains `changedIncarnation` and `internalFailure`. They are read answers, and they are separate from the parse-error namespace (`ControlRuntimeWireError`) and from `ControlRejectionCode`. Each read failure reaches the framed client as `.wire(code)`, not as `admissionUnknown` and not as an invalid reply.
- Transport mapping: another incarnation → `changedIncarnation`; an offset past the known total → `invalidValue`; a page that cannot fit the caller's frame (a single row, or the rows, larger than the frame) → `frameTooLarge`; an internal projection or pack failure → `internalFailure`. A projection failure no longer surfaces as `sent(invalidReply)`.
- Wire addition: `changed_incarnation` and `internal_failure` are new raw values. A client built before this slice, which decodes an unknown error code, fails to decode the reply rather than reporting it. No shipping v2 socket exists yet.

### Core page path (`RuntimeServiceCore.pageSource` and `captureCurrent`)

- A changed total under an unchanged revision: a held proof of the current revision, live, aged or released, is compared with the same turn's snapshot total before any decision. A mismatch delivers `revisionTotalChanged` and returns `internalFailure`. The rows are not served, the proof is not replaced, and nothing is recaptured.
- A stale revision keeps its own captured total. It is never compared with the current total.
- An offset past the total the revision is known to have → `invalidOffset`, before any capture or projection. The offset is checked only when the revision it refers to has a provable total: the current revision, from the snapshot, and a retained proof. An unavailable reference with a cursor is not checked.
- A total past the row bound is refused before the owner projects a row: `retentionBudgetExceeded` with the snapshot's total. The owner is not called.
- Owner results: `rows` goes to the ledger; `overBudget` is refused whole; `internalFailure` delivers `projectionNotEncodable`. A count or kind mismatch returns `countOrKindMismatch` from the ledger and delivers `projectionCountMismatch`. A ledger accounting mismatch returns `invariantFailure` and delivers `collectionAccountingMismatch`. Each fault is delivered after the state is complete, and nothing is stored on a refusal.
- The owner's snapshot naming another incarnation delivers `snapshotIncarnationMismatch` and returns `internalFailure`.
- `RuntimeServiceCore.collectionRetention(_:)` is a read-only accessor for tests. It is not a count accessor for the bridge.

### Shared bounded projection (one path)

- `Sources/ConduitShared/ControlRowProjection.swift` (new): `ControlProjectedRows` (moved from ConduitRuntime, with `kind` and `rowCount`), `ControlProjection` (`rows`, `overBudget`, `internalFailure`), `ControlRowsMeasure` and `ControlRowBudget`. `ControlRowBudget.measure` takes any `Sequence`. It checks the count before a row is mapped, and it checks the encoded bytes before a row is kept. The first row past either bound ends the measure as `overBudget`, so the rest is not built. A throwing map or an encoder failure ends it as `internalFailure`, and the error text is dropped. Row bytes come from `ControlRuntimeCodec.makeEncoder()`, which is the same encoder the packer uses.
- `RuntimeSnapshotControlProjection.projectRows(_:from:within:)` in ProxyControlBridge is the one production projection. The owner adapter that the host will later adopt calls it. The fake owner in the tests also calls it, over a kernel snapshot built from its hostnames. The fake holds no bound logic of its own.
- The old full-array builders and page functions (`connectionRows`, `upstreamRows`, `tunnelBindingRows`, `tunnelDNSHostRows` and the `*Page` functions) are removed. They had no production caller.
- Counts: the bridge checks each collection's exact count before any mapping. Connections are sorted only after that check passes. DNS hosts use a private `TunnelDNSHostSource` view over the status arrays. Its count sums the groups with checked addition, so it costs one step per group, not per host, and it allocates nothing. The row mapping and the count share that one view, with no second switch. `tunnelDNSHostCount` throws on overflow.
- ProxyControlBridge does not import ConduitRuntime, and this slice adds no import between them.

### Packer and rowless statuses

- `ControlPagePacker.page` packs only `current` and `staleRevision` pages. `expiredRevision` and `unavailable` are refused as `invalidValue`.
- `ControlCollectionPage` decoding treats `expiredRevision` as rowless, like `unavailable`. A page that claims it with rows is refused. The nested `expiredRevision` is kept only for decoding from older peers, and no producer emits it. The canonical no-rows reply is the top-level `unavailable`.

### Ledger (`RuntimeCollectionLedger.swift`)

- `capture(_:revision:total:rows:encodedBytes:at:)` returns `RuntimeCaptureResult` (`stored`, `overBudget`, `countOrKindMismatch`, `invariantFailure`). Capacity refusals and the entry byte-accounting check precede mutation: retained bytes must equal the sum of the held row sets. The unreachable loop-invariant branch occurs after mutation and carries no no-change guarantee; it remains unwitnessed. The ledger now bounds the total by its row capacity, so a proof's total is always within the bound its metadata is charged for.
- `RuntimePageDecision.current` carries the proof's total. `expired` carries the total.
- The janitor's doc states that physical cleanup is driven by activity. Each janitor turn is called by the service, and there is no timer. An expired row set stays resident while the service is idle. That residence sits inside the fixed byte bound, and a read never serves it, because expiry is decided from the proof's capture time.
- Re-projection of an over-budget or evicted current revision happens on every read, on the owner's turn. No negative cache is added, because no measurement justifies one. Measurement decides later.

### Tests

- `RuntimeCollectionLedgerTests` (29 at the earlier checkpoint, 32 now). The earlier ledger tests are kept and updated to the new API, and the DNS-count check moved to `RuntimeSnapshotProjectionTests`. New (11): the deterministic cross-kind witness, the cross-kind model, the changed-total fault, the snapshot incarnation fault, the encoding-failure seam (`UnencodableRow`, which the shared measure reports as `internalFailure`), the over-row-bound refusal with no state change, the refused-capture state check, the mapping-failure and exact-bounds measure tests, and the exact-total and unavailable-revision page tests.
- `RuntimeServiceTransportTests` (new through the framed client): an internal projection failure → `wire(internalFailure)` with `projectionNotEncodable`; another incarnation → `wire(changedIncarnation)`; an offset past the total → `wire(invalidValue)` with no projection; a row larger than the caller's frame → `wire(frameTooLarge)` with the capture stored; an over-budget refusal keeps its exact total.
- `RuntimeClientCodecTests` (new): the known-total round trip, the absent key, the legacy decode, the refused malformed totals, and the rowless status rules, including the packer refusal.
- `RuntimeSnapshotProjectionTests`: refactored onto the shared projection, with new kernel-based tests for the count refusal, the exact byte bound, the DNS order and count, and the unmappable row.
- `RuntimeServiceFixtures`: the fake owner delegates to the production projection, with a `projectionOverride` seam for mismatch and failure tests.
- `pm-sim runtime-service-wire`: the unavailable reply is checked with and without its total, a legacy reply decodes with no total, and a null total is refused.

## Final review fixes (2026-10-25)

Three findings from the independent recheck were fixed in the frozen files listed above. The wrapper ran red first on the earlier source. Four of the five new witnesses failed there: the aged and released changed totals, the framed snapshot reply, and the raw disconnect. The fifth, the forgotten-proof witness, is a guard that passes on both sources. The fixed source passes all 267 tests.

1. **A changed total under an aged or released current proof.** `pageSource` compares a held proof of the current revision with the snapshot's total before the ledger decides. A mismatch delivers `revisionTotalChanged`, returns `internalFailure`, and changes nothing. The check runs on every read, so a stale read also reports a held current proof whose total changed. The stale revision's own total is never compared with the current one. A forgotten proof has no total, so the current revision is captured again. Witnesses: `testAChangedTotalUnderAnAgedCurrentRevisionIsAnOwnerInvariantFaultAndNothingIsRecaptured`, `testAChangedTotalUnderAReleasedCurrentRevisionIsAnOwnerInvariantFault` and `testAForgottenProofLeavesNoOldTotalToCompareSoTheCurrentRevisionIsCapturedAgain`. The fault callback reads the held total through `RuntimeServiceCore.collectionProofTotal(_:revision:)`, a read-only test accessor.
2. **An impossible capture branch.** `RuntimeCaptureResult` gains `invariantFailure`. Before the first change, `capture` checks that the retained bytes equal the sum of the held row sets. The eviction loop's unreachable branch keeps its assertion and now returns `invariantFailure`, not `overBudget`. The core delivers the new closed fault `ControlServiceFault.collectionAccountingMismatch` and answers `internalFailure`. The branch has no witness. The public API cannot reach it, since `retainedRowBytes` is `private(set)`, and a debug assertion would trap a test. The restricted-scan source variant from the parent's runs reaches the same loop assertion by reading. It was not re-run on this source.
3. **A reply that no frame can carry was reported as a corrupt reply.** `finishReply` replaces an answer that the caller's frame cannot hold with one `frameTooLarge` failure, encoded once with no further fallback. A failure that does not fit ends as `.sent(.disconnected)`. Any other encoding invalidity stays `.sent(.invalidReply)`. The lost-reply seam still consumes once per encoded answer, and never on a disconnect with no answer. Witnesses: `testASnapshotLargerThanTheCallersFrameIsAStableFrameTooLargeWireError` (framed client, `wire(frameTooLarge)`) and `testAnAnswerThatNoFailureCanFitIsADisconnectNotAnInvalidReply` (raw transport, `sent(disconnected)`).

Residuals, not closed here:

- The disconnect path emits no owner fault. The caller's frame is the caller's limit, not an owner or service invariant, and the caller receives the typed disconnect. An oversized error reply that becomes a disconnect has no separate witness. The snapshot witness covers the shape.
- The ledger models are unchanged, because the decision semantics they check are unchanged. Their sequences (22,620 and 69,904, plus 100 walks each) pass on the fixed source in the final wrapper run.
- No source-variant mutation has been executed against the three fixes.

## M2E oversize-outcome replay gap, front-door refusal, framed lookup (local, 2026-10-25)

Base: the combined focused suite at **314 tests, 0 failures**, before this slice. This slice runs **323 tests, 0 failures**: 314 plus 9 new tests. The framed-lookup test was changed, not added. Source identity is **not computed** in this slice. The parent computes the fingerprint after the freeze. The 39 workflow checks have not been run on this slice.

### The gap, fixed

- A skipped oversize outcome cleared the control log and moved the floor. `controlStart(forEvent:)` refused only when the oldest retained outcome's boundary was at or after the replay start. After a skip nothing was retained to compare, so a replay from before the skip was accepted with no outcome. Example: events 1 to 3, an oversize outcome at boundary 3, then a replay from 1. It delivered all three events and caught-up, with no outcome and no `expiredHistory`.
- `RuntimeObservationLog.lastLostBoundary: Int?` is one value, nil when nothing was lost. It records the boundary of the newest evicted or skipped outcome, through ordinary evictions and oversize skips. Boundaries never decrease in sequence order, so it is the highest lost boundary. `controlStart(forEvent:)` refuses exactly when `lastLostBoundary >= first`, which is the inclusive start. The old comparison against the oldest retained boundary is removed. Consequence: a replay that starts after every lost boundary is now accepted, even when the oldest retained boundary is at or after it. The old code refused that case, so it was a false expiry.
- A skip still consumes its sequence and no event position. It fabricates no wire event or cursor. The successor is checked before anything changes, and eviction checks its successor before it removes an entry. Live opens are unchanged.

### Red, then green

- **Red**: the unfixed production source, with the new witnesses and the extended model, under the exact wrapper. It exited 1 with **323 tests executed, 12 failures**:
  - `RuntimeServiceReplayModelTests`, exhaustive: the shortest counterexample is `[event, oversizeOperation, openReplay, pull(0)]`. At step 3, the model is `idle` and production delivers `events(first: 1, count: 1)`. The seeded walks also failed.
  - `testAReplayThatWouldCrossASkippedOutcomeIsRefused`: `controlStart(forEvent: 1)` returned 2, not nil.
  - `testEverySkippedOutcomeRefusesTheReplaysThatReachIt`: `controlStart` returned 3 for both 1 and 2, not nil.
  - `testANormalOutcomeAfterASkipIsReplayedFromItsBoundary`: from 2 returned nil, not 2.
  - `testAnEvictedOutcomeRefusesOnlyTheReplaysThatReachIt`: from 2 returned nil, not 2.
  - `testAReplayAcrossAnOversizedOutcomeIsRefusedAsExpiredHistory`: the baseline was `replay(from: 1, through: 2)`, not expired history. The refused subscriber then delivered `events(count: 2, firstCursor: 1)`, which is the silent gap.
  - `testAReplayAcrossAnOversizedOutcomeIsRefusedOnTheFramedWire`: the baseline was `replay(from: 1, through: 2)`, not expired history.
  - `testASubscribeThroughExchangeIsRefusedBeforeAnyOwnerHop`: `sent(invalidReply)`, not `notSent(invalidReply)`, with one owner hop queued.
  - Passing on the old source, as intended guards: `testAReplayAfterAnOversizedOutcomeDeliversOnlyTheEventsAfterIt` (a replay after the skipped boundary is still accepted), `testAReplayCatchingUpWhenAnOversizedOutcomeLandsEndsWithAResync` (stale catch-up resyncs), and the framed outcome test.
- **Green**: the same wrapper passed with **323 tests, 0 failures**. The imports fence, event catalogue, decisions check and decisions tests, and both `pm-sim` scenarios passed under `set -e`. The build log has one warning, at `Tests/ConduitTests/RuntimePressureMetricsTests.swift:222` (an unnecessary `try`). This slice does not touch that file, and I did not investigate it.

### Replay model

- `ReplayReferenceModel` has an oversize action, `oversizeOperation`, and a 250-byte outcome bound. Ordinary outcomes are 100 bytes, so their count decides eviction. Oversize outcomes are 300 bytes and are skipped.
- Each outcome keeps its own fate (`ReplayOutcomeFate`: retained, evicted or skipped). A replay is refused when any outcome that is not retained has a boundary at or after the inclusive start. That scan runs over the full history, so it is not a copy of the production guard.
- The alphabet grew from seven actions to eight. Depth stays one to five, so the exhaustive count is **37,448 sequences**, where it was 19,607 over seven actions. The seeded walks stay at 200 walks of 40 actions. The model passes on the fixed source. No source mutant of this rule has been run.

### Other changes in this slice

- **`exchange()` front door.** A `.subscribe` is refused as `notSent(.invalidReply)` before any lane is reserved or owner hop is queued. Before, it hopped, and the claimed-round switch answered `sent(.invalidReply)`. The `answer` switch's `.subscribe` branch stays fail-closed as `sent`.
- **`quiesce`.** When an ordinary quiescence finds `ordinaryUnquiesced == 0`, it asserts (`assertionFailure`, active in debug) and delivers the new closed fault `ControlServiceFault.quiescenceAccountingMismatch` after the whole transaction. The D2 ordering is kept. There is no underflow absorption and no clamp. No test witnesses this branch, because the debug assertion would trap one.
- **Framed lookup.** The M2D outcome test now recovers the outcome through the framed client, not the core. A 2 KiB caller gets `wire(frameTooLarge)`, and a 64 KiB caller gets `finished(outcome)`. Recovery is conditional: the outcome is retained, and its lookup reply fits the caller's frame. A non-retained outcome is best-effort history and answers `notRecorded`. No shipping value is chosen.
- **Budget wording.** The checked service budget is the encoded payload plus the stated in-memory subscriber charge (`subscriberRecordBytes` times `subscriberLimit`). It is not a pure encoded size.

### Files

- Source: `Sources/ConduitRuntime/RuntimeObservationLog.swift` (`lastLostBoundary`, `controlStart`, `appendControl`), `RuntimeInMemoryTransport.swift` (`exchange`), `RuntimeServiceCore.swift` (`quiesce`), and `ControlCommandOwner.swift` (the new fault case).
- Tests: `RuntimeServiceReplayTests.swift`, `RuntimeServiceReplayModelTests.swift`, `RuntimeServiceTransportTests.swift`, and `RuntimeServiceFixtures.swift` (a `controlLogByteCapacity` parameter and `ManualOwnerScheduling.queuedHopCount`).
- Docs: this checkpoint and the verification note.

### Gaps

- Source identity and the parent fingerprint are not computed. The parent computes them after this freeze.
- Not run in this slice: the full `swift.yml` set beyond the wrapper, `pm-sim all`, `scripts/perf-gate.sh`, and the 39-check set. The parent runs these.
- No source mutant of the lost-boundary rule or the front-door refusal has been run. The red run is the unfixed production source, which is one variant, not a sensitivity sweep.
- The `quiescenceAccountingMismatch` branch has no witness, by design.
- The byte-bound witnesses use an 8,192-byte fixture bound. No shipping control-log bound is chosen.
- The display-text policy is still pending the owner. No text cap or default is implemented.

## Not implemented, explicitly

1. **Subscription table and latest-snapshot slot.** Built in M2B, below. The live model covers their rules; replay and control-log rules are not modelled.
2. **Snapshot frame.** `ControlRuntimeFrame.snapshot(ControlRuntimeSnapshot)` already exists (`Sources/ConduitShared/ControlRuntimeMessages.swift:401`), next to `baseline`, `events`, `replayCaughtUp`, `operationFinished` and `end`. The earlier claim that no snapshot frame exists was wrong, and no new frame or owner decision is needed for M2B.
3. **Replay and control-log models.** Not built. The live observation model (M2B) and the ledger models above are the only models.
4. **Owner adapter and host adoption.** The real owner does not implement `projectedRows(for:within:)` yet. The shared projection is ready for it. Nothing in `Sources/` constructs `RuntimeServiceCore`.
5. **`readSnapshot` nil path** still answers `invalidValue`. It is not part of this slice. The page path is closed.
6. **Sizing and frames.** No new measurement this slice. The existing points are `empty 1425B` and `widest 4771B`. The widest fixture is plain ASCII and is not the largest encoded JSON. **4,771 B is not a maximum.** No shipping profile is proposed.
7. **Cross-kind coverage** is two kinds, as stated above. No witness covers more than two kinds.
8. **Budget formula test.** `RuntimeServiceWorkTests` asserts the retained-byte formula with the same arithmetic as production, so it cannot catch a formula error shared by both.
9. **Historical fail-before evidence** was not produced. Parent source variants now cover the gate release and two eviction defects, with different detection mechanisms; D2 and rejection witnesses have no executed source-variant evidence. See the verification note.
10. **Row measure.** Row bytes come from the codec encoder, which is the same bytes the packer writes. The packer's own free-text pre-check is not applied in the budget, because the budget has no reply frame. A row that is too large for a caller's frame is answered `frameTooLarge` at the packer.

## Earlier history (unchanged, still valid)

- D1: payload release after the gate lock. The comment is corrected, and the witness is the deadline path (`testTheParkedClosureIsReleasedAfterTheGateLockIsFreeAndBeforeTheCallerResumes`). The parent reintroduced an under-lock release variant and observed the probe fail; no historical commit was checked out.
- D2: supersession, quiescence and the outcome measure deliver faults after their transaction is complete (`testASupersessionFaultReachesTheOwnerOnlyAfterTheReplacementIsInstalled`, `testAQuiescenceFaultReachesTheOwnerOnlyAfterTheCapacityIsReturned`, `testAnOutcomeEncodeFaultReachesTheOwnerOnlyAfterTheSettlementIsComplete`).
- Rejection coverage: `testARejectedStopIsRecordedAndRecoversItsRejectionWithoutAFreshFence` for `.dns` and `.proxy`.
- Stream end is terminal and releases the subscriber in the same owner turn. A held timer keeps the lane, not the payload. A dropped framed subscription releases its subscriber without a cancel. An evicted accepted alias is the selected best-effort contract.
- The wait model (`WaitAction`) and the earlier work model (`WorkAction`), each with exhaustive depth 1 to 4 and seeded walks, are unchanged.

## Frozen source paths for this checkpoint

Changed in this slice:

- `Sources/ConduitShared/ControlRowProjection.swift` (new)
- `Sources/ConduitShared/ControlRuntimeErrors.swift`
- `Sources/ConduitShared/ControlRuntimeCollections.swift`
- `Sources/ProxyControlBridge/RuntimeSnapshotControlProjection.swift`
- `Sources/ConduitRuntime/ControlCommandOwner.swift`
- `Sources/ConduitRuntime/RuntimeCollectionLedger.swift`
- `Sources/ConduitRuntime/RuntimeServiceCore.swift`
- `Sources/ConduitRuntime/RuntimeInMemoryTransport.swift`
- `Sources/pm-sim/ScenarioRuntimeServiceWire.swift`
- `Tests/ConduitTests/RuntimeCollectionLedgerTests.swift`
- `Tests/ConduitTests/RuntimeServiceFixtures.swift`
- `Tests/ConduitTests/RuntimeSnapshotProjectionTests.swift`
- `Tests/ConduitTests/RuntimeServiceTransportTests.swift`
- `Tests/ConduitTests/RuntimeClientCodecTests.swift`
- `docs/runtime-service-engine-checkpoint-2026-10-25.md`, `docs/design-runtime-client-engine.md`, `docs/decisions/0014-runtime-client-stream.md`

Changed in earlier slices and unchanged here: `RuntimeServiceLimits.swift`, `RuntimeTransportGate.swift` (D1 comments), `RuntimeServiceWorkTests.swift`, `RuntimeServiceAdmissionTests.swift`, `ControlRuntimeCollections.swift` (packer `status:` parameter), `RuntimeInMemoryTransport.swift` (stale status, `internalFailure`).

No file under `docs/architecture-review-2026-09-18.md` or `docs/issue-triage-2026-09-23.md` was touched. No commit, no push, and no install.
