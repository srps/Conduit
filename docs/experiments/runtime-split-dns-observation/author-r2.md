R2 is in place and frozen; I haven't compiled or run anything. Two edits are in the host test and one doc-comment edit is in the unit test. The production file and the unit test's body are unchanged from R1. No production statements, policy or wait budgets changed.

## `DaemonRuntimeHostTests.swift`

**Removed:** the counted matcher, its `NIOLockedValueBox`, and `import NIOConcurrencyHelpers`. The two remaining `removals` hits in the file belong to an unrelated test's local variable.

**Doc comment:** now says two holds fix the order the outcomes are recorded in: the write, then the drop, then the correction.

**New history, two hand-over holds, both on `.platform-work`, both matching `removeDNS`:**

1. **First hold:** while `getenv` is still held, it is armed for the first `removeDNS` (the drop's), and `beforeWrite = host.splitDNSRepair.generation` is captured. Then `release()` lets the drift pass go.
   - A bounded `waitUntilReached(within: .seconds(5))` waits for the drop's removal to be held, and is asserted.
   - The existing 5,000 × 1 ms poll then waits until `generation != beforeWrite`, which is asserted. While the drop's removal is held, only the write can be recorded.
   - **Assertions:** `isHolding`; `reachedOnArmedQueue`; no `removeDNS` has reached the helper; failures `[]`; nothing superseded; pending `nil`.
2. **Second hold:** while the drop's removal is held, the hold is armed for the next `removeDNS` (the correction's). Then `release()` lets the drop's removal be refused.
   - A bounded 5 s wait for the correction to be held, asserted, then the existing poll until a failure is recorded.
   - **The R1 intermediate assertions, all kept:** `isHolding`; `reachedOnArmedQueue`; exactly one `removeDNS`; failures `[attempt=1]`; nothing superseded; pending remove/`vpnTransition` with 1 attempt.
3. **Final:** `release()`, then the same `reload.value` join, delivery drain and **every** original final assertion.
   - The final no-superseded check is still the original inline expression.
   - The final failures check uses `failures()`, the same expression as in R1. I added a matching local `superseded()` for the intermediate checks only. Both capture only `let events`.

**Error paths:** if an armed call never arrives, the next `release()` sets released-early, so the call is let through when it comes. Harness teardown still runs `releaseAll()` and the cooperative-pool check, so a failed run doesn't hang or leave a hold.

**Controls you planned:** removing either `arm` makes that stage's `isHolding` assertion fail deterministically, and teardown stays safe. As the reviewer noted, `waitUntilReached` on its own isn't the causal check. The `isHolding` assertion, the helper command counts and the `generation` barrier are.

## `SplitDNSEntryFileRepairTests.swift`

The new case's doc comment now calls the history the one the hosted run's failed assertions **imply**. The run's event details weren't captured, so the order is inferred, not observed. The test body and the clarified older comment are unchanged.

## `SplitDNSEntryFileRepair.swift`

Unchanged since R1: the comment-only `queue()` doc edit. Its executable lines are identical to before, matching your mechanical check.
