# Byte-exact runtime intent

This unreleased correction follows merged PR247. Official Claude Code implemented it using the
owner's verified claude.ai Max subscription; no API authentication was used. Codex controls integration
and independent verification. The serving 0.5.8 app and installed helper remain untouched.

## Scope

Swift String equality treats canonical Unicode spellings as equal even when their UTF-8 differs.
The verified store now persists those edits correctly; the runtime must also consume their bytes.
`ConfigDiff.inputChanged` is the common adoption predicate for the orchestrator, reconciler and host.
Section decisions additionally compare PAC, health and DoH URLs and authentication identity text by
bytes, using one kernel helper. Profile-name respelling advances metadata without resetting pooled
authentication, preserving existing ordinary rename behavior. PAC refresh/cache/in-flight comparisons
and credential cache account comparisons use that same helper.

This adds no configuration parser, serialized comparison on MainActor, writer, registry, normalization,
field type, schema, transport operation or AppState activation. Display-only canonical-equivalent
respellings retain existing behavior. The real OS Keychain's handling of canonically equivalent account
names is unverified; the cache conservatively avoids reusing an earlier byte-distinct key.

## Evidence so far

Before production edits on main28ab775, eleven new tests failed with 35 assertions across actual
AppState save, host reload, reconciler, orchestrator, PAC refresh and credential cache behavior.
An earlier fixture omitted the platform sidecar and hit the existing uncommitted-input hold instead;
that setup was corrected before recording the production witnesses.

The initial implementation passed 268 focused tests, catalogue/decision checks and the actual-host
simulator. After rebasing onto merged store correction148c64c, 269 focused tests passed. The combined
simulator retains both the missing-sidecar source authority and PAC URL respelling exercises.
An integration compile first caught duplicated simulator fixture declarations introduced by Codex's
merge resolution. Those duplicates were removed before the reviewed snapshot fda80f7.

One earlier focused run (Wg49Xt) failed the existing snapshot-alias test during diagnostic shutdown:
the runtime settled but the snapshot-refusal diagnostic flush was unconfirmed. Fail-closed retention
then refused later roots. Later passes do not establish a cause or a fix. The harness now reports all
closed outcomes and numeric queue counters without relaxing its guards, budgets or retention.
Twenty isolated repetitions passed, but do not establish the cause or a fix. Independent review investigates the failed checkpoint.

## Remaining verification

Eight actual source mutations each failed their intended XCTest assertion without a compile failure
or crash: common byte comparison, orchestrator metadata adoption, reconciler effect, PAC freshness,
in-flight URL, foreground and background backoff, and credential cache identity. Exact source bytes
were restored and the targeted restored tests passed. The [replay patches and manifest](experiments/runtime-intent-guards/README.md)
record the executed variants and fingerprint all changed production files.

Independent subscription-backed static review of immutable fda80f7 returned READY with no blocking
production finding. It identified useful witnesses for the host Start adoption guard and dropping an
old PAC script on the routing path; those test-only additions wait for the frozen workflow to end.
Its initial proposed Start test incorrectly skipped explicit reload. Reading prepareStart showed that
this would correctly refuse an external edit, so the witness uses reload held by a Stop fence followed
by explicit Start instead. No production behavior changes to satisfy a test.

All 40 required workflow checks plus the targeted DNS scenario passed on frozen fda80f7: 3,447 Swift
tests with zero failures and four documented skips, all 103 simulator records and perf. The source/test/
script/resource/package fingerprint was:

    0d0088dfe469445674f39e88b0be18df508bf7bb8cdeca59b6c1602cf955b308

The review follow-up adds two witnesses and a pre-push lag assertion, with a refresh-operation join
in both routing tests. Focused checks pass 271 tests. The new PAC control first failed because its shared
fake intentionally leaves DIRECT unparsed; only the new private fake received a DIRECT parser, then
the control passed. This is a recorded test-fixture correction, not a production failure.

Three additional actual source mutations isolate the host verified-Start view guard, dropping an old PAC
script on routing, and the reconciler lag predicate. Each failed its intended assertion, exact bytes were
restored, and restored host/PAC/reconciler tests passed. The [follow-up manifest](experiments/runtime-intent-guards/review-followup.json)
proves all production files still match the immutable review/full-workflow source. Independent read-only
review of test delta 2bbd11d returned READY. Two optional cleanups removed an unused DNS fixture and
corrected an observer-delivery comment; no assertions or production files changed.

The final complete Swift run passed 3,449 tests with zero failures and four documented skips after
the added tests and cleanup. Decision checks, including the new owner-selected 0035 and mutation/history
checks, passed. All other workflow checks ran on identical production sources; no repeat of unchanged
packaging/performance tests is claimed. Exact-head hosted CI and merge disposition belong to the
integration PR; these local checks do not claim them.
Coverage limits remain explicit: PAC same-script/racing cache-store checks and the credential in-flight
keep-read check are not independently mutant-verified. No private hooks were added to inspect those states. No release-readiness claim follows from the focused passes. Actual-client memory and
Stop/status measurements remain a separate adoption gate. The unconfirmed diagnostic flush is tracked
with candidate mechanisms and deterministic-witness acceptance in issue47, without a cause or fix claimed. Hostname canonicalization is an unverified
follow-up hypothesis, and direct system-PAC repointing remains separate issue194 work.
