# Focused follow-up review: NIO fixture lifetimes, pool tests, pool simulator

- Repo: `/Users/SIS8LIS/.codex/worktrees/runtime-client-events/Conduit`
- Branch: `codex/fix-nio-test-concurrency`, base `15aabc1`
- Diff reviewed: `private-verification/final-code.patch` (immutable). I also
  read current sources where a finding depended on them: `ConnectionPool.swift:775-990`,
  `OutboundSocketRegistry.swift:116-135`, `HTTPProxyHandler.swift:1633-1728`,
  `StreamingExchangeTests.swift:226-251`, and the pinned NIO checkout (`Embedded.swift:568-598`,
  `BaseSocketChannel.swift:905-974`, `AsyncTestingEventLoop.swift:233-242`).
- How: read-only. Nothing was built or run, and no repo, memory or settings file was edited.
  The production locking audit (`pool-independent-review.md`) was not repeated.

## Verdict: ACCEPT (test and simulator follow-ups)

This follow-up introduces no blocker. Every earlier blocker is fixed in the final diff. The
items under "Optional" are fidelity and hygiene points. None of them causes a hang, a hidden
error, a weaker assertion or a race in the current code.

## Earlier blockers: all resolved

| Earlier finding | Final diff | Status |
|---|---|---|
| Pool review #1: the reset test hangs if the first exchange fails before its request reaches the upstream | `ConnectionPoolConcurrencyTests.swift` (patch :3138) `first.whenFailure { firstRequest.fail($0) }`, plus a 10 s `scheduleTask` deadline that fails the promise (:3108-3111, cancelled by `defer`) | Resolved. An early exchange failure now ends the wait with the exchange's own error. A fixture that never sends a request ends at 10 s. The teardown `fail` stays as a leak guard; completing the promise twice is a no-op. |
| Pool review #2: the retirement tests hang if `retire` leaves a channel open | patch :3055-3058 closes each channel before awaiting `closeFuture` | Resolved. The probe only appends after `seen` was read, so the extra close cannot change an assertion. |
| Pool review #3: same shape in the dedicated-tunnel test | patch :3092 | Resolved. |
| Pool review, optional: 600 s response timeout | patch :3131, now 10 s | Done. |
| Pool review: no raw credentials kept | `HeldFirstResponseHandler` keeps a `[Bool]` and reads only into a transient bounded buffer (16 KiB checked **before** the copy, :3229). The pm-sim upstream compares only the header-name prefix (:2936-2938). | Resolved. The test fixture compares against the fixed fake token `fixture`, never a real credential. |
| Harness review B1: two VPN tests mutate `gone` while the previous pass 0 may still be checking | patch :2282 (`.connected`, then `until held`) and :2645 (`.disconnected`, then `until held`) | Resolved. A held delay proves that transition's pass 0 finished before the sockets are tracked. In the reconnect test, the cancelled `.connected` task cannot take the slot: `HeldDelays.sleep` checks `Task.isCancelled` in the same locked step that would hold it. |
| Harness review B2: the owed full-path re-sweep was proved only by a label | patch :2337 (`offVPN`) and :2368 (`onVPN`) now use `moved` | Resolved. Both tests now need a `phase=paths` sweep to close a route-moved socket. The `findStranded(addressesOnly: true)` mutant fails them. |
| Harness review, optional 3: simulator fixture closure | patch :2821-2828. The pool is closed and each `closeFuture` is awaited, then the listener and every child, each bounded by `within`. `alreadyClosed` is the only error that is tolerated. | Done. The child's own EOF close and ours run on the same loop, so the loser gets `alreadyClosed`. |
| Harness review, optional 2: `Gate` with a late waiter | `opened` flag (:2534-2541) | Done. |

## Fixture lifetimes: checked

**Synchronous `EmbeddedChannel` / `EmbeddedEventLoop` fixtures**
- Every channel and loop that was converted is finished, or shut down, in a `defer` on the
  thread that created it. No embedded channel crosses an `await`. The tests that still use
  embedded channels are synchronous `throws` functions.
- Finishing is now `XCTAssertNoThrow(try …finish())`, so close or pipeline errors fail the test
  instead of being swallowed by `try?`. `acceptAlreadyClosed: true` appears only where a
  production path closes the channel. I checked each case against the code:
  - the forwarder's `errorCaught` / `fail` (`HTTPProxyHandler.swift:1708-1727`);
  - the upgrade relay's splice;
  - registry refusals and sweeps (`ConnectionPoolMigrationTests`, `OutboundSocketRegistryTests`);
  - the forwarder closing the client mid-response.
- Where `finish()` has no `acceptAlreadyClosed`, the channel stays open. For example,
  `testForwarderResumesUpstream…` forwards no head, so `fail` does not close the client (:1724).
- `defer` runs in reverse order, so the upstream channel finishes before the client channel.
  - In the forwarder tests that send `.end`, `settled` is set and the upstream's inactive does
    not close the client.
  - In the tests that send no head, the client is never closed.
  - So the client's plain `finish()` cannot meet `alreadyClosed`.
- The per-test arrays (`dialedChannels`, `channels`) live on the XCTest instance, which is new
  for every test. Every test that calls `dialed()` / `channel()` has the matching `defer`
  (`ConnectionPoolMigrationTests.swift:72-157`, `OutboundSocketRegistryTests.swift:61-157`).
  The two tests in `ConnectionPoolMigrationTests` without it make no dialed channels.
- `GatewayReachabilityProbeTests`: `syncShutdownGracefully()` on the embedded loop runs on the
  thread that created it, in a `defer`.

**Async fixtures (`NIOAsyncTestingChannel`)**
- Everything that outlives an `await`, or that the pool, a policy or a sweep touches from another
  loop, is now an `NIOAsyncTestingChannel`. An off-loop `execute` there goes onto the loop's
  serial queue and runs right away (`AsyncTestingEventLoop.swift:237-240`).
  - So the comment in `testAuthHandshakeLimitDoesNotRecordStreamingUpstreamFailure` holds: the
    observer install and removal are queued before the exchange fails, and `finish()`'s close
    is queued after them.
  - Likewise, `drain()` in the VPN tests orders after every close requested before it.
- **The throw path is covered.** `finishAtTearDown` registers `finish(acceptAlreadyClosed: true)`
  plus an `isClean` assertion at creation, before any operation that can throw. Bodies that
  also finish inline (to assert "writes nothing") are compatible with this:
  - the second `finish` accepts `alreadyClosed`;
  - it re-reports the same leftover buffers, which are not cleared;
  - so the result is clean twice or dirty twice, with no masking.
- **No references or teardown escape the test.**
  - VPN: `tracked` channels finish in teardown blocks registered after the orchestrator's
    block, so they run first (reverse order). The orchestrator block then runs
    `delays.finish()` and `stopProxy()`.
  - A sweep task that is still running can only close an already-finished channel, which gives
    `alreadyClosed` and is ignored by NIO. It cannot hold a delay, because `finished` refuses
    it.
  - Every `Task` the tests start (gate holders, the startup-hook disconnect, the AppState
    releases) is awaited, in the body or in a teardown block.
- **DNS:** `tearDown()` now uses `try await channel.finish()`, so pipeline errors from
  `throwIfErrorCaught` are reported. The extra teardown block covers a test that throws before
  reaching `gate.tearDown()`. Discarding its leftovers is deliberate: response packets stay
  unread, as the comment says.

**`AsyncChannelCleanup.swift` (25 lines)**
- Cohesive and test-only: an `XCTestCase` extension with two teardown registrars.
- Errors are reported:
  - `closeAtTearDown` ignores only `ChannelError.alreadyClosed`. Every other error is thrown
    from the async teardown block and fails the test.
  - `finishAtTearDown` throws on a finish error and asserts `isClean`, at the caller's
    file and line.
- No production type, no global state and no second shutdown path. Production code does not
  depend on it.

## Deterministic pool-exhaustion replacement: correct

`ConnectionPoolTests.testPoolExhaustedWhenMaxConnectionsReached` (patch :1104-1184) no longer
uses timing. I traced the order:

1. The first exchange's `acquireConnection` increments `pendingConnectionCount` to 1 under the
   pool lock (`ConnectionPool.swift:801-807`).
2. The real loopback connect completes. `makeConnection`'s `flatMapThrowing` calls `insert`, then
   `insertDialedConnection`, then `sockets.register` (`:984-985`, `:954`).
3. `register` calls `paths.verdicts` synchronously, **before** taking the registry lock
   (`OutboundSocketRegistry.swift:122` vs `:125`). The pool lock is not held either: it is only
   taken at `:958`, after `register` returns. So the nested `pool.exchange` re-enters no lock.
4. At that moment `allConnections.count == 0` and `pending == 1`. The decrement is in the
   `.always` that is chained on `makeConnection`'s future (`:819-823`), which only completes
   after `insert` returns. So `0 + 1 >= 1` gives `.exhausted` on every run.
5. A real socket always has the addresses `Self.query` needs, so the path check always runs.
   The box hands out the pool once, so the closure starts exactly one second exchange and breaks
   the pool → registry → box cycle.

The assertions are stronger than before:
- the first exchange must return 200;
- the second must exist and fail with `.poolExhausted`;
- the old "any other error is acceptable" escape is now an `XCTFail`.

The old blackhole upstream `192.0.2.1` and the 50 ms sleep are gone.

## Mid-response fixture: necessary and safe

- Pinned NIO's `EmbeddedChannelCore.close0` (`Embedded.swift:568-598`) does not fail
  `pendingOutboundBuffer`. The unflushed head's promise would therefore stay unfulfilled, and
  the debug leak check traps.
- A real socket fails pending writes on close (`BaseSocketChannel.swift:951`).
- `FailUnflushedWritesOnClose` sits next to the head (it was added first, so the encoder's bytes
  pass through it). It holds writes until flush and fails them with `ioOnClosedChannel` on
  close. That is the same error that NIO's head handler passes to `close0` for `.all`.
- It is bounded (`precondition(count < 8)`) and confined to the test thread.
- The test's assertions are unchanged, and none of them observes the write promise:
  - `fail` calls `backpressure?.complete()` before closing the client (`HTTPProxyHandler.swift:1723-1726`);
  - the forwarder never reads the head write's result.

## Pool simulator (`pool-auth-reset-during-exchange`): no new findings

- The size check comes before the copy (:2925). After each complete head is parsed, `received`
  is trimmed, so the capacity arithmetic cannot go negative.
- Every wait in the positive path is bounded by `within` (5 s; the deadline is cancelled when the
  result arrives).
- Cleanup stays registered as the backstop for the throw path.
- The parent's negative control (auth-reset generation ignored → exactly the two expected
  assertions fail, exit 1; restored → pass) is consistent with the order the scenario forces.
  I did not rerun it.

## Optional (not blockers)

1. **Ordering fidelity of `FailUnflushedWritesOnClose`** (`StreamingExchangeTests.swift`, the
   new handler):
   - A real socket fails pending writes **before** the close promise and `channelInactive`
     (`BaseSocketChannel.swift:951` vs `:963`). The fixture fails them after.
   - It also keeps writes that arrive after the close, where a socket fails them at once.
   - Neither difference is observable in today's test. If the fixture is reused:
     - fail `writes` before calling `context.close`;
     - in `write`, fail the promise at once when `!context.channel.isActive`.
2. **`AnswerAfterRequestHandler`** (`ConnectionPoolTests.swift`, end of file) appends without a
   bound until it sees `\r\n\r\n`. The pool sends a small well-formed head, so this cannot grow
   in practice. A 16 KiB cap checked before the copy would match the other two upstream
   fixtures.
3. **Scope of "remaining owned event-loop groups".** Untouched files still create
   `MultiThreadedEventLoopGroup(numberOfThreads:)` inline with no visible shutdown. Examples:
   - `UpstreamFailoverTests.swift:28,71,109,143`
   - `CircuitBreakerWindowTests.swift:31`
   - `ConnectTimeoutTests.swift:17,70,100,…`
   - `AuthHandshakeIntegrationTests.swift:19,…`

   I only looked at the two lines after each match. I did not check the `setUp`-owned groups for
   a matching `tearDown`. These are outside this diff and not part of the inventoried fixture
   set, so I would describe the repair as "in the touched and inventoried files".
4. `closeAtTearDown` has no doc comment, while its sibling has one. This is cosmetic.

## Limits of this review

- **Not compiled or run.** My compile-level confidence comes from the parent's reported
  strict-mode run (178 NIO fixture tests, 0 misuse diagnostics), the focused 156-test run, and
  the normal and TSan simulator runs, not from any build of mine.
- **One schedule is not a proof.** The determinism claims above come from reading the code: the
  register-before-lock order, the `.always` decrement, the inline close probes, and the held
  delays. A single passing TSan schedule does not establish concurrency correctness in general.
  I make no claim about interleavings outside the paths named above.
- The production synchronization in `ConnectionPool.swift` and the orchestrator delay seam were
  accepted in earlier reviews. I re-read only the lines this review depends on:
  `ConnectionPool.swift:775-990` and the orchestrator seam hunk (patch :500-542).
- The streaming generation path (`markAuthenticated(since:)` in the streamed exchange) is still
  verified by reading only. Neither test drives it.

## Checks that remain parent-owned

1. A full `swift build --build-tests` and `swift test` with `SWIFTNIO_STRICT=1`, plus a grep for
   `NIO API misuse` (expect 0), over the whole suite, not only the inventoried classes.
2. Broader TSan: `swift test --sanitize=thread` for the full suite, or at least
   `ConnectionPoolTests`, `ConnectionPoolConcurrencyTests`, `VPNTunnelMigrationTests`,
   `StreamingExchangeTests`, `DNSAdmissionGateTests` and `LinkLocalConnectPolicyTests`, repeated.
   Then `pm-sim all` under TSan.
3. Repeated runs of `VPNTunnelMigrationTests` and `ConnectionPoolConcurrencyTests` (for example
   50 times) to look for liveness outliers near the 3 s `until` and 10 s deadlines.
4. The negative controls requested earlier and not yet reported as run:
   - pool #1: an authenticator provider that throws → fails immediately;
   - pool #2: `retire` returning 0 → fails, does not hang;
   - B1: `usleep` in the paths closure;
   - B2: `findStranded(addressesOnly: true)` hard-coded;
   - the 10 controls in `vpn-deterministic-findings.md`.
5. A release-configuration test build (`release.yml:55`) and the full CI and release gates.
