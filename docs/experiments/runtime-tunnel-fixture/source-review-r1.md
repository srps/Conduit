## Review of the frozen tunnel test change

**Verdict: one required test-only fix, in `MockProxyDials`. Otherwise ACCEPT.** This is a read-only review of the frozen patch: I didn't rescan Source, and edited and ran nothing.

### Required fix: `MockProxyDials.join()` doesn't close the record
- **What's wrong:** the comment says "A dial recorded later fails at once, because the gate has already failed." That's only true if `release()` was never called. Once the gate has succeeded, `gate.fail(NeverReleased())` in `join()` does nothing. NIO ignores completing an already-completed promise.
- **The gap:** after a release, a CONNECT that reaches the mock after `join()` takes its snapshot still gets recorded. Its `gate.futureResult.flatMap { connect() }` starts a default-resolver dial at once, and nothing joins it. That's exactly the crash this test exists to rule out.
- **Is it reachable?** It needs a second CONNECT after `join()`'s snapshot. That could be a retry or a fresh-connection attempt, or a late-arriving CONNECT header on a child the mock already accepted; the mock's listener is still open during `join()`. It's unlikely in this test, but the cap of 4 shows more than one CONNECT was expected.
- **Fix (test-only, small):** keep a `closed` flag in the same lock as the dial list.
  - `join()` sets `closed = true` and takes the snapshot under that lock, then fails the gate.
  - `dial()` returns nil once `closed` is set, and the mock already closes the CONNECT in that case.
  - That makes "no dial in flight when the group shuts down" true on every path, and the comment accurate. No production API is involved.

### Checks that pass on reading
- **No double completion:** every promise is completed more than once by design, and NIO ignores the later calls. This covers:
  - `requested.succeed` per dial;
  - `signal.succeed` per matching log line;
  - `bytesArrived.succeed` per read;
  - the teardown `fail`s;
  - `awaitSignal`'s timeout failing a promise that is then failed again.
  
  Calls from another thread are executed on the promise's own loop, which is still running until `tearDown`.
- **No unbounded wait:**
  - Each `awaitSignal` is limited to 5 s by a task scheduled on the promise's loop and cancelled in `defer`. The three waits run one after another, each bounded.
  - In `join()`, gated dials fail as soon as the gate fails. Released dials are limited by the 5 s `connectTimeout`, which in HappyEyeballs also covers resolution.
- **No lock re-entrancy:** `flatMap` inside `withLockedValue` may run `connect()` synchronously, but `connect()` never touches `recorded`. `requested.succeed` is called outside the lock.
- **Swift 6.3 capture hazards:** none found.
  - The test body's `var`s are never captured by an escaping closure.
  - `configProvider` captures the `let fixedConfig` copy.
  - The `onReceive` and `connect` closures capture only `let` values or Sendable boxes.
  - `MockProxyDials` (final, Sendable `let`s) and `TunnelLogSignal` (final, immutable `let`s) need no `@unchecked`.
  - There are no nested functions capturing mutable locals.
- **Coverage is meaningful:**
  - The OP_MSG is checked bit for bit at the target through the real proxied forwarder, and `ProtocolDetector.detect` returns `.mongodb`.
  - The real handler's log line is checked exactly, once, at `.info`. It matches the format at `TunnelForwarder.swift:701`.
  - The held-dial witness ("no bytes at the target while the dial is held") shows that the detection log comes before the bytes arrive, which is the ordering flaw in the old fixture.
- **PostgreSQL narrowing is acceptable:** PG detection is covered at the unit level in `ProtocolDetectorTests`, and the handler's detection-and-log path is the same for every protocol.
- **Error cleanup:** teardown runs on every path. The order is client, `forwarder.stop()`, `join()`, mock proxy, target, `pool.closeAll()`, then the leftover promises are failed. Close and dial failures are reported, and the body's error is rethrown.
- **Removal-only control:** I agree with the prediction. Without `dials.release()`, the test fails with "the OP_MSG at the target did not arrive within five seconds". `join()` then fails the gate before any resolver starts, the mock answers 502 and closes, and nothing crashes.
  - Run it after the `closed` fix too. The fix doesn't change this path.

### Accepted scoped limit: the forwarder's own pool dial isn't joined
- I accept leaving this as a stated limit rather than requiring a test fix.
- The pool dials an IP literal, so `AddressFamilyAwareResolver` completes the lookup on the event loop. No lookup is in flight on a dispatch queue that could deliver to a dead loop later.
- That connect is to the mock's loopback listener. A channel still pending is closed and its promise failed during graceful shutdown, so there's no leak.
- Joining it would need a production lifecycle API, which nothing here justifies.
- The cross-loop `close(promise: nil)` propagation after teardown is the same as in the existing forwarder tests. Without a promise, it can't leak.

### Limits
- I can't tell whether it compiles under Swift 6.3.3 optimized, or whether it passes. Your focused runs, the repeats, the control and the hosted Release run are still owed.
- The original CI crash's source is still likely but unproven.