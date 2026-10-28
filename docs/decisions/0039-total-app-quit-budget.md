# 0039: Bound the in-process app's complete Quit wait to ten seconds

- Date: 2026-10-27
- Decision: accepted (owner, 2026-10-27, #186: selected “10 seconds total (Recommended)”)
- Implementation: implemented
- Validation: pending
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

## Open questions

Verify the selected-total actual-client probe and native AppKit path on the
frozen activation. Real-machine cleanup timing remains due.
