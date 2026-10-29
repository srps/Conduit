# Tunnel fixture shutdown and streaming auth reset: independent review

Verdict: **ACCEPT**. Neither delta has a blocker.

Scope: read only. I read root `AGENTS.md`, `followup-review.patch`, `strict-post-shutdown-stack.txt`, the worker notes (`tunnel-fixture-shutdown-findings.md`), the current `TunnelForwarderTests.swift`, `AsyncChannelCleanup.swift`, the relevant parts of `ConnectionPoolConcurrencyTests.swift` and `ConnectionPoolTests.swift`, the production callbacks in `TunnelForwarder.swift`, `CONNECTHandler.swift` and `ConnectionPool.swift`, and `docs/experiments/nio-concurrency/` (the probe, the README and both reports). I built and ran nothing. The current tunnel and pool fixture code matches the patch at every point I checked. I did not repeat the production pool audit.

## 1. TunnelForwarderTests: post-shutdown close

### The original trap
The stack shows loop #1's `Selector.closeGently` closing a still-registered mock CONNECT child. Its `ConnectHandler.channelInactive` then calls `upstream?.close` on the dialed channel, which lives on loop #0. Loop #0 had already shut down, so `SelectableEventLoop.swift:483` trapped. The cause is ownership, not a missing `isActive` guard. Closing a listener does not close its accepted children, and `MockProxyDials.join()` waits only for dial futures. The fix addresses that cause.

### Teardown ordering: correct
- `mockChannels()` is the first teardown registration in every test that uses it (`TunnelForwarderTests.swift:49, 108, 180, 393`, the DNS-override and session-limit tests). Blocks run LIFO, so the order is:
  1. the body and its `defer { pool.closeAll() }`;
  2. `closeAtTearDown` for the client, which starts the cascade, then the listeners;
  3. `settle()`;
  4. `tearDown()`'s `syncShutdownGracefully()`.
- NIO's `close0` fires `channelInactive` synchronously; the stack's frames 16–17 show this. `closePromise` completes after that. So `closeFuture` completion on a recorded channel means its handler's cross-loop `close` was already enqueued on a live loop, and graceful shutdown drains those tasks. Every mock handler's cross-loop close is therefore ordered before shutdown:
  - `ConnectHandler.channelInactive` at `:946`;
  - `SimpleRelay.channelInactive` at `:964`;
  - the `clientGone` close at `:922`.
- `closes(_:by:)` at `:1101` completes one promise from `closeFuture` and from a `scheduleTask(deadline:)` timer, both on the channel's own loop. A second completion is ignored. There is one shared 5 s deadline, and the timer is cancelled after fulfilment. It is bounded.

### Late admission: correct
- `admit` at `:1060` and `settle`'s snapshot at `:1076` share one lock. A channel offered after the snapshot is refused before any handler is added. The bootstrap then closes it with an empty pipeline, so nothing on it can reach another loop.
- This covers:
  - children accepted while their listener closes;
  - the mock's own dial channels, because `ClientBootstrap.channelInitializer` runs before connect (`:893`).
- Refusals at capacity are counted and reported. A refusal after `closed` is not reported. That is right, because by then the test is in teardown.

### Dial completion and `clientGone`: correct and loop-confined
- `clientGone` is written in `channelInactive` on the child's loop. It is read in the dial callback after `.hop(to: clientEL)` (`:915`), which is the same loop and the same handler instance, so there is no race.
- The new branch at `:919` closes a dial that connects after the client left. That dial was admitted, so `settle()` waits for its close.
- This mirrors production `ProxiedTunnelClientHandler.handleConnectResult` at `TunnelForwarder.swift:621-627`.
- The guard is a state check, not an `isActive` mask. The peer closes at `:948` and `:965` are unchanged.

### Failure-path cleanup and bounds: adequate
- The MongoDB test runs in this order: client close, `forwarder.stop()`, `dials.join()`, proxy and target close, `pool.closeAll()`, fail the two signal promises, then `settle`. Every promise is completed, and every await is bounded:
  - `awaitSignal`: 5 s;
  - mock dial: `connectTimeout` 5 s;
  - settle: 5 s.
- Capacity 16 against at most 3 channels per test (child, dial, echo child). `MockProxyDials.capacity` is 4.
- A leaked mock channel is reported as `XCTFail` and then force-closed on a live loop, before shutdown, so it cannot turn into a strict trap.
- The parent's injected `TestEnded` with the dial held matches the trace: normal failure, no strict trap. Proven arms are counted only at the parent's stated level. The 20 isolated repeats were still in progress.

### Forwarder-owned channels: concrete assessment
These channels are the forwarder's accepted tunnel child T and its upstream U. Nothing records them.

- **Success path (client closes first).**
  1. T's `channelInactive` (`TunnelForwarder.swift:731` proxied, `:887` direct) closes U across loops.
  2. U's `TunnelPeerRelay.channelInactive` (`:926` → `:940-944`) sees T inactive and enqueues `T.close` on T's loop.
  3. That enqueue happens inside U's `close0`, a few calls after U's `socket.close()` sends the FIN that the mock child M or the echo child E eventually reads.

  `settle()` observes only M, D and E. So `T.close` is not formally ordered before shutdown. For a trap, everything below would have to fit between U's `socket.close()` and the next few synchronous statements of the same `close0`:
  - M or E wakes, reads EOF and closes;
  - the `closePromise` task runs;
  - the Swift task resumes;
  - XCTest runs `tearDown`;
  - T's loop finishes shutting down.

  That is not a realistic interleaving, and it needs T and U on different loops. Not a blocker.
- **Failure path (the mock closes first: a held dial ended by `join()`, the 502, then M closes).**
  1. U reads the 502.
  2. `CONNECTHandler.swift:160-169` closes U, then fails the future.
  3. `ProxiedTunnelClientHandler` hops the failure to T's loop (`TunnelForwarder.swift:608`).

  M's close does not order that hop. This window is wider than the success-path one, but it opens only after the test has already failed. The parent's injected run went through it without a trap. A mock-side fix (keep M open after the 502 until U closes) would not close it either: U closes at `:161` before the failure propagates. Only a forwarder seam, for example a `stop()` that joins sessions, closes it. The worker's residual-risk note is accurate and is not hidden.

### Actionable findings
None.

### Optional future work
- If strict-mode flakes ever point at a forwarder handler (frames in `ProxiedTunnelClientHandler`, `DirectTunnelClientHandler` or `TunnelPeerRelay`), consider a `TunnelForwarder` session join. That is a Sources decision; do not add a public test hook for this.
- `testSessionLimitRejectsExcessConnections`: `client2` is not registered for teardown. If `Task.sleep` throws in the `do` block, `client2` survives to group shutdown. It has no handler, so this is cosmetic.

## 2. ConnectionPoolConcurrencyTests: streaming auth reset

### Causality is sound
- `performStreamingExchange` (`ConnectionPool.swift:1228`) captures `authenticationState()` before the exchange. Its completion (`:1258-1261`) calls `markAuthenticated(since:)`, which is generation-guarded, then `release`, and only then succeeds the future.
- Because `release` comes first, the test's assertion that one connection was accepted (`accepted == 1`) is deterministic rather than timing-dependent.
- The streaming promise is succeeded from `finish` only after the client `.end` write completes (`ConnectionPool.swift:1841-1867`, `succeedStreaming` at `:1928`). Head, body and end are therefore already in the testing channel's outbound buffer when `first.get()` returns. The drain in `assertForwardedOK` cannot miss parts or race.
- The negative control showed that reverting only the streaming completion fails only the streaming test's credentials assertion. That is the right discriminator.

### Fixture checks
- The client is a thread-safe `NIOAsyncTestingChannel`. `connect(to:)` only marks it active, and `.end` needs it active. `finishAtTearDown` requires it to be clean. The success path drains it twice, which proves exactly `["head 200", "end"]` per exchange.
- Credential presence is recorded as a `Bool` only (`ConnectionPoolConcurrencyTests.swift:352` area). No header bytes are kept or compared; the token is a fixture.
- Bounds:
  - 16 KiB is checked before the copy (`:342`);
  - request records are capped at 3, and a third request closes the connection;
  - `firstRequest` deadline: 10 s;
  - response timeout: 10 s;
  - `defer` cancels the deadline;
  - a teardown block fails the promise, which is a no-op once fulfilled.
- `first.whenFailure { firstRequest.fail }` turns an early exchange failure into a prompt test failure instead of a 10 s wait.
- Throw path: teardown runs LIFO, as follows. An exchange still in flight then writes to a finished channel and fails, so nothing hangs. If the test throws mid-exchange, `isClean` adds a second failure, which is acceptable.
  1. Client `finish`.
  2. `pool.closeAll`.
  3. Server close.
  4. `firstRequest.fail`.
- The upstream's accepted children are not closed by the listener close, but the pool's FIN closes them. All of this runs on the perpetual singleton, so there is no shutdown hazard.
- `AnswerAfterRequestHandler` (`ConnectionPoolTests.swift:932-951`) now checks the 8 KiB ceiling before `writeBuffer`. Confirmed.

### Actionable findings
None.

### Optional
- `CloseAfterRequestHandler` (`ConnectionPoolTests.swift` ~`:918-926`) is pre-existing and outside this delta. It still accumulates without a ceiling. Give it the same guard in a later tidy-up.

## 3. TSan continuation report classification

### The probe contains no intentional race
- The single slot and the `finished` flag are accessed only under `NSCondition`. Work is taken out under the lock and run outside it.
- `precondition(pending == nil)` holds. The next `execute` happens only after the previous continuation resumed, and that resume happens after `pending = nil` under the lock.
- Each `UnsafeContinuation` is resumed exactly once. Resuming before the body returns, as in resume-first, is legal.
- `Payload` is an immutable `final class`. `Resumer`'s `@unchecked Sendable` is justified by the lock.
- The join is bounded at 30 s. `usleep` only shifts timing.
- The line references in `continuation-runtime-report.txt` (`:110`, `:91`, `:56`, `:165`) match the committed `continuation-handoff.swift`. The report names the scratch file `tsan-continuation-handoff-repro.swift`, which is a cosmetic provenance mismatch.

### The reports match
Both reports have the same shape:
- an 8-byte write in `withUnsafeThrowingContinuation` from `runJobInEstablishedExecutorContext` on a GCD worker;
- a previous 8-byte read in `UnsafeContinuation.resume(returning:)` on the resumer thread (in the app, the NIO loop via `EventLoopFuture.get()`, `AsyncAwaitSupport.swift:90`);
- the same 1016-byte heap block allocated from `runJobInEstablishedExecutorContext`, which is the task allocator's slab.

The probe has no Conduit and no NIO code.

### Interpretation
The controls separate the cases:
- handoff and resume-first report;
- await-first (50k) and inline (200k) do not.

This points at the path where the continuation is already resumed when the task awaits, so the task continues without suspending. On that path the only synchronisation is libswift_Concurrency's internal atomic status exchange, which TSan may not model. On the await-first path the task re-enqueues through dispatch, which TSan intercepts, and that gives it a happens-before edge. Task-allocator memory is then reused by the next await's continuation context, which yields exactly the reported write after read. This is consistent with swiftlang/swift#57803.

**Decision:** the evidence supports recording this as a separate, independently reproducible Swift-runtime continuation / TSan finding, not a Conduit ownership defect. It does not establish whether the cause is instrumentation alone or a real runtime ordering bug. It does not make the full TSan suite a pass, and it does not prove Conduit's concurrency correct. The README already says both, and that wording is right.

### Optional
- To strengthen the upstream report, run the same probe with `withCheckedThrowingContinuation` as a variant.
- Add a control that adds an explicit lock edge after the await: the resumer sets a flag under the condition, and the task reads it after the await. If the report disappears, only a happens-before edge was missing, which points at instrumentation.
- File a new upstream issue with the probe and the exact toolchain. Do not reopen #57803 by reference.

## Parent-owned, not assessed here
The full strict workflow gates, the TSan checks, the 20-repeat result, hosted PR babysitting and validation of the new candidate.
