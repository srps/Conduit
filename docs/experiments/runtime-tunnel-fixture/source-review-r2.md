## R1→R2 delta review

**Verdict: ACCEPT.** I reviewed only the R1→R2 delta, read-only: I compiled and ran nothing.

**The required fix is done correctly**
- `closed` and the dial list now share one `NIOLockedValueBox<Record>`.
- `dial()` checks `!record.closed` under that same lock before recording anything.
- `join()` sets `closed = true` and takes its snapshot in one locked step, and only then fails the gate and `requested`.
- So nothing can be recorded after the snapshot, whether or not the gate was released. A refused CONNECT goes through the mock's existing `nil` branch, which closes the CONNECT. The doc comments now match this.

**The new witness, `testJoinedMockProxyDialsAdmitNoLaterDial`, is causal and safe**
- **No network:** the `connect` closure only counts calls and returns a failed future on `loop`.
- **Released branch:** the gate has already succeeded, so only the `closed` flag can refuse the late dial.
  - With `!record.closed` removed, the dial is admitted, `flatMap` runs `connect`, and `lateDialOutcome` reports "admitted, then failed". The `XCTAssertNil` fails and the count becomes 1.
- **Held branch:** the gate has failed.
  - With the guard removed, the dial is admitted and fails with `NeverReleased` without calling `connect`, so the assertion fails and the count stays 1.
  - The author's prediction for the closed-guard control is correct.
- **Every promise is settled:**
  - `requested` is failed by `join()` in both branches.
  - The gate is succeeded in one branch and failed in the other.
  - Any admitted dial future completes.
  - Repeat completions are ignored by NIO, so nothing completes twice and nothing leaks.
- **Bounded and isolation-safe:**
  - `lateDialOutcome` awaits a future that has already completed or will complete at once.
  - Captures are a `let` loop and a `NIOLockedValueBox`, with no mutable locals.
  - The test is nonisolated `async`, and the static helper is too.

**tearDown change**
- The only change is that `XCTAssertNoThrow(try group.syncShutdownGracefully(), …)` reports a shutdown error instead of discarding it.
- No test in the snapshot shuts the group itself (grep finds only `setUp`/`tearDown` and the mock's stored `group`), so this can't produce a spurious double-shutdown failure.

**Unchanged:** `ProxiedTunnelTests.swift` and the R1 integration test body.

**Limits**
- I can't tell whether it compiles under Swift 6.3.3 optimized, or how the 24 focused tests, the three controls, all 41 checks and the hosted Release will turn out. You're running those.
- The historical CI crash's source is still likely but unproven.
- The forwarder's own pool dial stays a stated, accepted limit.