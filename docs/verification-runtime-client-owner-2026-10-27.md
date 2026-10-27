# Shared host through the actual runtime clients

Status: merged integration checkpoint, 2026-10-27 (PR254). This follows the merged
[shared module owner](verification-runtime-module-owner-2026-10-27.md).
AppState activation, RuntimeActor isolation, shipping profile selection and release
acceptance remain open. The installed app and helper have not been replaced.

## Ownership and interfaces

`RuntimeHost` implements `ControlCommandOwner`; the service owns bounded admission,
lookup and observation, and delegates runtime intent to that host. One host
incarnation spans the service, private editor and workflow. The store separately
mints exact component baselines. One host composition supplies both framed
`RuntimeClient` and `PrivateEditorClient`; neither exposes a live manager.

Normal editor reads capture current values, component authority and module intent
in one memory observation. They do no file I/O. Explicit reload remains the sole
read-and-reconcile operation. Revision-qualified collection captures retain each
collection's COW slice rather than a complete kernel snapshot.

Private frozen updates, save-only changes, conditional DNS activation and
apply-while-running use the existing workflow and store. Three file writers are
not reproduced in the client. Launch-at-login administration preserves other
platform fields, and runtime/platform updates preserve its current stored value.
Preferences have a separate component precondition and no runtime apply.

Receipts describe each verified write, exact new baselines and actual lifecycle
member results. A matching causal receipt may advance its submitting draft;
observations cannot retokenize a dirty draft. DNS Stop's disable write includes
its prior baseline, allowing its own client to recognize that write without
hiding an intervening client's edit.

Quit fences immediately, has separate admission capacity, and reserves only the
explicit request IDs for its final configuration and preference saves. A thin
client routine uses those same framed operations under one total deadline. No
final save applies or persists an exit-disable. Logical deadline and physical
cleanup remain separate: capacity and root authority survive detached work.

The two new service diagnostics use Foundation-only `RuntimeServiceEvent` values,
separate wire values and exhaustive bridge mappings. The shared catalogue gate
pins all three migrated families; 16 benign fixture changes pass and 63
mutations are rejected. Legacy event fields retain their meaning.

DNS tests use one coalesced physical probe away from the serial teardown queue.
A lost or refused stream does not skip final Quit saves: their producers perform
one causal outcome lookup after the prior input physically releases. Normal Quit
settles through the stream; without it, one final lookup runs before the total
deadline and an unsettled caller remains until that deadline. No polling or new
server waiter is added.

## Verification boundaries

The reviewed runtime corrections at `0e54966` passed 1,560 focused tests, two
skips and no failures, with all 101 actual-host simulator assertions. Subsequent
test-only sizing and typed-name checks passed nine targeted tests and all 20
wire-simulator assertions. The strengthened held-probe witness at `c105073` also
passed independently. Sources remained frozen during each verification. The
complete local workflow has passed; exact-head hosted gates remain pending.

Independent subscription-backed review found and then cleared two blockers: a
DNS probe queued ahead of teardown, and final Quit saves skipped on stream loss.
The final held-probe test removes its queue-label dependency and uses one bounded
stream reader. Executed mutations below discriminate physical ordering and the
full remaining shutdown window. This is not AppState or release acceptance.

The independent private-authority model exercises 88 legal depth-three two-client
histories and 264 transitions through the actual framed host/store. Its reference
state does not reuse production transition policy. It covers read/save/reuse
authority; it does not establish production UI draft handling or every lifecycle
and cancellation schedule.

[Executed guard experiments](experiments/runtime-client-owner-guards/README.md)
record exact sources, failed assertions and byte restoration. An early removal
of the apply pair-freshness guard survived its existing witness. The final-client experiment closes that witness gap with two intended
assertions; returning a capacity-wait permit before timer cleanup causes three.
That experiment
passes 48 baseline/restored tests. The subsequent probe/terminal correction
experiment passes 54 baseline/restored owner tests; its serial-queue removal
fails five ordering assertions (plus honest unconfirmed-cleanup diagnostics), and
its premature Quit return fails the deadline assertion.
Compiler errors, crashes and unrelated failures do not count as guard evidence.

Official Claude Code implementation and independent review use the owner's
authenticated `claude.ai` Max subscription, with API credentials/provider overrides
cleared and first-party subscription authentication checked before requests.

## Measurements and remaining activation work

The actual-client experiment exercises the real host, codecs, sole store, explicit
fake effects, scratch state and a loopback listener. Preliminary timings and
whole-probe memory samples are not shipping guarantees. Independent review found
probe-held observation copies, an understated validator-accepted wide fixture and
mislabelled cleanup timing; these were corrected in the
[actual-client probe](experiments/actual-runtime-client-profile/README.md). Its
resolved-source run records 29 passing mode/trials on source-equivalent
`ebff753` / `4be2399`, with stable source and linked objects. The added
validator-wide final-save case calls the production `RuntimeClientQuit.quit`,
rebases only from its own prior receipt, verifies both final files and proves
physical cleanup. Independent subscription-backed review checked the actual
routine, causal authority, fake effects and quoted numeric cells. The
[raw numeric records](experiments/actual-runtime-client-profile/runs/ebff753-85GRoD/metadata.json)
are preserved alongside the earlier checkpoint rather than relabelled.

The valid wide reply/request remain 6,448,967 / 6,350,146 bytes; escape-heavy
frames remain below 8 MiB. Live contention Stop completion was 2.7–19.7 ms,
including slower results with and without sampling. The actual Quit routine
completed in 1,009.9 ms, including a deliberately held prior save; 622.3 ms
followed its release. These are single-machine observations, not latency
guarantees. Whole-probe peaks include test fixtures and verification reads:
96.5 MB footprint / 109.9 MB RSS in the older contention mode, and a 54.67 MB
sampled malloc phase maximum in the routine mode. No application memory bound,
plateau or attribution of residual allocations is established. Encoded
reservations do not bound process RSS. Shipping profile selection remains open.

The actual outcome codec also measures every outcome kind at its widened
constructed point: the upstream-probe result is 9,616 bytes (9,812 as a stream
frame), the three-member configuration receipt 715, the conditional-DNS receipt
706, and the DNS-disable result 434. Each fits the candidate outcome/log capacities
and 64 KiB frame cap; this does not promote that candidate to production.

Complete coherent-source review, all workflow gates and exact-head hosted CI.
Then finish the measured composition profile and client-facing diagnostics needed
by AppState, activate AppState once, and delete its replaced runtime, reconciler,
observer and persistence paths together (0031). Move the whole control cluster to
RuntimeActor afterwards. Production daemon sockets, expanded applied-state scope
and listener handoff remain separately scoped work.


## Complete local workflow

All 41 workflow checks passed on stable source at `4be2399`: 3,619 Swift tests
(four skips), all 103 simulator records, perf, packaging, updater, boundary,
redaction, wire and standalone shutdown checks. The
[per-step results](experiments/runtime-client-owner-guards/workflow-results.json)
record the commands, durations and source fingerprint. The committed source tree
is `176bb9daa53d048b1ad93f0fb4b449d2bc3357ed`; the independent verification
checkout has the same tree. Documentation updates that follow this run do not
change the tested Sources, Tests, scripts, resources or package files.

The resolved-source resource run and its independent review passed. Hosted Swift
and CodeQL passed on exact head `f16c58e473344069e78f94c1115fa1c15e1f93ee` before
expected-head squash merge in [PR254](https://github.com/srps/Conduit/pull/254) to
`b83ae22f58626b4c54c701caf4b4b72b810a8631`. All three annotations were runner
notices. Codex automated code/security reviews could not complete and Devin
skipped; no completed automated-review evidence is claimed.
The next AppState integration obligations remain separate. No installed-app, RuntimeActor or release-readiness
claim follows from this passing workflow.
