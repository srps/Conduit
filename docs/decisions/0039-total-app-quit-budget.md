# 0039: Bound the in-process app's complete Quit wait to ten seconds

- Date: 2026-10-27
- Decision: accepted (owner, 2026-10-27, #186: selected “10 seconds total (Recommended)”)
- Implementation: implemented
- Validation: passed
- Supersedes: none
- Superseded by: none

## Context

Decision 0015 selected one total monotonic Quit deadline, independent of save
success, without selecting its shipping duration. The legacy app has a five-second
platform-drain allowance followed by other work; that is not a five-second total.
The new client already accepts an explicit total for the entire caller wait.

The corrected-source resource run completed all 31 trials and the actual client
Quit routine in about one second with fake effects and the widest final save.
Its 30-second caller budget was experimental. The owner subsequently selected
ten seconds total in #186. Real helper and machine teardown timing remains
unvalidated.

## Decision

Use ten seconds total for the in-process app's Quit, counted once when
it begins. Fence immediately, then spend only that remaining time on final frozen
saves, operation observation and cleanup confirmation. Return earlier when the
Quit settles. No app-owned final work starts under a fresh budget afterwards.

At expiry, report unresolved work honestly and preserve recovery records. Expiry
does not prove a started physical write was canceled or cleanup completed. It
creates no durable disable, retry or replacement writer. The host retains physical
authority while its started work runs; process exit and next-launch recovery keep
the selected semantics. Later daemon-mode UI Quit still disconnects only (0015).

## Alternatives

- **Five seconds total:** faster worst-case exit, less time than the existing
  combined shutdown work. Diagnostic writers alone may spend up to six seconds
  within their phase, so loaded-machine exits would more often leave confirmation
  unresolved.
- **Thirty seconds total:** more opportunity for slow teardown and final saves;
  a stuck helper can visibly delay app exit or logout for the whole interval.
- **A new allowance per step:** loses the selected single total bound and makes
  the maximum exit wait hard to predict. Not proposed.

## Consequences

Ten seconds is a responsiveness/cleanup tradeoff, not a claim that every helper
call can finish within it. It does not change frame caps, configuration bounds or
selected collection budgets. Other finite service capacities are engineering
profile values reviewed and measured together, not separate owner decisions.

Revisit if native acceptance or actual use repeatedly reaches expiry, if helper
latency changes materially, or when UI/runtime ownership moves out of process.

## Invariants and verification

Run the actual client Quit probe with the selected total, including widest final
saves and held effects. Keep deadline tests covering unstarted writes, physical
work retained after logical expiry, unavailable streams and final-save ordering.
Native app acceptance must verify AppKit terminate-later behavior and the total
wait; machine cleanup validation remains separate from fake timing.

## Implementation evidence

The existing [client Quit routine](../../Sources/ConduitShared/PrivateConfiguration/RuntimeClientQuit.swift)
and [host flush window](../../Sources/ConduitRuntime/RuntimeQuitFlush.swift) accept
one explicit total and distinguish deadline outcome from physical quiescence.
[`AppTiming.quitTotal`](../../Sources/Conduit/App/AppComposition.swift) now supplies
ten seconds to the app's one Quit path. [`AppState`](../../Sources/Conduit/App/AppState.swift)
fences synchronously and freezes final intent once; [`ConduitAppDelegate`](../../Sources/Conduit/App/AppDelegate.swift)
uses AppKit terminate-later and replies after the bounded client routine returns.
[`RuntimeServiceShippingProfileTests`](../../Tests/ConduitTests/RuntimeServiceShippingProfileTests.swift)
pins the selected value, and [`AppStateHarnessTests`](../../Tests/ConduitTests/AppStateHarnessTests.swift)
cover repeated Quit, expiry, late opening, final save order and refusal. The
focused activation checkpoint passes 295 tests (two existing skips). The
[complete workflow and fresh selected-total run](../verification-appstate-activation-2026-10-28.md)
pass: the widest actual client Quit routine uses ten seconds total and returns
in 974.47 ms with fake effects, verified final saves and confirmed cleanup. Native
acceptance remains pending because UI inspection is blocked by the locked Mac. The historical
thirty-second probe does not establish the shipping composition.


The [diagnostic prerequisite](../verification-runtime-diagnostics-2026-10-28.md)
adds the app's final log drain under that same deadline. Actual AppState harness
tests hold the protected log destination: a four-second injected budget returns
in about 2.26 seconds with an honest host timeout/app busy outcome; a one-second
budget returns in about 1.03 seconds with skipped-budget tail work. These are
fake-effect correctness observations, not shipping real-helper timing. The host
can retain diagnostic custody after logical caller expiry; it grants no fresh
app wait and exit may cut unconfirmed output short.

Does not prove: native AppKit termination timing, real-helper teardown latency,
or release readiness. Those checks remain separate from focused fake-effect tests.

### Installed-candidate validation — 2026-10-29

Validation: on the owner's installed 0.6.0 candidate (locally signed, real helper,
VPN connected), the owner's normal Quit while the proxy ran exited without being
forced. The exit came at most 1.91 s after the
owner pressed Return, inside the ten-second total; that upper bound includes the
owner's reaction. Per-service cleanup was confirmed; whether a global route to
Conduit remained after Quit is unproven (see the verification). All eight
journal-scoped per-service proxy field sets matched the priors Start tracked, resolver files and launchd
variables were restored, and the listener was closed. The final snapshot shows
every service stopped, and the journal holds no surface records. Results and
limits are in the [installed verification](../verification-runtime-installed-2026-10-29.md).
This is one normal-path Quit. It does not exercise expiry, a slow or stuck
helper, or a product-only duration, because no readable quit-start event exists.

## Open questions

Verify the selected-total actual-client probe and native AppKit path on the
frozen activation. Real-machine cleanup timing remains due.

Validation checkpoint — 2026-10-28: [native isolated Dev checks](../verification-runtime-actor-activation-2026-10-28.md) save a focused final numeric edit while the proxy is running, exit and show it on relaunch. UI-tool elapsed is not a precise worst-case deadline measurement. Real helper/machine timing remains due, so validation stays pending.


### Artifact-phase deadline correction (2026-10-28)

The [correction checkpoint](../verification-runtime-quit-deadline-2026-10-28.md) records 66c411d implementing this existing policy: the logger cap now also clips the one artifact phase. Ordinary nil-cap flushes keep six seconds; started physical writes retain authority until completion or process exit. The prior implementation and reviews clipped only the logger despite stronger checkpoint wording. Causal unit, actual-host and simulator guards fail when propagation/clamping is removed and pass when restored. The selected total and wire policy are unchanged.

The final local workflow passes all 41 checks (3,770 tests / four skips / 103 scenarios), focused/optimized guards and seven production Release trials/162 checks. An earlier unconfirmed ordinary simulator flush remains recorded without a proven cause; diagnostic-only bounded evidence was added, with all assertions and budgets intact. Final hosted and real-machine validation remain pending.

Status 2026-10-29: the normal-path installed Quit is recorded under Implementation evidence, and validation is passed for that scope. The "remains due" and "pending" lines above are historical. Expiry under a slow or stuck helper is still not observed on a real machine; revisit as Consequences describes.

### Deterministic no-stream confirmation coverage — 2026-10-29

The strict hosted Swift run found a test requiring a settled receipt from the one
final lookup inside its 200 ms reserve. At total expiry, either pending work or
a missed lookup deadline legitimately leaves confirmation unresolved. Increasing
the test's total had only narrowed that race. The client now accepts one package
wait effect, defaulting to the identical continuous-clock sleep. Tests hold the
last declared save, observe the pending Quit and held wait, release the save and
join actual host settlement, then release the final read with wire budget left.
Real-clock expiry and held-teardown coverage remains separate. The selected ten
seconds, receipt rules and wire contract are unchanged. See the
[NIO/concurrency verification](../verification-nio-concurrency-2026-10-29.md) for
checkpoint results, controls and final validation status.

### Signed 0.6.1 normal-path validation — 2026-10-29

The [signed release closeout](../verification-release-0.6.1-2026-10-29.md) records
owner-run acceptance of exact tag `v0.6.1` / `f809bb9`: 23 passing checks, four
observations and no errors. Stop/Start, settings-byte preservation, Quit, reopen
with manual Start, HTTPS, Kerberos and helper observations pass; Conduit remains
serving. Quit was observed within 5.92 seconds of the prompt including owner
reaction, not a product-only measurement. Journal release does not repeat
physical per-service/global-proxy validation. Slow/stuck-helper expiry and power
loss remain outside this native scope. Accepted policy and implementation status
are unchanged; no new owner decision is inferred.
