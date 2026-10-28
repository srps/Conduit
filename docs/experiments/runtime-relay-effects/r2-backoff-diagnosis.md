Read-only, as instructed. This is a missing causal barrier in the test, not a production fault. The 1b split-DNS offload widened the race window but didn't create the bug. The test changed in r2 only by a line shift.

## Cause
- **The test** (`AppStateActivationParityTests.swift:410-417`) emits the VPN drop, then goes straight into five iterations. Each one reads the failure count `before` from `events.ndjson`, calls `refreshPreflight()`, and settles until the count exceeds `before`. Then it asserts at least six failures.
- **It never waits for the drop's own refused removal before the loop.** Its sibling tests do (`:384` "the removal was refused", `:431` "the new removal was refused").
- **A preflight only retries when a repair is pending.** It ends in `observeHelperForSplitDNS(available:)` (`RuntimeHostPreflight.swift:92`), which guards on `splitDNSRepair.shouldRetry`, meaning `pending != nil` (`RuntimeHost.swift:1182`). A refresh that lands before the drop's failure is recorded correctly retries nothing.
- **Why the window is wider since 1b:**
  - The drop's removal now waits on `PlatformWork` and is recorded in a later turn.
  - The preflight reads the helper on a global queue and can finish first.
  - Before 1b the removal ran inline in the delivery's turn, so the failure was usually recorded before the preflight finished.
- **What happened in the failing run:**
  - Iteration 1 read `before = 0` and refreshed before the drop's failure was recorded, so no retry ran.
  - Its settle was then satisfied by the drop's own failure (`attempt=1 source=vpn_transition`, `swift-tests.log:795`).
  - Iterations 2 to 5 each got one retry (`attempt=2..5`, `:799-810`).
  - Total: 5, not 6. That's exactly one short, as the hypothesis predicts.

## Fix: one test-only barrier, no production change
After `harness.vpn.emit(.disconnected(reason: .networkLost))` and before the loop, add the same precondition settle the siblings use:
```swift
await harness.settle("the drop's removal was refused") { !self.hostEvents(harness, "platform.split_dns_failed").isEmpty }
```

**Why it's causal, not timing:**
- `SplitDNSEntryFileRepair.record` sets `pending` (`:179`) before it appends `platform.split_dns_failed` (`:183`), in the same synchronous call. The events writer is first-in, first-out. So a failure visible in the file means the repair is already pending, and every later refresh finds something to retry.
- The loop then guarantees the count by arithmetic, not by timing. The barrier makes `before₁ ≥ 1`. Each iteration's settle requires `count > beforeₖ`, so `beforeₖ₊₁ ≥ beforeₖ + 1`, and the count after five iterations is at least 6.
- That holds even if a 1 s helper-check retry interleaves: it only adds failures, and a preflight blocked by a retry already in flight is still satisfied by that retry's failure.

**Unchanged:**
- The assertion stays `≥ 6` with its message. There's no new sleep, and the loop and every later step stay as they are, including the existing 1.5 s sleep at `:418`.
- This settle is a precondition on the drop's own failure, not a poll of the asserted value.

## When you release
- **Ownership:** only `Tests/ConduitTests/AppStateActivationParityTests.swift`, one line.
- **Verification:** one fixed-wrapper run, which includes `AppStateActivationParityTests`, then your full workflow.
- **Manifest:** a new `runtime-actor-relay-r3-manifest.json` recording the r2 full failure, the cause, the barrier and the result. Relay production stays exactly r1.

The diagnostic plan is preserved and no logger work has started. Waiting for release.