**Verdict: not ready. One fix is needed.**

The patch makes the drop's refusal (p2) reach the owner before the correction (p3). But it doesn't make the switch-on's success (p1) reach the owner before p2, and that is the same kind of cross-task reordering CI just showed. Everything else in the patch holds.

I read `manifest.json`, `change.patch` and the three frozen files, plus `HeldCall.swift` and the harness teardown for how the hold behaves. I ran nothing. `runtime-split-dns-author-r1.md` isn't in the snapshot directory, so I reviewed without it.

## Necessary fix: p1 versus p2 owner order is still unforced
- p1's block finishes, then p2's block, on the serial queue. Their completions resume two different tasks on `RuntimeActor`: J1 in the reload task and J2 in the drop's delivery task.
- Nothing in the patch stops J2 from running before J1. That is the same reachability as the J3-before-J2 order seen in CI, and the cause of that reorder was never established, so it can't be assumed to run in only one direction.
- If J2 runs first, p1 is recorded after p2 and is superseded (`startedAt p1 < generation p2`). p3 is still queued, because it is queued only after p1's record, whatever that record says.
- The new intermediate check "nothing was superseded yet" and the retained final checks (no superseded event, `[1, 2]`) would then fail, and the final state would still be correct. So the test still depends on an order nobody selected; only half of that dependence is gated.
- The doc comment's own claim, "the earlier success recording first must not discard the later failures", is exactly that unforced order.

**Smallest fix: two holds handed over in sequence, no counter.** `HeldCall` already supports arming a new call while an earlier one is held (`HeldCall.swift:72-73`, tickets at `:131-144`).
1. While the drift pass is held, arm for the **first** `removeDNS` (the drop, p2). Capture `let g0 = host.splitDNSRepair.generation`, then release, which lets the drift pass go.
2. Wait until that arm is reached, which means p2 is held. Then poll, using the test's existing bounded style, until `host.splitDNSRepair.generation != g0`.
   - Only p1 can move `generation` now, because p2 is held and p3 isn't queued until p1 is recorded. So this is a valid completion barrier on p1's record.
   - Intermediate asserts: no `split_dns_failed`, no superseded event, `pending == nil`, `isHolding`, and `commands(matching: .removeDNS)` is empty.
3. Arm for the next `removeDNS` (the correction, p3) while p2 is still held, then release, which lets p2 go. Wait until reached, poll for `failures() == [attempt=1]`, then run the patch's existing intermediate asserts.
4. Release and keep all the final asserts.

Each record then happens while the next operation is physically held, so the order p1, p2, p3 is established rather than assumed. The `removals` counter and the `NIOConcurrencyHelpers` import go away. Update the doc comment to say two hand-over holds set all three record orders.

## What holds
- **Hand-over and cleanup:** the first `release()` frees the drift pass's ticket and doesn't set `releasedEarly`, because something is held. The next arm resets `reached`, so the wait means the new call arrived. If the matcher never fires, the later `release()` only sets `releasedEarly`, so nothing hangs. A thrown sleep or a failed assertion mid-hold is covered by the harness teardown's `releaseAll()` (`DaemonRuntimeHostTests.swift:1756`).
- **Bounds:** every wait is finite: the 5 s wait, the 5,000 × 1 ms poll, and the teardown release.
- **Nothing blocks while p3 is held:** the drop records p2 straight after its block. Anything it queues afterwards waits behind p3 without blocking that record.
- **No assertions erased:** every original final assert is kept, and the only refactor is that the failure list now goes through `failures()`.
- **Swift 6.3 captures:** the nested function captures only `let`s (`events`, and `host` in the fix). The matcher captured a Sendable `let` box. There are no mutable nested captures.
- **Unit test:** traced exactly. With places 1, 2, 3, recording 1 ✓ then 3 ✓ then 2 gives superseded with `newer=1`. `generation` stays 3 and `attempts` is 1. The `names()` helper and the `events` property exist at `:15` and `:39`.
- **Causal control for the unit test:** removing the `startedAt < generation` guard records p2. That makes `attempts == 2` and moves `generation` back to 2, and the event names become two failures. Three assertions fail deterministically, which makes it a real guard witness.
- **Production comment (`:142-145`):** accurate. Operations run in queue order, outcomes reach the owner from the task that queued each one, and supersession keeps the physically latest result. That matches `record` at `:154-176`.

## Controls (for when you run them)
- **Gate-removal control:** when an arm is removed, `waitUntilReached(within:)` and `reachedOnArmedQueue` stay true from the earlier arm, because `arm()` is what resets them. They prove nothing in that control. The deterministic signal is `isHolding == false` at the matching intermediate. Final counts that depend on timing aren't proof, as you said.
- **Single-step assumption:** each removal is assumed to issue one `removeDNS` step, since `clearEntryFiles` removes every enabled entry in one batch. If the launch config had two entries, the arm would catch the wrong call. That would fail deterministically and safely through the intermediate count and the bounded polls, so your baseline run would show it. It doesn't need a change now.

## Wording
- The unit test's doc says "A history a hosted run observed". The CI assertions only *imply* the record order p1, p3, p2.
- Keep "observed" only if the downloaded log actually contains `platform.split_dns_outcome_superseded … source=vpn_transition failed=true newer=1`. Otherwise write "the history a hosted run's assertions imply".

No architecture, API, queue or policy change is involved.
