# Single AppState activation checkpoint

Status: implementation under verification, not merged or released. The installed
0.5.8 app and helper remain untouched. Official Claude Code implementation and
independent review used the owner's authenticated claude.ai Max subscription;
API/provider overrides were removed, with no API fallback.

## One runtime owner

The app composes one `RuntimeHost` through explicit production/dev/harness
effects. Runtime commands and observations cross the actual framed ordinary and
private clients. AppState's replaced orchestrator, lifecycle lanes, reconciler,
recovery/VPN observers and direct configuration writers are deleted together.
Its editor drafts, receipt ledger, bounded client observation, presentation and
app administration remain client responsibilities. No second store, loader,
snapshot registry or runtime command shortcut is added.

`RuntimeServiceProfile.inProcessApp` supplies one coherent profile, including the
selected 64 KiB ordinary frames, 8 MiB private frames, 10,000-row / 4 MiB complete
capture and 8 MiB host-retained encoded rows. These accounts are not app RAM
bounds. App composition uses the selected ten-second total Quit budget. AppKit
uses terminate-later; the synchronous fence freezes final intent before any
asynchronous work, and repeated Quit joins the same wait.

The complete control cluster is still MainActor. Its separately selected
RuntimeActor move follows this activation; moving only RuntimeHost is insufficient.

## Focused and independent evidence

The final full focused checkpoint ran 295 tests with no failures and two existing
log-only probe skips, plus app-entry checks, all 132 actual-host simulator
assertions, the 230-name catalogue, decision history and diff checks. The editor
model explores 106,759 transitions plus a depth-six own-Stop race with 3,106
transitions. The real session witness verifies one resubmission of the exact
refused draft and no automatic submission of a newer edit.

[Ten executed guard witnesses](experiments/appstate-client-guards/README.md)
each fail on semantic assertions and pass after exact restoration. The two
invalidated runner attempts are preserved separately from the successful run.
The final test-only closure strengthens the existing host test for
older Start → Stop → newer Start: the newer exact managed endpoint and journal
survive the old completion, and final Stop clears both. A second existing test
now explicitly asserts that the next proxy Start succeeds. Both pass.

Independent subscription-backed Claude review returns SOURCE READY at immutable
r6 snapshot `69c3054d32b1f3a5737e27cc726ef24aa989e1e729b1cd3bab2b374123d2f977`
and patch `3d852245c058cf78ae9610223fc17788cb79e8eec1b023095fa700aa37c1253d`,
against base `d7d47d4f3e918ed9c96ec3ec9ebfcc55da758813`. Production source is
byte-identical to the mutation-tested r5; only those two host tests changed.
This is source review, not release acceptance.

## Behavior and limits

Save-before-apply, whole mixed-apply holds, explicit reload/reconcile and external
changed-byte refusal use the shared workflow. Stop and Quit preserve their selected
exceptions. Saved commands capture at preparation. As selected in 0035/0037,
replacing frozen input can interrupt an unfinished Start; the app explains the
interruption without assuming which module stopped and requires an explicit
retry. This intentionally differs from the old late-input following behavior.

The app's one-line mapping for a lost own-command settlement has model/ledger
coverage but no app transport-fault witness. The notification-only supersession
branch has no notification seam; its login-item non-repair is asserted. A generic
final-save producer exception can consume the bounded ten seconds and report
`cleanupIncomplete`. These are disclosed proof/behavior limits, not swallowed
errors or a new cancellation protocol.

The known separate pool Stop, ephemeral-endpoint, wall-clock flap and unreachable
legacy recovery-notification issues remain #250, #251, #252 and #255. This cut
does not claim their resolution.

## Remaining acceptance

[The complete 41-check proof](experiments/appstate-client-workflow/README.md)
passes on unchanged relevant-source fingerprint
`c79e243f274ebfd408effae8c39bc62a8acf9c8e8419ae398796ef23bf5596ce`: 3,696
Swift tests (four skips), all 103 simulator records, performance, packaging and
standalone regressions. The original run completed with two document-format
failures; the corrected document-only rechecks pass, with both records preserved.
Release builds on clean source `2e8d9fe7f8752ea20d0798c29416ed8910d8a417`.
[All 31 actual-profile trials](experiments/actual-runtime-client-profile/runs/2e8d9fe-appstate/README.md)
pass 481 checks with stable source/objects and complete host/lease release. The
actual widest client Quit routine returns in 974.47 ms under its selected
10,000 ms total; this is fake-effect timing. Three separate fresh
[Debug app-consumer observations](experiments/appstate-consumer-observation/README.md)
pass the structural 10,000-row/four-revision checks. Their observed heartbeat
lateness is 0.677–0.691 s; it includes scheduler delay and motivates the selected
isolation work rather than establishing Release UI latency.

The distinct dev bundle builds and launches with owned scratch state. Native UI
inspection is currently blocked by the locked Mac, so edit/Quit/AppKit checks are
not claimed. Exact-head hosted CI and applicable real-machine/release acceptance
also remain open. No installed app/helper replacement or real VPN/auth test has
occurred. Historical experimental measurements remain separately identified.
