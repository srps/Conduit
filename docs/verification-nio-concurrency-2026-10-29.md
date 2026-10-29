# NIO concurrency verification — 2026-10-29

Status: implementation, independent review and local workflow gates passed.
Hosted PR checks and a new candidate remain pending. The existing 0.6.0 draft
does not contain these repairs.

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
| Optimized tests and hosted PR checks | Pending |
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
