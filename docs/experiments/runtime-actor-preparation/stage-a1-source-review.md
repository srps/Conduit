**Verdict: I accept the StageA Source as current-isolation preparation, with the limits below.** I found no P0 or P1 defects in the Source change itself. The action items are about evidence scope, test meaningfulness, the helper's edges and comment accuracy. This is not acceptance of #47, a RuntimeActor, or any native, machine or release behaviour.

## Findings

**P1 (evidence): reprobe tests that actually fire the timer exist but weren't in the runs you cited.**
- `Tests/ConduitTests/VPNReprobeRecoveryTests.swift:60` sets the reprobe interval to 0.1 s and asserts `connectivity.reprobe_started`.
- `Tests/ConduitTests/ConnectivityProbeSupersessionTests.swift:484` sets it to 0.2 s and stops the runtime while a reprobe is out.
- Both go through the changed off-main handler and the generation-checked tick (`ProxyOrchestrator.swift:3014-3027`, and `directModeReprobeTick`). Neither suite is in the strict 9yrwOT list or the k8yvGr list.
- Fix: add both to the focused normal and strict filters, then correct the manifest's limit that says "direct-mode reprobe never fires". Only the relay timer (fixed 30 s, `ProxyOrchestrator.swift:3341`) and the DNS health timer (fixed 30 s, `RuntimeHost.swift:1481`) are really inspection-only.
- Also check the evidence: the manifest says the strict marker `/private/tmp/conduit-runtime-stage1-20261024/runtime-actor-strict-pool` still exists. If it was there when the all-41 run started, that run is strict, not normal.

**P2: the new coalesce test can't tell the old code from the new, and it never exercises the stale-hop guard** (`SnapshotCoalescingTests.swift:184-211`).
- The old `.main` timer, with main parked, also emits nothing during the park and once afterwards. So the message at `:201` ("the timer fired off the main thread") isn't proven.
- The test also assumes main is the owner, so it will fail once Stage B moves the owner off main.
- The branch that matters, `guard generation == snapshotCoalesceGeneration` at `ProxyOrchestrator.swift:400`, has no witness. A cheap, deterministic one using existing seams and main's FIFO order:
  1. Arm with `triggerCoalescedSnapshotEmitForTesting()`, then park main.
  2. Straight away, queue `Task { @MainActor in mutateSnapshotForTesting{…}; triggerCoalescedSnapshotEmitForTesting() }`.
  3. Sleep about 300 ms, release, then `await MainActor.run {}`.
  4. Expect +1 at this point (the immediate emit only, because the stale hop is dropped), and +2 only after another ~100 ms or more.
  5. Without the guard, the stale hop flushes early and drops the new timer's handle, so you'd see +2 at once.

**P3: re-arming `HeldCall` while a call is held breaks "a release belongs to one arm".**
- `arm()` (`HeldCall.swift:75-85`) resets everything except `holding`.
- After a re-arm, `release()` frees the earlier arm's held call instead of marking an early release for the new arm.
- A call the new arm takes but doesn't hold sets `holding = false` (`:130`), which wakes the old call without any `release()`.
- Fix: one line, an XCTFail or precondition in `arm()` when `holding` is true. No current self-test covers this case.

**P3: `recordedExcept` is unused.** Only its own self-test uses it (`HeldCall.swift:32,117`); no host test does. In keeping with simple design, remove it until a test needs it.

**P3: older tests can now pass without anything being held.**
- 79 `arm` sites across 10 files arm with no queue name, and many assert only `!reachedOnMainThread`.
- A matching call on the pool is now taken and let through, never held. A test whose later assertions don't depend on the hold could then pass vacuously.
- One central `XCTAssertFalse(hold.reachedOnCooperativePool)` in the harness teardowns closes this without editing each test.

**P3: inaccurate comments.**
- `LaunchRecovery.swift:41-42` says "queued now rather than on the caller's next turn". `Task.detached` doesn't guarantee when its body queues the work relative to the caller's later turns. Ordering rests on `join()`, so reword.
- `RuntimeHost.swift:571` says "every path that queues there joins recovery first". The VPN entry-file path (`:1147-1151`) and `relayCommand` (`:479`) don't join. They are safe only because they can't run before a Start's join, as `:625-632` already explains, so point there.
- `SnapshotCoalescingTests.swift:50-51` still says the timer fires "on the main queue" (this may be your existing docs TODO).

## Checked and sound
- **Task inheritance:** every retagged site is inside a `@MainActor` type (`RuntimeHost:30`, `ProxyOrchestrator:255`, `RuntimeReconciler:58`, `PhysicalLifecycle:11`, `RuntimeQuitFlush:14`, `StoppedEffectsJoin:30`). The package uses tools 6.2 with no language-mode override, so it builds in Swift 6 mode. Closures that touch owner state synchronously are therefore compiler-checked. The ones that only `await` (reconciler worker, `runEffect`, `runStart`) get main-actor isolation from the language's inheritance rule. NIO callbacks, `reportAuthOutcome` and `HealthChecker` were not touched.
- **Timers:**
  - They are still uptime-based `DispatchSource` timers, with explicitly `@Sendable` handlers.
  - Each timer's generation is read after the stop that bumps it (`:3006` then `:3014`, and the same for the relay).
  - The one-pending-hop flag is a fresh box per arm, so a stale hop clears only its own.
  - A stale tick can't clear a newer timer, because the generation is checked before any stop.
  - A stale tick can't bring the runtime back: the relay requires `tcpRelayActive`, and the reprobe requires `state != .stopped`, a lifecycle guard and a matching generation.
  - A coalesced emit that arrives between the timer firing and its hop is covered, because the timer handle stays set until the hop lands.
- **LaunchRecovery:**
  - The normal host uses its existing serial `PlatformWork`.
  - The configless path uses a single worker of its own, is awaited, and the closure keeps that queue alive.
  - There is no synchronous re-entry: recovery awaits nothing, and the managers' `serialized` calls are locks.
  - Joins, ordering and root custody are unchanged.
  - New cost: for those seconds, recovery occupies the host's platform queue, so other platform work waits behind it. That is latency, not a deadlock.
- **NetworkMonitor:** the callback reference is read under the lock and called outside it, and `cancel()` runs outside the lock.
- **terminalExit:** it is called only at `RuntimeHostLifecycle.swift:1046`, on the owner. `exit(0)` and `{}` are unchanged.
- **HeldCall:** holding and release work as you specified. Waits sit in `while` loops on one `NSCondition`, so spurious wake-ups are safe. The rule that labels ending in `.cooperative` are pool threads is checked by the self-tests on the real contexts, and those passed in the strict run (9yrwOT). The new held-recovery test names the exact queue strictly (it doesn't just check "not main").

## Limits to keep stated
- The mixed-priority audit test exercises only the current MainActor owner. The NIO callback hops come from the event-loop thread at its own priority, so nothing forces a reordering. It needs a rerun after Stage B.
- The relay and DNS-health timers have no firing witness.
- Blocking work still on the pool, outside StageA's scope: the stranded-socket scan (`ProxyOrchestrator.swift:2505`, a ProxyKernel file, so `PlatformWork` isn't available there) and the app's curl PAC fetch (`AppState.swift:1554`).

## Older issue I noticed but couldn't verify (not StageA)
A host keeps one `NetworkMonitor` for its lifetime (`RuntimeHost.swift:393`). It calls `start()` at `RuntimeHostLifecycle.swift:308` and `stop()` at `:742`, and `stop()` cancels the `NWPathMonitor`. As I understand Network.framework, a cancelled path monitor can't be restarted, which would mean a Start → Stop → Start on the same host gets no path updates afterwards. I couldn't run anything to confirm it; it's worth a separate issue.