# RuntimeActor prerequisite: reconciler flag effects

Status: phase 1a implemented and locally verified; no actor retag or release.
This separate checkout includes the AppState lifetime correction before its
actor work. The installed app/helper and primary checkout remain untouched.
Official Claude Code implements and independently reviews through the owner's
claude.ai subscription, with no API fallback.

## One owner and one effect queue

RuntimeReconcilerHost.perform is async for physical flag actions. RuntimeHost
captures their inputs, lane/generation facts, managers and logger in the deciding
owner turn, then enqueues on its existing PlatformWork FIFO before suspension.
The owner retains admission and settlement. The login-item immediate action
keeps its existing no-machine-effect policy; registration expansion is not added.

The existing quiescence handle now covers flag effects with a finish-only,
explicit zero-buffer stream. Stop waits for the action's settlement before
reading its applied baseline. A physically landed action records only its own
field at its own request's value, preserving cleanup ownership (#13). It never
promotes a stale whole configuration or overwrites newer desired intent. A
lapsed admission runs no later action and adopts no unnamed group. Partial
failures and generation-superseded outcomes remain observable.

## Focused evidence

The fixed focused wrapper passes 231 tests and 145 actual-host simulator
assertions. The framed witness holds a real environment apply while snapshot
and Stop answer, then verifies Stop clears last and partial failure is reported.
Additional tests cover quiescence ordering, DNS Stop during an in-flight system
DNS switch, and a VPN-gate change while resolver apply is queued. They use
positive ordering conditions rather than fixed sleeps.

Two earlier builds failed when one additional optional expression exceeded the
compiler's type-checking budget. A list of already-computed results preserves
evaluation, first-failure selection, pin/release, cleanup and flush semantics;
it starts no extra scenario. Both failed attempts remain archived locally.
Independent static review of the revised source finds its bounded findings
resolved. The complete 41-check workflow exited zero: 3,704 Swift tests with four
existing skips and zero failures, and all 103 simulator records passed. The
relevant source fingerprint stayed
`105f6b8f15e0f37f32519566fcc467c1c5aaf56d7056a284157760a3c6e57b37`.
[Executed evidence](experiments/runtime-actor-flag-effects/full-workflow.json)
keeps the full check list; simulator records, test summary and author manifest
are archived alongside it. [Independent final review](experiments/runtime-actor-flag-effects/independent-review.md)
checked the immutable final patch and full workflow and found no confirmed
remaining defect in phase 1a. Its snapshot fingerprint covers sources plus
selected documents; the workflow fingerprint covers sources, tests, scripts,
workflow and build resources. Both identify this frozen candidate by their
recorded base and patch. [Commit provenance](experiments/runtime-actor-flag-effects/commit-provenance.json)
independently hashes the committed tree at `4696a62` to the exact workflow
fingerprint. Hosted actor checks and native acceptance remain pending.

## Sanitizer baseline

The frozen final phase-1a snapshot additionally passes 192 lifecycle,
reconciler and actual-control-owner tests under ThreadSanitizer, without
suppressions or reported race warnings. The fresh test binary links the TSan
runtime; [the command and provenance](experiments/runtime-actor-flag-effects/tsan-results.json),
linkage and test summary are archived together. The initial sandbox-only attempt
failed to open the compiler module cache before project compilation; its record
is preserved separately. The authorized run exited zero. This single baseline
does not close the older continuation investigation (#118), establish a soak,
or verify the later actor change.

## Remaining at the phase-1a checkpoint

The subsequent [DNS prerequisite](verification-runtime-dns-effects-2026-10-28.md)
records the current candidate for the inline paths below.
The control cluster remains MainActor. Inline VPN/split-DNS gate and retry writes
can still block on the resolver lock held by physical work; this slice claims no
fix for that contention. Push/re-apply still have their existing one-turn
admission-to-task gap. Relay helper work, remaining blocking diagnostic/ready
work, bounded AppLogStore delivery and the HeldCall actor-aware witness remain
separate prerequisites. The complete control-owner cluster must move together,
with large-capture/observer fairness and native/real-machine acceptance.
