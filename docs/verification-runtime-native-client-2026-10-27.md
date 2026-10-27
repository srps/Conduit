# Native clients before AppState activation

Status: implementation checkpoint, 2026-10-27. This follows merged
[PR254](https://github.com/srps/Conduit/pull/254) and its
[verification](verification-runtime-client-owner-2026-10-27.md).
Saved Start, typed recovery, helper preflight, credential invalidation and wake
integration are implemented. Independent review is clear and focused checks pass.
The corrected combined source passes all 41 workflow checks and independent static
review. Final resource measurement, hosted checks, remaining production-profile
values and AppState activation remain open. Collection budgets are selected in 0038.

## Shared ownership

Ordinary saved Start names the module's exact revision; its optional DNS companion
is proxy-only and names DNS's exact revision. Restart retains its whole-host
precondition. Both enter the same admission, preparation and settlement path as
private Start. Preparation captures the saved pair once through the sole store
slot (0037); a private Start retains its frozen submitted input.

Preparation records each component's prior baseline in that same capture turn.
A saved command's causal receipt reports those priors, verified persistence and
actual member/companion outcomes. The submitting client can advance only a draft
still at the exact prior. An intervening client's write still conflicts.
A held or failed member can coexist with a verified save; clients inspect member
results instead of reading generic completion as listener success.

The ordinary command adds no new loader, store mode or writer. Private receipts
keep their existing encoding. Shipped v1 control, helper IPC and schema-two files
remain compatible. The unshipped v2 Restart result changes to the common causal
receipt; no published peer requires a compatibility branch.

## Recovery events

The kernel emits the typed `proxy_recovery` event at its existing recovery
decision point, before the completion state and callback. Domain values,
wire values and exhaustive bridge mapping remain separate. The payload contains
no summary or endpoint. RuntimeHost's duplicate recovery callback/log adapter
is deleted. AppState retains its notification callback until the one activation.

The failure branch is retained legacy behavior. Its focused fixture forces state
through existing testing seams and checks branch mechanics, not production
reachability. Independent review found that normal direct-mode/reachable-probe
returns appear to bypass it; [#255](https://github.com/srps/Conduit/issues/255)
tracks proof or a real counterexample before changing that behavior.
A stream event and its related snapshot have no ordering guarantee; notification
classification must use the typed event and presentation text may be generic.

## Preflight, credential and wake boundaries

A preflight fence records the replacement notice and pending request count;
it starts no query. Effect launch joins the one running/one pending read pipeline.
Each pass captures its stamp and inputs after launch recovery, reads and evaluates
off the owner and serial teardown queue, and drops replaced or post-quit results
before verdict changes or repair. No request waiter list is added.

The reply carries the held display verdict and the raw-busy indicator. Immutable
wire values reject inconsistent pairs; a missing indicator derives from the older
helper status, preserving conclusive and busy encodings. Credential changes carry
no secret or identity: one command invalidates the existing provider's cache epoch.
An in-flight old read cannot populate the new epoch.

Wake observation is a required injected effect. The daemon selects an inert
adapter; headless consumers select fakes. Three existing coalescers bound the
independent proxy, kernel and DNS repairs before task creation. A module Stop
keeps observation; Quit admission stops it and later passes check that fence.
The app's legacy observer stays until the single activation.

Known capacity refusal occurs before the owner fence and has no effect. The
future app adapter must retain and safely retry a known-unadmitted helper-change
or credential notice, or surface the pending refresh; an ambiguous admission is
recovered by lookup rather than resending. Readings and drafts still do not grant
runtime authority.

## Focused verification

- Saved Start source at `fa78db4` (integrated as `39a0d6e`): 1,569 selected
  tests, two skips, zero failures; event and decision checks; 105 actual-host
  simulator assertions. A mistakenly duplicated wrapper was terminated by its
  60-second limit and is excluded from this evidence.
- Independent subscription-backed Claude source and final-test reviews found no
  blocker. They verified the store capture turn, causal prior semantics, shared
  settlement, codec rejection and absence of v1/helper changes.
- The new saved-Start reference model runs 125 legal depth-three two-client
  histories alongside the existing 88-history model. Its oracle tracks versions,
  values, DNS intent and each client's observed authority without calling the
  production authority policy. It excludes DNS Stop, proxy/tunnel Start and
  asynchronous OS schedules; deterministic tests and pm-sim cover separate paths.
  [One executed guard](experiments/native-client-guards/README.md) omits the
  causal prior, causes the intended assertion, restores exact bytes and passes
  the 125 histories again. It is one property witness at the recorded checkpoint.
- Typed recovery at `60cf52d`: 331 focused tests passed; the catalogue accepts
  17 benign changes and rejects 71 mutations; kernel import checks and the two
  existing supersession simulator scenarios pass. These scenarios assert absence
  of an outcome; positive outcomes are kernel tests, not a pm-proxy file-process
  scenario. Subsequent cleanup and event-order refinements passed the combined
  focused checks and the full Swift suite below.
- A widest constructed saved-Start request is 378 bytes. Its receipt is 887 bytes
  as an outcome, 952 as a retained settlement and 1,083 as a stream frame.
  These are measured codec points under explicit test limits, not production
  profile selection or process-memory bounds.

The first combined run compiled and passed every class except two preflight
fixtures that attempted three held operations under an explicit capacity of two.
Those tests now declare three slots; the saturation test still declares four and
rejects a fifth request. The correction passed 96 tests and the actual-host
simulator. A further phase/wire-contract refinement passed 132 focused tests and
the simulator after two test-message autoclosure compile errors were corrected.
Neither compile failure is represented as a runtime failure or passing evidence.

All 41 workflow checks passed on stable source at `00a4b30`: 3,647 Swift tests
(four skips), 103 simulator records and perf. That checkpoint precedes the final
phase/wire refinement. The final run on stable source at `3ed13fa` passed
40 of 41 checks, including 3,648 Swift tests (four skips), all 103 simulator
records and perf. The process redaction test timed out awaiting the connect-failure
response. Eight bounded reruns passed, which did not establish a cause. A retained
diagnostic then showed that the fixture’s bound, non-listening loopback socket
took 7.782 seconds to fail with OS timeout error 60. That fixture can race the
ten-second client deadline; its claim of deterministic refusal was incorrect.
The test-only closed-port correction passed against the same binary in
0.22 seconds; its failure-artifact retention was also exercised. The fixture does
not enable auditing, so its vacuous optional audit-file check and audit coverage
claim were removed. Runtime timeout policy is unchanged; this checkpoint
is not an all-green workflow claim. Independent subscription-backed delta review found no blocker in
the refinement, including the read-after-launch ordering and balanced pending
count. No ordinary admission-drop API was introduced: admitted ordinary work
already runs its effect; only queued Stop replacement has a discard hook.

Official Claude Code implementation and independent review use authenticated
claude.ai Max subscription sessions, with API/provider overrides cleared and
first-party subscription authentication verified before each session.
The serving Conduit 0.5.8, installed helper and primary checkout remain untouched.

## Actual observation and successful-reply completion

Review of the 31-check resource run at `3ed13fa` found it had observed no runtime
events: the actual host composition had not connected its log sink to service
ingress and did not end streams on shutdown. That run remains explicitly
pre-integration evidence. These defects are corrected at `8f5b71d`:

- Every composition connects state, events and shutdown together. The single
  event sink records once to the diagnostic writer and feeds the existing bounded
  ingress through a weak service reference. No manual-scheduler test skips it.
- Shutdown closes ingress, drains queued observations and admitted outcomes,
  wakes parked waits and ends streams with the existing `host_shutdown` reason.
  Later opens/compositions observe the same end. Factory refusal detaches all
  connections; dropping clients retains neither the service nor host.
- Successful owner-round replies and opens wait for their ticket's physical
  release, including the counter and callback. This is one shared handoff,
  reusing the private exchange's existing settlement primitive. No consumer
  polling helper remains. Failures and timer-generated budget refusals still
  detach promptly while unfinished work retains its slot; resolution provenance
  is recorded in the gate's winning locked step.

The first event-focused run failed one authority-model pull with a transient busy
result. Connecting the real event feed exposed the successful-pull cleanup gap;
adding waits/retries to each consumer was rejected in favor of the shared handoff.
A 349-test passing checkpoint then failed independent static review because the
initial handoff also waited on timer-generated refusal bytes. The corrected
checkpoint passed 351 focused tests (two skips), all 121 actual-host simulator
assertions, the 229-name catalogue and decision checks. Independent frozen-source
review is READY; its scope is code review, separate from the parent's test runs.

[Three executed source guards](experiments/runtime-observation-guards/README.md)
disconnect the feed, omit shutdown wakeup and restore the erroneous refusal
handoff. Each fails its intended assertion without a compiler error, crash or
process timeout. Exact restored bytes pass all four selected tests.

Events recorded after the observation close remain file-only. Concurrent producer
threads have no shared chronological order guarantee. Event encoding runs on the
producer thread and still needs the complete resource measurement. The isolated
core wakeup test feeds synthetic events; the actual-host tests produce their
records through the real host/workflow.

## Explicit reload and DNS health

The combined source at `f775a91` adds the payload-free v2 reload command over the
existing reload primitive. Facade and client pass through the same store/workflow;
the client request ID reaches the store context. A bounded typed result explains
refusal, adopted-but-held/superseded input or a reconcile attempt. An attempt is
not physical success and carries no configuration or baseline authority. Normal
editor reads remain memory observations, and dirty drafts retain their old tokens.

One host-owned DNS liveness observation projects through the existing bounded
`dnsError`, before the presentation revision, while DNS runs and has no kernel
error. Recovery and lifecycle changes clear it. Timer and restart callbacks carry
the run token; old readings cannot act on a newer run. The legacy app receives the
minimal matching guard under the twin rule until its one deletion. Its transient
UI overlay is not a stable display assertion; shared-host snapshots cover health
presentation. The legacy failed-to-running override is not adopted by the host.

The isolated slice passed 130 focused reload/DNS/codec/workflow tests after 13 async
XCTest-autoclosure compile errors were corrected. Five affected app/daemon harness
cases passed for the twin guard. These results precede combined-workflow acceptance.

The combined `f775a91` checkpoint passed all 41 workflow checks on stable source:
3,678 Swift tests (four skips), all 103 simulator records, perf and packaging. Further
review then confirmed that reload/save admissions do not move the lifecycle
counter, so an older reload could continue after a later eligible accepted view
and falsely report currentAtEnd. `011f589` binds the pass and its answer to the
existing accepted-view generation through one weak-self predicate. A held/refused
observation preserves prior eligible work. Thirty focused tests pass, and
[the executed view guard](experiments/runtime-reload-view-guard/README.md)
detects the deliberate regression; restored tests pass. The final complete run
on corrected source `011f5898e752f914b110fb41639cb6b76e99357d` passes all 41
checks, including 3,680 Swift tests (four skips), all 103 simulator records,
perf and packaging, with a stable source fingerprint
`ff3809916409e1b4bcfe2d546d3ba8ff9ec70ba59824af5bae2748e0440c5a9b`.
Independent subscription-backed static review is READY. The parent mistakenly
started the resource Release build while the final simulator steps were still
running; those steps passed, and perf had completed before the overlap. That
resource attempt is excluded and is being repeated in isolation.

V1, helper IPC, schema-two files and event names stay compatible. V2 gains the
unshipped reload operation/result; DNS health events now label their source
`health_timer`, and the reload log is host-neutral.

## Resource run finding

The isolated `011f589` run `bwveLh` passed 30 of 31 mode/trials, including actual
event delivery to all four subscribers and host-shutdown stream endings. It is
not complete profile acceptance: `lifetime-save` failed snapshot flush
confirmation. [Preserved records](experiments/actual-runtime-client-profile/runs/011f589-bwveLh/README.md)
include the exact diagnostic events: a first journal creation is followed by a
latched snapshot destination refusal (`inspection_failed`, `platform_state`).
No snapshot was written. Source review identifies a missing-resolution /
newly-existing-file metadata race; the precise syscall branch is inferred from
the records, not instrumented. A bounded re-resolution and deterministic guard
coverage are implemented at `ef3e4df`. Claude's focused wrapper passes 54 tests,
the destination-guard simulator, catalogue and decision checks.
[The executed recheck-removal guard](experiments/diagnostic-creation-guard/README.md)
fails its intended effect assertion; exact restored bytes pass. Existing refusal
latching stays selected. Independent frozen-source subscription-backed review is
READY. The complete corrected source
`ef3e4dfcdc712e29b46a78953a01ab00caa4b852` passes all [41 workflow checks](experiments/native-client-workflow/README.md):
3,685 Swift tests (four skips), all 103 simulator records, perf and packaging.
Initial/final source fingerprint:
`6fa8afc9ccad7418a36e1daa39326373bb54d6e01a8549fd05b9bce20a35ec21`.
The fresh [corrected-source resource run](experiments/actual-runtime-client-profile/runs/ef3e4df-OdAmdZ/README.md)
passes all 31 mode/trials with clean/stable product sources and unchanged linked
objects. Every subscriber receives 13 actual-host events (three typed configuration
workflow events) and ends with hostShutdown before manual cancellation. No typed
lifecycle event is claimed for that pressure fixture. The actual client Quit
settles its final saves and teardown in about 1.07 seconds under its experimental
30-second allowance. This does not select the shipping Quit wait or validate real
helper timing. The [measurement report](experiments/actual-runtime-client-profile/README.md)
keeps encoded custody, sampled whole-probe memory and application RAM distinct.

## Remaining acceptance

Complete exact-head hosted checks/reviews on the combined source.
The corrected-source run measures actual event delivery, shutdown and contention;
older zero-event figures remain historical. Owner-selected
[0038](decisions/0038-bounded-runtime-collection-capture.md) fixes 10,000 rows / 4 MiB
capture / 8 MiB retained; remaining capacities and deadlines stay distinct from that
selection and from process-memory measurements.

Settle the proposed [total app Quit wait](decisions/0039-total-app-quit-budget.md)
and preserve optional audit logging in the shared host before activation.
Then activate AppState once and delete replaced runtime, reconciler, persistence,
observer and callback paths together. The
[test migration checklist](planning-appstate-test-migration.md) distinguishes
verified twins, candidates requiring comparison and client-flow coverage.
RuntimeActor isolation and release acceptance follow the activation.
