# Runtime service and retained pages: verification checkpoint

This is an unadopted service foundation and retained-page slice, after all 39 local workflow checks, before a service PR. RuntimeHost/AppState/store adoption, the latest
snapshot slot, subscription table and observation/replay models remain open.
No shipping ordinary-v2 resource profile is selected.

## Source and focused checks

The frozen source is based on `ff7d859a340f4b13b8400e8c30093c932b14d740`, over
merged store PR232 (`6535fc8`). Its source/test/script/resource fingerprint is
`b08710674ba2a3b43dfc59d042cbbe5a3c1ade9cce2bb53532f886d168def4b6`.
Documentation is excluded from this fingerprint, as in the full-workflow runner.
That fingerprint identifies the earlier frozen source used for the source variants.
The parent computed the corrected current source fingerprint as
`b69b6dfa2633f75ad7ea1f4c7df8d8af362803e35c53bfc665dde112ee1c417c`.
All 39 workflow-equivalent checks passed on that unchanged corrected source.
The run began while HEAD was `53a050e`; its frozen edits were subsequently committed as `5920ae6`.
Claude implemented and verified the slice through the owner's authenticated
claude.ai Max subscription. No API credential or Agent SDK was used.

The focused wrapper selects the actual service, collection, transport, codec and
projection suites. The writer's final run passed 262 tests, both relevant pm-sim
scenarios and the import/catalogue/decision checks. The parent reran that same wrapper after restoring every source variant: 262
tests, zero failures, both simulator scenarios and the checks passed. Those earlier runs preceded the full workflow checkpoint below.

## Final review-fix pass

Three findings from the independent recheck were fixed in the runtime service,
ledger and transport files, with witnesses in the collection-ledger and
service-transport suites. The wrapper ran red first on the earlier source:
four of the five new witnesses failed. Those were the aged and released changed
totals, the framed snapshot reply, and the raw disconnect. On the fixed source,
the same wrapper passes with 267 tests and 0 failures. Both simulator scenarios,
the imports fence, the event catalogue, the decisions check and its tests pass.
The fixes are described in the checkpoint's review-fix section.

The focused wrapper and the full workflow below ran on the fixed source. The restricted-scan
and reversed-tie source variants, and the gate-release variant, were run only
against the earlier files. They have not been re-run here, and no
source-variant claim extends to the review fixes.

## Executed source-variant sensitivity

These were deliberate temporary source mutations in owned test processes. Each
runner saved and restored the exact original bytes in `finally`; no source
variant is staged or retained in production. Each test ran with Xcode selected.
No serving Conduit, helper or machine setting was changed.

1. **Release under the gate lock.** Removed the transfer of `attempt` and the
   refusal into the outside-lock holder in `RuntimeWaitGate.resolve`.
   `RuntimeServiceLifetimeTests.testTheParkedClosureIsReleasedAfterTheGateLockIsFreeAndBeforeTheCallerResumes`
   failed its nonblocking lock probe (`false` versus expected `true`). It exited
   1 without timing out; the source was restored. The original gate file hash was
   `1f28af6d331a987e86b53065a949a460d44f2aa2fe99b2474f9e4c63f998fa19`.
2. **Restricted global eviction scan.** Changed `oldestRowSet` to inspect only
   the first collection kind. The cross-kind model test process reached the
   production invariant `the retained bytes name no row set` and exited with
   signal 5. This is an invariant kill, not a formatted reference-model
   counterexample. The source was restored. The runner deliberately required a
   model counterexample and therefore reported its own expectation unmet.
3. **Wrong cross-kind tie-break.** Changed the production oldest-row comparator
   from `<=` to `<`, reversing the selected equal-time kind priority. The model
   reported a shortest three-action counterexample:
   `[capture(kind 0, revision 1, size 0), capture(kind 1, revision 1, size 1), capture(kind 0, revision 2, size 1)]`.
   At the third action, production retained the first revision as stale while
   the reference expected it expired. The test exited 1 without timing out and
   the source was restored. The original ledger file hash for both variants was
   `4c457f3a8bbdd5b52a639b032ec1009bf4907fbe2bb659cc49be24339dc397ea`.

Raw local artifacts are under `/private/tmp/conduit-runtime-stage1-20261024/` in
`gate-release-mutant/`, `ledger-eviction-mutant/` and
`ledger-eviction-tie-mutant/`. They contain result JSON, logs and the original
source. They are local evidence, not stable external links. The test functions
and production source in the repository are the reproducible entry points.

These runs establish sensitivity to these concrete variants. They do not prove
all defects are caught, independent authorship, a fixed point, or a historical
fail-before run against an earlier commit. D2 fault-ordering witnesses and other
branches have no executed source-mutation evidence yet.

## Models and limits

The wait model explores 7,380 sequences; the work model 22,620; both use depth
1–4 and 150 walks of 40 actions. Join/reject exploration is DNS-only. The
single-kind collection model explores 22,620 sequences and 100 walks of 25;
the cross-kind model 69,904 sequences and 100 walks of 25. Their exact alphabets,
capacities and representation limitations are in
[the service checkpoint](runtime-service-engine-checkpoint-2026-10-25.md).
The single-kind and cross-kind references share design rules and codec sizing
with production; the source variants above supply limited additional sensitivity
evidence. None of these are whole-program interleaving or fairness proofs.

Capture budgeting includes global retained row payload, bounded proof metadata
and one temporary capture before eviction. It is an encoded-payload accounting
model, not an RSS bound; object/allocator/encoder overhead and caller-owned values
are separate. Idle expired rows may remain physically resident within the byte
cap until activity, while page reads enforce logical expiry immediately.

## Full local workflow (parent)

All 39 checks corresponding to `.github/workflows/swift.yml` passed on unchanged
source fingerprint `b69b6dfa2633f75ad7ea1f4c7df8d8af362803e35c53bfc665dde112ee1c417c`.
The exact per-check results are in
`/private/tmp/conduit-runtime-stage1-20261024/runtime-service-full-gates/`.
Full XCTest: 3,112 tests, two skipped, zero failures. All 97 simulator records passed.
The existing proxy performance gate measured wall 10.209 s, maximum RSS 34,045,952 bytes
and CPU 101.03%; this is not a client-service or whole-app memory measurement.

This is the retained-page/service foundation checkpoint, before the separate
observation/coalescing changes are integrated. It is not evidence for that later combined source.

## M2B observation slice (2026-10-25, local)

On `codex/runtime-observation-stream`, based on `53a050e`, the exact wrapper
`verify-runtime-observation.sh` passes with the M2B, M2C and M2D source: 309 filtered tests with 0 failures.
M2D gives stream pulls their own finite lane, adds a real upstream-probe outcome witness through the framed client, and changes an
end that does not fit into a bounded disconnect.
Earlier, at M2C, the run was 305 filtered tests with 0 failures,
and both `pm-sim` scenarios pass. M2C adds a replay model over the production observation log
(19,607 exhaustive sequences and 200 seeded walks), replay tests through the core, and fake-owner pressure metrics. The logs are under
`/private/tmp/conduit-runtime-stage1-20261024/runtime-observation-checks/`. The
live observation model passes, but no source mutant of the M2B rules has been run,
so it is not sensitivity evidence. Limits, sizing and the exact gaps are in the
[service checkpoint](runtime-service-engine-checkpoint-2026-10-25.md), section
"M2B observation slice".

## Combined integration and remaining gates

The retained-page fixes, snapshot/replay service and merged PR234 are now combined locally.
Earlier source fingerprints and test counts above identify only those separate checkpoints.
Focused checks, independent review and all workflow checks must run on the combined source.
The previously noted invariant wording has been narrowed; the unreachable invariant result remains unwitnessed.
Observation/coalescing and replay models exist with the bounds above, and snapshot reads now classify invalid owner state as internal failure.
Actual production-owner adaptation and a measured owner-reviewed shipping profile remain required.
The display-text policy is pending the owner. No v2 socket,
installed-app validation, total shutdown or release-readiness claim follows.
