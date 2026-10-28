# RuntimeActor prerequisite: split-DNS effects

Status: corrected r2 source independently accepted and all local workflow checks
passed. Hosted checks, full RuntimeActor and native/release acceptance remain due. This is current-isolation preparation, not the RuntimeActor
move or release acceptance. Official Claude Code implements and reviews through
the authenticated claude.ai subscription, without an API fallback.

## One decision and effect flow

RuntimeHost decides each entry-file operation and assigns its queue position in
one owner turn, then enqueues on its existing PlatformWork before suspending.
The operation and its residue read run together under the DNSManager lock,
against the operation's exact configuration. The owner settles the observation.
VPN transitions, Start tails, repair retries, configuration reapply and resolver
switches consume this pattern. The old inline intercept-refresh helper is removed.
Existing synchronous gate/repair conveniences compose the same underlying
primitives for their unit and simulator callers; the host uses queued effects.

Queue positions replace completion counts for freshness: an earlier success must
not discard a later failed VPN-down removal. Out-of-order continuations may drop
only an outcome older than one already recorded. Intercept-refresh settlement
also keeps the newest queued result. Start marks runtimeStarted in the turn that
decides its tail; returning from that tail cannot revive a stopped runtime.
Existing lane/delivery/reconciler drains retain cleanup ownership.

## Evidence and limits

The focused wrapper passed 260 tests and 147 actual-host simulator assertions,
including framed snapshot and Stop admission during a held resolver write,
failed removal after switch-on, VPN flap/Stop during a held Start tail, and retry
versus a newer VPN drop. One earlier attempt failed to compile a new test with
an await inside an assertion autoclosure; the product built. The corrected
attempt passed. [Author inventory](experiments/runtime-dns-effects/author-manifest.json)
and immutable review provenance preserve both attempts and the exact candidate.

The event catalogue describes newer= as a gap in queue positions. It is no longer
a count of completions. No file schema, control frame shape or configuration-store
policy changes in this prerequisite.

## Independent r1 review findings

[The complete r1 workflow](experiments/runtime-dns-effects/r1-full-workflow.json)
passed 41 checks at stable source fingerprint
`e665eba7933a6f0e1524a69651defad108152b041bd31c8150eebc07552b8bab`, including
all 103 simulator records. [Independent review](experiments/runtime-dns-effects/r1-independent-review.md)
nevertheless found two production defects: Start observed residue before its own
intercept sweep, and a VPN drop/reconnect during Start could leave files removed
when the net gate state matched its initial value. The correction moves the read
after the complete sweep and uses the existing VPN report sequence to detect the
flap. New actual-host tests must fail against r1, then pass after correction.
The full workflow alone did not establish these behaviors. R1 evidence remains
historical; corrected-source full checks and final review remain due.

## Corrected candidate

The two new host tests fail against r1 production for the intended reasons and
pass after correction. The first residue fixture failed its own setup and is
explicitly invalidated; the corrected fixture proves residue remained pending
only because it was observed before the sweep. The flap test proves the missing
final apply and file. A simulator matcher initially expected the generic clear
operation; the composition actually restores prior proxy settings with setters.
The corrected trace compares the removal with that restoration.

The final focused run passes 262 tests and 148 simulator assertions, with clean
imports, event catalogue and decision checks. [Regression evidence](experiments/runtime-dns-effects/r2-regression-evidence.json)
preserves all attempts and distinguishes setup/check defects from product
failures. [The r2 manifest](experiments/runtime-dns-effects/r2-author-manifest.json)
and review provenance identify the frozen candidate. [The corrected complete workflow](experiments/runtime-dns-effects/r2-full-workflow.json)
passed all 41 checks: 3,710 tests with four existing skips and all 103 simulator
records. The relevant-source fingerprint remained
`06d02d0acb7f57eee64cf1cc1e92cb14d6c2a5eb69789ffda037ad0f1d7ab143`. [Independent re-review](experiments/runtime-dns-effects/r2-source-review.md)
accepts the corrected source, both real regression witnesses and the non-vacuous
simulator check. Its first attempt failed with a TLS handshake error and is not
review evidence; the successful retry uses the same authenticated subscription.

## Ordering tradeoff and revisit

Keep files-before-orchestrator VPN order. The alternative would add a synchronous
enqueue/await-later PlatformWork handle to begin orchestrator handling while file
work waits. This prerequisite keeps the existing API and physical order. It adds
no queue or separate delivery, whose scheduling could reorder decisions.

As a consequence, VPN routing handling can wait behind unrelated earlier platform
work, bounded by the existing helper transaction budgets per queued item. Framed
reads and Stop admission remain available; their progress does not imply immediate
physical cleanup or VPN routing settlement. This latency has not been measured
here. Revisit the enqueue handle if real-machine/loaded-queue measurements show
unacceptable routing response before declaring release acceptance.

The whole control cluster is still MainActor. TCP relay, diagnostic/ready work,
bounded AppLogStore delivery and the actor-aware HeldCall witness remain separate
prerequisites; the final isolation move must carry the complete cluster together.
