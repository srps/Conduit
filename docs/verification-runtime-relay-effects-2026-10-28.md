# RuntimeActor prerequisite: relay effects

Status: final r3 full workflow and independent source review pass. Earlier
failures and causal test corrections remain below; hosted and release gates are separate. The control cluster is still MainActor. Diagnostics, whole-cluster
isolation and native/release acceptance are separate gates. Official Claude Code
implements and reviews through the authenticated claude.ai subscription.

## One physical effect path

ProxyOrchestrator receives an async relay-command closure instead of a direct
privilege client. RuntimeHost supplies it over its existing PlatformWork and
audited helper client. The kernel owns no helper, queue or concrete platform
adapter. pm-proxy keeps the nil-closure path with no privileged effect.

DNS lifecycle's existing physical slot orders start, reassert and teardown.
Reassert probes run outside the slot; execution rechecks its captured epoch and
generation inside it. At most one reassert is in flight. A Stop admitted while a
claimed relay start is held waits for it, then stops what physically landed.
This preserves truthful state rather than discarding a landed relay flag.

## Focused evidence and cleanup

The final focused run passes 293 tests, 148 actual-host simulator assertions and
10 relay-scenario assertions, plus import, catalogue and decision checks. A
functional seam baseline without PlatformWork/slot/in-flight protection fails
four assertions across three tests: exact queue placement, Stop ordering/final
command trace, and a second reassert being admitted. This is not byte-identical
old code: the async baseline ran on a generic cooperative executor. That is why
the host witness checks the exact platform queue, beyond non-main placement.
An earlier test-target autoclosure compile error is separately invalidated.
[The manifest](experiments/runtime-relay-effects/author-manifest.json) records
attempts and exact coverage; review provenance identifies the frozen candidate.

The unused performTerminationCleanup, its unused timer helper and the unused
PlatformWork.waitUntilIdle(timeout:) are deleted. The audit test retains its
meaningful content, ordering and timestamp assertions on the consumed
DiagnosticFlush path. The catalogue removes the last producer's obsolete
audit_flush_timeout row. No test is added merely to prove deletion.

## Full-workflow gate

[The first complete workflow](experiments/runtime-relay-effects/r1-full-workflow.json)
exited one on unchanged source
`968b14741424157ee66ccfc9dd3661727389c35b91981e7a816234f7dee77daa`.
All 41 checks ran; only swift-tests failed. The single assertion was the
config.proxy_restart count in the listen-host/DNS app-parity test (zero versus
one); the listener-host and unchanged-DNS predicates passed. This is a restart
diagnostic count, not a relay-helper count. The failed run is preserved.

[Independent static review](experiments/runtime-relay-effects/r1-source-review.md)
accepts the relay shape and discriminating focused tests. That does not accept
the failing execution. The source author is tracing receipt/reconciler completion
and observed bindings before proposing any change; no blind rerun or weakened
count/DNS assertion is accepted.

## Test-only correction

[The causal diagnosis](experiments/runtime-relay-effects/r1-full-failure-diagnosis.md)
confirms that the restart event was appended in memory before the successful
rebind, while the test read the asynchronous events file without a writer wait.
The receipt refusal/retry sequence was normal and the relay is not on this path.

The corrected test joins the existing app Quit before its file assertions. All
runtime, listener, machine and saved-config assertions stay before Quit; exact
counts and negative file assertions follow it. Completed Quit establishes that
the bounded diagnostic flush was attempted, not that every queue is empty or
every write confirmed. Missing records still fail. This corrects the stronger
sentence in the author's causal-boundary summary; its stated limitation and the
helper's scope remain explicit.

[Assertion parity](experiments/runtime-relay-effects/r2-author-manifest.json)
covers six tests. Two 100 ms sleeps and two event-file polling waits are removed;
one private helper joins the real app/host boundary without a host reference or
test hook. The expanded focused run passes 327 tests and both simulator scenarios.
[Byte comparison](experiments/runtime-relay-effects/r2-production-comparison.json)
confirms every production Source file is unchanged from relay r1. Corrected-source
full workflow and independent re-review are in progress. Other known artifact
read limitations remain explicitly scoped for the diagnostic work.

## Second full run: a separate setup race

[The second complete run](experiments/runtime-relay-effects/r2-full-workflow.json)
again completed all 41 checks, with only swift-tests failing. The earlier file-read
cases passed. The new failure was the helper-backoff test seeing five failures
instead of six. [Causal diagnosis](experiments/runtime-relay-effects/r2-backoff-diagnosis.md)
identifies its missing setup barrier: the first refresh could finish before the
VPN removal had failed, then its wait consumed the initial failure as a retry.
The correction explicitly observes that initial failure before the five refreshes.
No production behavior or six-attempt requirement changes.

Independent [test-only review](experiments/runtime-relay-effects/r2-source-review.md)
accepts the assertion movement while distinguishing bounded flush attempts from
physical confirmation. Negative-only file assertions still have limited proof
under unconfirmed drains; the diagnostic work retains that limitation explicitly.
The corrected setup and precise helper documentation await their final full run.

## Final setup correction under verification

The backoff fixture now positively observes the initial VPN removal failure
before issuing its five refreshes. Each refresh then has a pending repair and
must add a failure, so the unchanged count reaches at least six. No sleep or
later assertion changes. Helper documentation now states only the bounded flush
attempt guarantee.

[The final focused record](experiments/runtime-relay-effects/r3-author-manifest.json)
passes 327 tests and both simulator scenarios. The helper comment was corrected
after that run, with no logic change. [Production comparison](experiments/runtime-relay-effects/r3-production-comparison.json)
confirms all 404 production Source files match relay r1. [Final complete workflow](experiments/runtime-relay-effects/r3-full-workflow.json)
passes all 41 checks: 3,713 tests with four existing skips and all 103 simulator
records. Relevant source remained `6b1efad999442ec0b7491c51e990c9c8532fc351c332995e6ac941766e371d0a`.
[Independent re-review](experiments/runtime-relay-effects/r3-source-review.md)
accepts the final source and causal test setup, with proof limits retained.

[Final independent executed review](experiments/runtime-relay-effects/r3-final-acceptance.md)
accepts phase 1c and confirms both earlier failure witnesses passed in the full
run. [Commit provenance](experiments/runtime-relay-effects/commit-provenance.json)
links the tested scope to `0aa744a`; [snapshot comparison](experiments/runtime-relay-effects/snapshot-source-link.json)
checks every included relevant review file byte-for-byte against that commit,
with the omitted build resources recorded separately.

## Limits carried forward

Relay commands can wait behind earlier platform work, as selected; the queue's
physical blocks never wait on the owner. A relay left by a crashed earlier run
still has no blind quit stop; the next DNS Start replaces it, as before this
slice. Two slot tests include a bounded negative observation, but their final
relay state/command assertions are decisive. HeldCall's targeted wrong-queue
mode preserves existing preflight exclusions; full actor-aware harness acceptance
remains later work. Hosted CI and real-machine evidence are not implied by the
focused run.
