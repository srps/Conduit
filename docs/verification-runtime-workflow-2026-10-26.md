# Shared-host workflow integration: verification checkpoint

This is an unreleased headless integration slice after PR243 (`8014437`).
It does not activate AppState, move the control cluster to RuntimeActor or make
Conduit release-ready. The serving 0.5.8 app was not stopped or replaced.
Claude Code implemented and reviewed through the owner's verified claude.ai Max
subscription; the final corrections and independent review used Opus.

## Implemented boundary

`RuntimeConfigurationWorkflow` privately owns the sole `ConfigurationStore`.
Start commits required inputs before consuming their exact verified pair; Stop
fences synchronously and terminal admission cannot reopen. Explicit reload
observes files read-only, retains supported repair drafts and reconciles only
eligible inputs. Missing required defaults commit through Start. Runtime and
platform inputs retain the whole mixed-apply gate; preferences remain independent.

The host has one accepted-view adoption function for runtime/platform values,
VPN timing providers and the existing v1 configuration generation. That counter
is not an intent, durable or physically applied revision. Eligible no-op reloads
retain their existing generation increment.

The reconciler has one worker, one replaceable pending request and one active
effect. It selects its diff when executing, advances from the exact input held
by the runtime, retains the original retry admission and carries owed surface
work across supersession. It does not create a predecessor-task chain.

Physical proxy/PAC operations use one owned task slot and lifecycle checks.
Recovery operations capture a server-scoped listener identity before taking a
pool across an asynchronous hop. Stale Start, health, probe and recovery work
cannot reclaim the later lifecycle's listener, status or monitors. Actual-host
and AppState twin witnesses cover the selected interleavings separately.

Typed `config.workflow` domain events project to separate wire values. Known
family classification shares the wire codec's closed family discriminator;
actual encoding/classification, cross-domain decoding and a frozen record retain
compatibility coverage.

## Verification and negative controls

The independent workflow model explores 1,339 fixed breadth-first traces and
150 seeded walks against production workflow/store code. Its explicit frontier
budget fails if exceeded. It checks store I/O, per-component persistence facts,
intent generation and returned eligibility; it does not model every physical
host, OS or NIO interleaving.

A parent-run mutation bypassed the store's worker-time write claim. The model
failed on a queued Stop allowing a write; restoring the original bytes passed.
Separate lifecycle/probe/listener mutations also made their real regression
witnesses fail, including an old recovery ladder changing a newer server's pool
and late work changing stopped state. Those kernel mutations were restored by
exact text edits and passing checks, not an independently hashed restoration.

Independent Opus review found and corrected a held-reload/next-Start consistency
bug: the accepted configuration changed while the VPN timing providers stayed
old. A late author note identified configuration effects admitted during physical
Stop. Live admission, restart freshness and lifecycle-scoped probe checks now
cover those paths. Five regression witnesses failed when their guards were
bypassed; the final corrected focused run passed 570 tests and the actual-host
simulator. The health-loop guard already prevented a physical restart; the new
config gate also prevents a false health-restart decision event.

Final full-workflow result: all 40 required workflow checks plus the targeted
DNS ephemeral-pair scenario passed on unchanged source. The Swift suite ran
3,372 tests with zero failures and four skips: two live GSS tests without a
Kerberos ticket and the two opt-in memory diagnostics. All 102 simulator records
passed, as did the performance gate. The source fingerprint covers 703 relevant
source/test/script/resource/package files:

```text
8b0ced770b309b97618d49ae6e9ee1d236c3cdf4bc96bfe8bda48bf601defbd3
```

The independent whole-core and final delta reviews were READY at the prior
`acfee020…5451` fingerprint. Subsequent source changes were limited to two test fixtures.
PACPreviewTests explicitly selects the real CF evaluator for its two owned-file
JavaScript tests while the general harness/dev composition keeps its fake.
AppStateHarnessTests reads machine state after the reconcile drains instead of
requiring exactly one global lifecycle waiter. Codex reviewed both changes;
all five preview tests, 22 targeted ordering/reconciler tests and the full suite
passed. Exact-head hosted checks and review disposition are recorded on the
integration PR and [#186](https://github.com/srps/Conduit/issues/186).

Earlier mid-edit failures and an interrupted full run remain failed checkpoints.
A stable preceding full run passed 40/41 checks but had four assertions fail in
the two preview fixtures; that failure led to the explicit evaluator wiring.
Guard-mutation runs also recorded an isolated diagnostic flush timeout and an
import-test directory cleanup refusal that did not reproduce in the final run.
The extra legitimate DNS retry exposed and corrected an overly strict test/sim
cardinality assertion; production DNS behavior did not change.

The first hosted Swift run on `31dcd4c` failed one assertion in
`testASettingsChangeWhileTheStartAppliesIsReconciledAfterIt`: the global lane
waiter count was two, rather than one. A helper-availability preflight can park
its independent system-proxy drift pass behind the same held Start. The test
now captures the machine's proxy state when reconciliation drains, retaining
its environment, journal and shell-block assertions. No production behavior
changed. Temporarily bypassing the reconciler's lifecycle wait made 22 tests
report seven failures, including five assertions in this target. The parent
verified restoration against the committed reconciler bytes (SHA-256
`4c6cab761e7e6a22494680fcf6fa030da405391d125c8a5c948506059af4ef03`)
before the final stable 41-check rerun.

## Cleanup

- Removed duplicate vocabulary-only coverage and test-only metadata; retained
  actual codec/classifier and compatibility assertions.
- Shared one bounded held-PAC fake between unit tests and pm-sim; moved reconciler
  gate assertions into their owning suite and removed the emptied files.
- Kept count, byte, frame, pressure, model and lifecycle assertions in ordinary
  tests. The two log-only process-memory diagnostics are opt-in; their original
  results and reproduction command remain in the
  [experiment](experiments/runtime-service-profile/README.md).
- Refreshed roadmap/progress and decision implementation evidence, removed stale
  blocker claims and corrected comments that described optimistic baseline
  rewinds or supersession as failure.

## Remaining gates

The [next editor/client review](design-runtime-editor-contract-review.md) records
the private observation/request/reply path, its measured reply ceiling, remaining
production service-profile selection, ordered interactive admission, per-module
fences, reserved final Quit flush and client-owned draft/token behavior. These
and one final AppState activation remain open. The current process-start facade
must not be exposed unchanged to interactive clients. Activation must delete
the app's replaced runtime and writer paths together. The whole control cluster
then moves to RuntimeActor with its own checks.

This checkpoint does not prove installed-app behavior, real VPN/Kerberos/PAC
operation, helper cleanup, power-loss durability, atomic multi-file persistence,
every possible scheduler interleaving or release readiness. No production socket,
private editor reply cap or shipping service defaults are selected here.
