# NIO concurrency verification — 2026-10-29

Status: implementation, independent review and local workflow gates passed.
The first hosted Release checkpoint passed; its parallel Swift run found a separate
Quit-test deadline race, repaired below. Final hosted checks and a new candidate
remain pending. The existing 0.6.0 draft does not contain these repairs.

## Report and baseline

The owner reported `EmbeddedEventLoop` cross-thread diagnostics and a failure in
`VPNTunnelMigrationTests.testAFlapRecoveryClosesOnlySocketsWhoseAddressIsGone`:
the route-moved socket closed, and the last event described an owed `connected`
path sweep instead of an address-only `flap_recovered` sweep.

The [tagged 0.6.0 run](https://github.com/srps/Conduit/actions/runs/40905660480)
passed 3,775 tests with four skips and zero failed assertions, but emitted 157 NIO
misuse diagnostics while 11 ConnectionPool/VPN tests ran. A successful job did not
establish compliance with NIO's threading contract.

With the pinned SwiftNIO 2.101.0, the unmodified
`ConnectionPoolTests.testAuthHandshakeLimitDoesNotRecordStreamingUpstreamFailure`
exits nonzero with signal 5 when run with `SWIFTNIO_STRICT=1`: the embedded loop's
thread check traps. This is a negative control for strict enforcement, not proof
that the separate VPN assertion had the same cause. The pinned implementation
reads `SWIFTNIO_STRICT`; its similarly named embedded-only variable is ineffective.

## Causes and repair boundaries

- Embedded channels used by asynchronous tests crossed executor and real-channel
  callback boundaries. RuntimeActor/MainActor isolation does not promise one
  physical thread. Async fixtures use NIO's thread-safe testing channel and loop;
  synchronous embedded fixtures must finish on their creating thread. Leaking an
  embedded channel can conceal an invalid destruction path and is not a remedy.
- The VPN test used a fixed sleep to assume an earlier asynchronous sweep had
  completed. Recovery correctly resumes a full sweep still owed by a confirmed
  transition. The separate no-owed case uses an address-only recovery sweep.
  Tests control the existing re-sweep delay effect and observe actual completion.
  The production default remains `Task.sleep`; no completion API or second
  scheduling path is added.
- Pool cleanup selected reference objects under its lock, then inspected and
  closed them after unlocking and only later removed them. Acquisition could
  reuse an idle connection selected for closure. Selection and retirement now
  share the pool lock; channel operations happen after unlocking.
- Dedicated classification happened after publication. It now precedes
  publication. Mutable connection metadata has one synchronization boundary,
  with pool-to-connection lock ordering. An exchange that predates an auth reset
  must not undo that reset when its response arrives.
- XCTest setup/teardown actor violations, unobserved throwing release tasks and
  fixture resource lifetimes are repaired alongside the affected tests.
- The full strict suite also exposed a mock CONNECT proxy closing a peer after
  its event loop shut down. Listener closure had left accepted channels alive.
  The two-loop fixture now bounds admission and joins mock channel closure
  before group shutdown, including a failure while the target dial is held.

These repairs preserve the selected runtime, tunnel and recovery policies. They
do not introduce a client contract, persistence format or helper protocol change.
Claude implementation and independent reviews use the owner's authenticated
claude.ai Max subscription, with API/provider overrides removed and no API-key
fallback.

## Acceptance evidence

| Check | Result |
| --- | --- |
| Baseline strict misuse control | Confirmed fatal diagnostic on the original auth-limit fixture |
| First async-fixture slice | 59 focused tests passed under strict NIO mode; zero misuse diagnostics |
| Final strict full suite | 3,780 tests, four skips, zero failures and zero NIO misuse diagnostics |
| Fixture inventory | 178 strict tests passed; repaired tunnel class passed 20 isolated runs (280 executions) |
| Controlled VPN and pool semantic negative controls, then exact restoration | Six pool/VPN mutants, buffered auth-reset simulator and streaming-only auth mutant failed their intended assertions; restored code passed |
| Tunnel cleanup failure control | Injected failure while the target dial was held ended normally with the intended test failure; exact restoration passed |
| Scoped ThreadSanitizer | 264 affected tests, then 32 final pool/streaming/tunnel/VPN tests, passed without suppressions |
| Full ThreadSanitizer | Failed on the independently reproduced Swift continuation finding described below; not counted as passed |
| Every Swift workflow step, simulator suite and perf gate | All 20 steps passed on one stable tree; 104 simulator cases passed; perf gate passed (10.12 s, 33.5 MiB maximum RSS) |
| Optimized checkpoint | Local release compilation and all 32 repaired pool/VPN/tunnel tests passed; hosted Release checkpoint passed its full standard suite, optimized PAC checks and ad-hoc package verification |
| Parallel hosted Swift checkpoint | Failed one no-stream Quit assertion; zero NIO misuse diagnostics. The original result remains failed |
| Independent final reviews | Claude accepted the production synchronization, fixture repairs, streaming coverage and final tunnel shutdown changes after requested fixes |

Strict NIO enforcement is inherited by the Swift, release and sanitizer workflows,
including optimized XCTest and simulator subprocesses. It also rejects scheduling
onto a shut-down real event loop. No diagnostic is suppressed to make a gate pass.

The full unsuppressed TSan run stopped at a Swift continuation handoff. A bounded
standalone probe with no Conduit or NIO reproduces the same report; inline and
await-first controls complete cleanly. The independently reviewed probe and raw
evidence are [committed with the controls](experiments/nio-concurrency/README.md).
This supports a separate Swift continuation/TSan finding without establishing
whether its underlying cause is instrumentation or the runtime. No second
continuation bridge, dependency fork or new suppression is introduced.

The [workflow receipt](experiments/nio-concurrency/local-workflow-gates.json)
records the stable tested-tree fingerprint and log hashes. Documentation-only
receipts were added afterwards and their checks rerun before push.

The installed candidate's earlier
[normal-machine verification](verification-runtime-installed-2026-10-29.md)
remains evidence for that exact candidate. The production pool repair needs a new
candidate and its own release validation. The serving app is not stopped or
replaced by this investigation.

## Hosted Quit deadline follow-up

The [first hosted checkpoints](experiments/nio-concurrency/hosted-workflow-checkpoints.json)
ran the same head. Release passed all 3,780 tests, four skips, optimized PAC
checks and complete ad-hoc ZIP/DMG verification with no NIO misuse. Swift failed
one no-stream Quit test: its final read reported `unsettled` after 10.836 s.
There was no NIO misuse in that run either. The log cannot distinguish pending
Quit work from a lookup that missed its 200 ms remaining deadline; both are
permitted expiry under decision 0039.

The test now controls the existing keep-caller wait through one package sleep
effect whose default is the original `Task.sleep`. It holds the final declared
save through the routine's pending lookups, proves the caller is held, releases
the save, observes actual host completion and operation settlement, then releases
the final read. It checks the real Quit receipt, saved values and cleanup. The
real-clock held-teardown and exhausted-budget tests retain expiry coverage.
Nothing adds another Quit algorithm, host timing dependency, public type or wire
change.

Both repaired tests passed 20 isolated strict trials each. Eighteen focused
client/Quit tests passed, and all 76 affected host/client tests passed TSan
without suppressions. The [independent Claude review](experiments/nio-concurrency/quit-fallback-review.md)
accepted the wait, cancellation, bounded recording and task joins; its early
setup release gap was closed before final gates. Removing the final lookup
failed both intended receipt assertions; exact
restoration passed. An injected early setup error ended normally with the
expected test error in 1.505 s, confirming task cleanup; restoration passed.
The [semantic](experiments/nio-concurrency/quit-semantic-controls.json),
[cleanup](experiments/nio-concurrency/quit-failure-control.json) and
[repeat](experiments/nio-concurrency/quit-strict-repeat.json) receipts retain
those outcomes. The [final workflow receipt](experiments/nio-concurrency/local-workflow-gates-quit-followup.json)
records all 20 steps passing on the stable `db11f4ab` tree: 3,780 tests, four
skips, zero failures/misuse diagnostics and 104 simulator cases. Perf passed at
10.13 s and 34,783,232 bytes maximum RSS. Only documentation receipts/status
wording were added after that run, with their checks rerun before push.

The separate Swift continuation finding remains tracked in [issue #118](https://github.com/srps/Conduit/issues/118).
The full unsuppressed TSan run remains failed; scoped passes do not erase it.
