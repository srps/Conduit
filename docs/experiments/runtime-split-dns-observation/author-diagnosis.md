# Split-DNS failure in `testAVPNDropsRefusedRemovalQueuedBehindAResolverSwitchOnStaysPending`: diagnosis and proposed fix

The test assumes an ordering that isn't selected; production follows its selected contract. The test assumes the owner records two independent tasks' outcomes in the order the platform queue ran them. Nothing guarantees that, and the selected contract handles the other order on purpose. Every final-state assertion passed in CI. I made no edits or executions; this is from reading the code, the records and the bounded assertion excerpt.

## What is actually guaranteed

- **Physical FIFO: guaranteed.** `PlatformWork` is one serial queue, and each entry-file decision is queued in the same owner turn that takes its place (`splitDNSRepair.queue()`). The helper therefore runs them in place order.
- **Owner observation order: not guaranteed.** Each `platformWork.run` resumes its own awaiting task from the queue thread (`PlatformWork.swift:35-36`), and those tasks then queue back onto RuntimeActor. For two different tasks, nothing makes the actor run them in the order they were resumed.
- **Attempt identity:** `attempts` counts only failures that were actually recorded in the current repair episode.
- **Supersession is the selected rule.** The DNS-effects record says: "Out-of-order continuations may drop only an outcome older than one already recorded" (`verification-runtime-dns-effects-2026-10-28.md:19-21`). `SplitDNSEntryFileRepair.record` drops an outcome whose place is older than the newest recorded one, and reports it as `platform.split_dns_outcome_superseded … failed=…`. The unit model covers both orders (`SplitDNSEntryFileRepairTests.swift:173-208`).

## What happened in CI

The test produces three entry-file operations:

1. **First:** the switch-on's apply, run by the reload task. It succeeds.
2. **Second:** the VPN drop's removal, run by the VPN delivery task. It is refused.
3. **Third:** the switch-on's correction removal, queued by the reload task after it records the first (`RuntimeHost.swift:1894-1895`). It is also refused.

The gate decision is a pure function of state (`SplitDNSVPNGate.action`), so only one interleaving produces exactly one failure (`attempt=1`) plus one superseded event: the owner recorded the third before the second.
- If the second had been recorded before the first, the first would be superseded, but the third would still be recorded as `attempt=2`. That doesn't match the CI output.
- The second task was resumed physically before the third even ran, so the actor did not run them first-in, first-out.

The second outcome was dropped correctly by the selected rule: the third ran later on disk and reports the true state. The assertions on pending remove/`vpn_transition`, the file still present, the write order and the landed baseline all passed.

**Why now (hypothesis, not established):** this test came from the MainActor-era prerequisite. The main queue resumes jobs first-in, first-out. RuntimeActor's default executor orders by priority, so task priority or escalation could reorder them. I haven't established the exact priority difference in this run. Local 6.4 passing proves nothing about this.

**Minor consequence, within policy:** the superseded failure isn't counted in `attempts`, so helper-check backoff starts one step lower, and that failure is reported at info level as superseded. The newer failure's warning is still emitted.

## Proposed correction (test only, one test)

Pin the one schedule these assertions describe with a second physical gate plus a semantic barrier. Keep every existing assertion.

1. **Second gate:** while `getenv` is still held, arm a second hold on `.platform-work` for the second `removeDNS` call, using a counting matcher. HeldCall hands the hold over, so the first `release()` frees `getenv` and the second gate catches the correction before it reaches the helper (`HoldingPrivilegeClient` checks the hold before it executes).
2. **Reach the gate:** after the first release, use `waitUntilReached(within: .seconds(5))` and assert it was reached.
3. **Semantic barrier:** wait for the owner to record the drop's refused removal, using the file's existing bounded event-log poll, then assert it.
4. **New intermediate assertions while the correction is held:**
   - `hold.isHolding` is true;
   - exactly one `removeDNS` has reached the helper;
   - failures are exactly `[…attempt=1]`;
   - nothing is superseded;
   - `pending` is remove with 1 attempt.
5. **Release** the correction, then keep the existing `reload.value`, drain and all final assertions unchanged: no superseded event, and failures exactly `attempt=1` and `attempt=2`.
6. **Doc comment:** update it to say the second hold makes the owner record in queue order. The other legal schedule is the selected drop rule, covered by the unit model.

**Why this is valid rather than weaker:**
- It uses the same physical gating mechanism the test already uses.
- The correction's decision and place are taken before it's held, so no decision is affected.
- It chooses one of the two legal owner schedules instead of hoping for it.
- It adds assertions and removes none.

**Coverage gap:** a host-level witness for the out-of-order schedule can't be built without a new seam, because the drop's resumption can't be delayed from a test. I'm not proposing one. The unit model covers that schedule, and this CI run is accidental host-level evidence that final state holds under it.

## Controls (for you to run)

- **Removal-only:** delete the second `arm`. The intermediate assertions then fail deterministically (`isHolding` false, `removeDNS` count wrong). The second `release()` is safe with nothing armed or held, so nothing hangs.
- **Don't** remove the second `release()`: `reload.value` would hang.
- **Then run:** the focused `DaemonRuntimeHostTests` with repeats, the `SplitDNSEntryFileRepairTests` unit model, all 41 checks, and hosted Release with its optimized step.

## Production

No behavior change is indicated, and the selected policy holds. Alternatives that would force owner recording into queue order, such as a reorder buffer or recording on the platform queue, would be a new coordination mechanism and a policy choice. I don't recommend them.

One accuracy issue is comment-only. `SplitDNSEntryFileRepair.queue()` says two operations in flight "are both recorded, the later one last". That's only true when the owner records them in order. Fixing it would touch a production file and make the e120 candidate obsolete under your rule. I suggest deferring it to the next production change or filing an issue; it isn't an owner decision. The matching doc comment on the unit test could be clarified at the same time, since that's test-only.
