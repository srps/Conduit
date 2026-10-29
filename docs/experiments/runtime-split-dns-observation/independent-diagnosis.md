**Diagnosis: the production code behaves as its selected contract says. The test assumed an order that was never selected: that the owner records outcomes in the same order the platform queue ran them. One production comment states that assumption as fact and should be corrected; no behaviour change is needed. This is a routine fix, with no architecture or policy question.**

I read the test, `SplitDNSEntryFileRepair.swift`, `PlatformWork.swift`, `RuntimeHost.swift` (lines 1125–1233 and 1861–1936), the events catalogue and the DNS-effects R1 review. The CI log isn't in this worktree, so the reconstruction below rests on the two assertion failures plus the code.

## What is actually guaranteed
| Property | Guaranteed? | Where |
|---|---|---|
| Physical FIFO | Yes. `PlatformWork` is one serial `DispatchQueue`, and each operation takes its place (`queue()`) in the same turn it is queued. | `PlatformWork.swift:11,32-37`; same-turn enqueue confirmed in R1 |
| Owner observation order | **No.** Each completion resumes a *different* task back onto `RuntimeActor`, a default actor. Swift actors don't promise FIFO order across tasks. | `RuntimeActor.swift:9-14` |
| Attempt identity | Each operation has a unique place. `attempts` counts only failures that are recorded, not superseded ones. | `SplitDNSEntryFileRepair.swift:144-179` |
| Supersession | An outcome recorded after a later-queued one is dropped (`startedAt < generation`), so the final state always reflects the physically latest operation, whatever order the owner records them in. | `:165-175`; `docs/events.md:349` defines the event for exactly this case |

R1 accepted this as a limitation: "Protection against priority-ordered resumption is untested until the RuntimeActor retag" (`r1-independent-review.md:90`). This CI run is the first time it was observed.

## Reconstruction (only one order fits)
There are three operations:
- **p1:** the switch-on's apply, which succeeds.
- **p2:** the VPN drop's removal, which is refused.
- **p3:** the switch-on tail's correction, queued at `RuntimeHost.swift:1894-1895` only *after* p1 is recorded. It goes through `reconcileEntryFiles`, so its source is also `vpn_transition`. It is also refused.

On the platform queue they always run p1, p2, p3. The owner can record them in two orders:
- **p1, p2, p3:** gives `[attempt=1, attempt=2]` and no supersession. This is what the test expects.
- **p1, p3, p2:** p3 records `remove vpn_transition attempt=1`, then p2 is dropped as superseded. This is **exactly the two observed failures.**
- Any order with p2 before p1 still gives attempt 1 and 2, and p3 can't be recorded before p1. So no other order matches.

**Check you can make:** the log's superseded event should read `operation=remove source=vpn_transition failed=true newer=1`.

**Not established:** *why* p3's task reached the actor before p2's. In the code, both tasks seem to inherit the test task's priority: the fake VPN `emit` is synchronous and `ObserverDeliveries` uses a plain `Task {}`. So whether the cause is priority ordering or the resumption hop on 6.3.3 is unproven. The fix doesn't depend on which it is.

**The production outcome was correct.** The final-state assertions (pending `.remove`/`.vpnTransition`, refused file still on disk, baseline landed, Stop clearing it) all passed. The only order-dependent effects are the `attempts` number and the superseded event. `attempts` drives a 60 s versus 120 s helper-check backoff, which is a bounded rate limit and not authority (`:100-101`).

## Smallest cohesive correction
1. **Test (`DaemonRuntimeHostTests.swift:3655`): add a second physical gate.** Hold the correction's block, the *second* `removeDNS` on `.platform-work`, using a counted predicate. Use the existing hold if it can be re-armed while parked; otherwise use a test-local gate in the harness. No production seam.
   - Before releasing it, wait (using the test's existing bounded polling style) until the drop's `attempt=1` failure is recorded.
   - Assert `pending?.attempts == 1` and no superseded event yet.
   - Then release.
   - **Why this is valid:** p3's completion can't reach the owner before its block runs, so the gate *establishes* the order "p2 recorded before p3" rather than assuming it. Every original assertion stays: no superseded event, `[1, 2]`, and the full final state.
   - Also assert that the gate was reached, which proves the correction was queued.
   - Change the message "outcomes are recorded in the order they were queued" to say the gate establishes that order.
2. **Model witness for the order CI actually hit (`SplitDNSEntryFileRepairTests`):** queue p1, p2, p3, then record p1 success, p3 failure, p2 failure. Expect pending `remove/vpnTransition`, `attempts == 1`, and one superseded event with `failed=true newer=1`. This deterministically covers the reversed observation order, which the integration test can't force without a seam.
3. **Comment fix:**
   - `SplitDNSEntryFileRepair.swift:142-143` says "Outcomes land in this order… so two operations in flight at once are both recorded, the later one last." That is true of the physical queue but not of what the owner records. It should say completions may reach the owner out of queue order and that place-based supersession is what keeps the final state correct.
   - The test doc at `SplitDNSEntryFileRepairTests.swift:188-189` makes the same overclaim.
   - **Cost:** the fix is comment-only, but it changes a production file, so under your rule e120 becomes obsolete and needs a mechanical rebuild, signature check and early helper preflight.
   - **My recommendation:** include it, because this false comment is where the test's assumption came from. If you want to keep e120 for now, defer it as a tracked doc follow-up instead.

## Verification needed
- **Gate control:** remove the second gate and keep the strict assertions. The test should then be order-dependent, but that won't fail deterministically, so don't count it as a control. Instead, the gate's positive witness (`attempts == 1` with p3 still held) is what proves the order was enforced.
- **Model control:** change `startedAt < generation` to `<=` or drop the guard. The new model test should then fail on the superseded event.
- Run all 41 local checks, then exact-head hosted Release (standard plus optimized) on Swift 6.3.3. Don't rerun blindly; this failure was order-dependent, so a single pass proves little without the gate.
- Record in the DNS-effects follow-up that the accepted R1 limitation was observed in CI and is now covered by the model witness. The test change plus that note are enough.

No owner decision is needed.
