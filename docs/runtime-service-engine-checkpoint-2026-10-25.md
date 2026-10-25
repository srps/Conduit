# Runtime service engine: checkpoint (2026-10-25)

Status: **local worker checkpoint, not PR-ready and not engine-complete.** The exact wrapper passes (`PASS: runtime-service focused checks`) with 267 focused tests and 0 failures, after the final review fixes below. M2 is partial: the collection ledger, the shared bounded projection, the page decisions with logical expiry and the closed read failures are implemented and tested. Not implemented: the subscription table, the latest-snapshot slot, observation, replay and control-log models, the owner adapter in the actual host, and any host adoption. No RuntimeHost, AppState, ConfigurationStore, helper, v1 or private-wire edits. No shipping values were chosen.

Branch: `codex/runtime-service-engine`, based on `ff7d859` over merged PR232. Local checkpoint; nothing pushed or installed. Source identity and parent verification are in [the verification note](verification-runtime-service-pages-2026-10-25.md).

## Verification record

- Latest run: the exact wrapper `bash /private/tmp/conduit-runtime-stage1-20261024/verify-runtime-service.sh` printed `PASS: runtime-service focused checks; logs under /private/tmp/conduit-runtime-stage1-20261024/runtime-service-checks`. Its filter selects `RuntimeCollection|RuntimeRowBudget|RuntimeService|ControlService|AdmissionLedger|Subscription|Replay|ControlTransport|ControlCollectionRetention|FramedRuntimeClient|RuntimeClient|ControlRuntime|RuntimeSnapshotProjection`.
- Filtered `swift test`: **267 tests, 0 failures** (fresh `tests.log`, after the review fixes below). The parent's run before those fixes was 262. The checkpoint before that ran 240, so the earlier net change was +22. `RuntimeCollectionLedgerTests` now runs 32 tests, and `RuntimeServiceTransportTests` runs 12.
- The build and the test logs contain no warnings. The two unnecessary `try` warnings in `ScenarioRuntimeServiceWire.swift`, which this slice owns, were removed.
- Imports fence, event catalogue (207 names), decisions check, decisions tests, `pm-sim framed-runtime-client` and `pm-sim runtime-service-wire` all pass under `set -e`.
- **Parent source-variant runs followed this worker checkpoint.** The gate probe detected under-lock release; a restricted-kind scan hit a production invariant; a reversed eviction tie-break produced a three-action model counterexample. All original source bytes were restored. Exact provenance and limitations are in [the verification note](verification-runtime-service-pages-2026-10-25.md). No historical-commit fail-before claim is made.
- Not run in this slice: the full `swift.yml` workflow, `pm-sim all`, `scripts/perf-gate.sh`, and any review gate. The parent's independent recheck and final review follow.

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

## Not implemented, explicitly

1. **Subscription table and latest-snapshot slot.** `RuntimeSubscriptionTable`, the latest DTO slot, `ownerDidChange()`, and coalescing are not built. This is M2B and is not started.
2. **Snapshot frame.** `ControlRuntimeFrame.snapshot(ControlRuntimeSnapshot)` already exists (`Sources/ConduitShared/ControlRuntimeMessages.swift:401`), next to `baseline`, `events`, `replayCaughtUp`, `operationFinished` and `end`. The earlier claim that no snapshot frame exists was wrong, and no new frame or owner decision is needed for M2B.
3. **Observation, replay and control-log models.** Not built. The ledger models above are the only M2 models.
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
