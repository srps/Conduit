## Phase1c relay review (`runtime-actor-relay-review-r1`, patch `bd240b4d…`)

**Verdict: Source ready. I found no defects.** I read every changed production, test, helper and scenario hunk, plus the surrounding `PhysicalLifecycle` and DNS start/stop/restart code, and checked them against the approved plan. I made no edits, built nothing, made no network calls and did not read the moving worktree.

Following your clarification, I treat attempt mZz0zx as a **functional seam baseline**. It kept the command and generation-only logic but had no PlatformWork, slot or in-flight cap. It did not preserve execution placement: its `@Sendable async` closure ran on the cooperative executor, as the recorded queue label shows. Its four failures are valid witnesses for:
- the wrong queue;
- a teardown running beside the slot (two assertions);
- the missing in-flight cap.

None of them is timeout evidence.

### Invariants checked against the code

- **One host PlatformWork, no new kernel queue or API.**
  - `RuntimeHost.swift` (init, near `:466-481`) builds one `PlatformWork` with the unchanged label, assigns it to the property, and passes `relayCommand`. The closure calls `platformWork.run { Result { try relayClient.execute(...) } }.get()` on the same audited client, so `auth.privilege_request` audit events are unchanged.
  - In the kernel, the seam is an optional `@Sendable` closure in the init (`ProxyOrchestrator.swift:977`, `:1273`). There is no queue, protocol or concrete helper type, and no access was widened.
- **The DNS slot serializes relay commands.**
  - Lifecycle relay commands run only from `startTransparentProxy`/`stopTransparentProxy`, inside `runDNSStart` or `closeDNSListeners` effects (`:1676-1693`, `:1711`, `:1727`).
  - The reissue runs as `runInfallibleEffect(dnsLifecycle, epoch: fence.epoch)`.
  - `PhysicalLifecycle.run` (`PhysicalLifecycle.swift:58-70`) checks the epoch and claims the slot with no suspension between the two. So a reassert either claimed the slot before a Stop was admitted, in which case the Stop's teardown waits for it, or it finds its epoch stale.
- **No re-entry deadlock.** No production caller invokes the reassert from inside an effect; the only one is the main-queue timer at `:3326`. The reissue body calls only `startTCPRelay`, never a lifecycle method.
- **Probe outside the slot, then epoch and generation checked inside.**
  - The fence (generation plus epoch) is taken in the tick's turn, only while `admitsRunning` (`:3389-3392`).
  - The probe runs before the effect, on the utility queue for the tick and off-main path, inline for the test-only entry point.
  - The generation is checked again inside the effect. That catches a restart whose teardown bumped the generation under an unchanged epoch: production ticks require `tcpRelayActive`, so such a teardown always stops the relay and bumps the generation.
  - A refused claim, or a generation that moved, emits the unchanged `tcp_relay.reassert_superseded` detail. The `docs/events.md:299` wording in the base matches.
- **One reassert in flight, including the test entry points.** All three package entry points and the tick task pair `beginRelayReassert` with `endRelayReassert` (`defer`, or after the task body). A tick that arrives meanwhile returns nil, so at most one reassert waits on the slot.
- **The landed flag stays truthful and failures are still reported.**
  - `tcpRelayActive` is set only after a start succeeds and cleared only after a stop succeeds. The generation is still bumped in the deciding turn.
  - Log lines and levels are unchanged.
  - While a command is out, the stale flag is read only inside the slot (teardown) or by the tick, which can't run during a start because the timer starts after publish.
- **Stop leaves the relay stopped.** The Stop's teardown runs after the reassert's effect and sees `tcpRelayActive == true`, so it stops the relay. Both new witnesses prove this.
- **nil (pm-proxy) unchanged.** `PMProxy.swift:112` passes no closure. A start logs "unavailable" and returns before bumping the generation. A stop's optional call is a no-op that clears the flag, exactly as `privilegeClient?.execute` did.
- **Dead code removal is clean.** No references remain anywhere in `Sources`, `Tests`, `docs` or `scripts` to:
  - `performTerminationCleanup`;
  - `stopSnapshotCoalesceTimer`;
  - `PlatformWork.waitUntilIdle(timeout:)`;
  - `observability.audit_flush_timeout`.

### Tests and simulator: non-vacuous, nothing weakened

- **`HeldCall`:** `.ignored` keeps the old behaviour exactly, so the preflight exclusion holds for every existing arm site:
  - a main-thread call is taken but not held;
  - a call on the armed queue is held;
  - a call on any other queue doesn't count.

  `.recorded` takes a call on the wrong queue, records its label and lets it through. It does not wait for it. That turns a wrong executor into a positive placement failure.
- **Every prior `RelayLifecycleTests` assertion is kept:** command orders, the `relay_active=false` detail, and the reasserted counts.
  - `testALiveRelayIsLeftAlone` now starts DNS, so it can no longer pass just because no reassert began.
  - The `BlockingRelayProbe` pass-on change only frees probes waiting behind it.
- **The new slot test and the pm-sim row discriminate:**
  - each asserts that the hold was reached on the expected queue;
  - each checks that DNS is still running and nothing was sent during a bounded window;
  - each ends with exactly `[startTCPRelay, stopTCPRelay]` and DNS stopped.
- **In-flight test:** `XCTAssertNil(second)` is the discriminating assertion. Its precondition (DNS running) is asserted first. The command count passed even on the baseline because the generation check already supersedes the duplicate; the manifest says so.
- **Host witness (`RuntimeHostControlOwnerTests`):** it asserts the exact host label via `reachedOnArmedQueue`, the snapshot answering, and the Stop admitted. After release it checks that the first relay command is a start and that the last and only stop comes after every start.
- **The `BoundedRecordWriterTests` retarget is real coverage, not a weakening.** It drives the actual `DiagnosticFlush.run` that the host and pm-proxy use, keeps every prior assertion and adds `report.audit == .drained`.

### Non-blocking notes

- The tick drops silently when a reassert is already in flight; it emits no event. That is acceptable, because a drop is not a routing or health decision.
- `testNothingPublishedMeansNothingToReassert` still exits at the `tcpRelayActive` guard without starting DNS. That was already true before this change.
- A test entry point with `tcpRelayActive == false` can claim the slot between a restart's teardown and its rebind, and reissue to the old target. The rebind then re-points the relay. No production path can reach this.

### Remaining limitations

- **Relay commands can be later:** they now wait behind any queued PlatformWork. That includes the DNS-stop relay stop during a terminal quit, which stays within the quit budget, so a relay can be left up if the budget expires. Nothing queued waits on the orchestrator, so there is no deadlock.
- **No blind relay stop at quit, as in the base:** a relay left by a crashed earlier run is replaced at the next DNS start by `TCPRelayPlan`.
- **A stuck helper holds the DNS slot:** a reassert or lifecycle relay command waiting on it holds the slot for up to the helper transaction budget, so a DNS Stop's teardown waits for it.
- **Bounded negative windows cost time:** the two slot witnesses each spend 500 ms checking that a beside-the-slot teardown does not appear. The decisive assertions are deterministic.
- **HeldCall leaves a semaphore permit:** when `.recorded` lets a call through, the later release leaves a permit behind. No witness re-arms afterwards. Making HeldCall fully actor-aware is still later work.
- **Not run here:** all41 (the parent is running it), TSan, CI, and real-helper validation. The control cluster is still MainActor; the logger, the whole-actor retag and the native work are not done.

I'll wait for your next step.