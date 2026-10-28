## Phase1b review (`runtime-actor-dns-review-r1`, patch `4a64…d767`)

**Decision: Source not ready yet. Two small production changes are needed. Everything else you asked me to confirm holds.** I made no edits, built nothing, ran nothing and read nothing outside the frozen snapshot and its manifest.

### Changes needed

**1. The start path reads residue before its own intercept sweep, so the residue it records is not exact.**
- **Where:** `Sources/ConduitRuntime/RuntimeHost.swift:700-701` runs `Observation.after(...)` before the `refreshInterceptFiles` sweep at `:706-715`, inside the same `resolvers.serialized` scope.
- **What goes wrong:**
  - `unconfiguredRecordedDomains` counts a recorded file for a disabled intercept rule as residue (`SplitDNSEntryFileRepairTests.testADisabledInterceptRulesFileIsResidueAndSwept`).
  - At start, the sweep removes exactly that file, because `clearInterceptFiles` uses `forCleanup: true`.
  - Before 1b, the residue was read after the whole block. Now a pending repair that the start actually fixed stays pending.
  - As a result, `markResolverSwitchLanded` is held back until a later retry, and the resolver-flag baseline lags for that time.
  - This errs on the safe side: the baseline is never promoted falsely. But it is a change from base behaviour, and it contradicts "exact residue".
- **Fix:** move lines 700-701 to just after line 715, still inside the same lock. The config-change path at `:1679` already reads residue after its refresh.
- **Test:** one host test. Set up a pending repair plus a journal-recorded file for a disabled intercept rule, then start. Expect `split_dns_repaired by=start`. With the current ordering, the repair stays pending.

**2. The start tail compares the net gate state, so a drop and reconnect while the start's block is out loses the entry files.** The FIFO ordering makes this deterministic.
- **Where:** the condition `splitDNSGate.entriesWanted != vpnConnected` at `RuntimeHost.swift:733`.
- **Sequence:**
  1. The start's block captures `vpnConnected = true`.
  2. A drop is handled with `runtimeStarted == false` and queues a `.remove` behind the start's apply.
  3. The reconnect is handled while `runtimeStarted` is still false, so it decides `.nothing`.
  4. The tail sees wanted == captured and does not correct.
- **Result:** the tunnel is up, the runtime is started, and there are no entry files. No failure is recorded, so no retry fixes it.
- **Is this new?** Before 1b it was a race: the inline removal could land before the start's resolver step, and the apply would then restore the files. Now the removal always lands after the apply.
- **When it can happen:** only while observers are already running during a proxy start (DNS module up, or a restart). A cold start calls `startObservers` at `RuntimeHostLifecycle.swift:522`, after the apply.
- **Impact:** split-DNS stops working until the next flip. It is not the bootstrap-deadlock direction.
- **Fix, no new API:**
  - Capture `let gateSeen = splitDNSGateOrder.applied` (already `package private(set)`) next to `vpnConnected` at `:661`.
  - Change the condition to `entriesWanted != vpnConnected || (entriesWanted && splitDNSGateOrder.applied != gateSeen)`.
  - The extra case only ever queues an idempotent apply.
- The switch-on tail at `:1834` does not need this, because `runtimeStarted` is already true there.
- **Test:** hold the start's block, drop and then reconnect while it is held, release. Expect an entry file at the end.
- If you would rather not take this in 1b, record it as a remaining limitation with that precise scope.

### Confirmed

- **No blocking manager or file read left on the owner.**
  - Every `dnsManager`/`resolvers` call in ConduitRuntime now runs inside a `platformWork` block.
  - The preflight still reads on a global queue, and launch recovery runs in its own job.
  - `recordSplitDNS` (`:1134-1150`) reads no disk.
  - The inline `refreshInterceptFiles` helper is gone.
- **Same-turn enqueue.** Each site decides and then calls `queue()` and `platformWork.run` with no suspension in between:
  - `reconcileEntryFiles` `:1113-1126`
  - retry `:1180-1190`
  - settle refresh `:1212-1214`
  - config change `:1650-1663`
  - switch-on `:1806-1809` and switch-off `:1856-1858`
  - intercept-refresh flag action `:1841-1847`
  - stop `RuntimeHostLifecycle.swift:825-826`
- **Stop, tail and `runtimeStarted`.**
  - `runtimeStarted = true` is set in the same turn as `continueStart` (`:724-729`).
  - The old assignment after `applyProxySurfaces` is gone (`RuntimeHostLifecycle.swift:474`).
  - `testAVPNFlapAndAStopDuringAStartsHeldEntryFileTailEndInOrderAndStopped` would fail under either the old placement or the old re-set.
- **Freshness by queue place, and a refused removal is kept.**
  - `queue()` and the `startedAt < generation` drop rule are at `SplitDNSEntryFileRepair.swift:144-176`.
  - `testAVPNDropsRefusedRemovalQueuedBehindAResolverSwitchOnStaysPending` would fail under the old count-based rule.
  - The `docs/events.md:348` wording for `newer=` is accurate, gaps included.
- **Intercept-refresh outcome is safe against out-of-order completion.**
  - `recordInterceptRefresh(failed:place:)` (`:273-282`) is used by both the settle refresh and the flag action.
  - The bindings are captured and the work queued in the deciding turn, so a later DNS Stop's withdrawal always lands after it.
- **No false baseline promotion.**
  - The settle runs only when a real record moves pending to nil; a superseded outcome never settles.
  - `markResolverSwitchLanded` keeps its guard on the requested flag.
  - Marking before the refresh matches the accepted semantics.
- **Files before orchestrator** is kept (`:1101-1106`). The proxy-repair delivery still queues its work after the entry work.

### Non-blocking fixes (cheap)

- **`RuntimeHost.swift:1137`:** make `startedAt` required. An unplaced record takes `queue()` (`SplitDNSEntryFileRepair.swift:176`), which ranks it newer than every operation in flight. A future call that omits the place would therefore supersede those outcomes, including a refused removal.
- **`SplitDNSEntryFileRepair.swift:154`:** remove "or the `generation` a caller read". Under the new rule, a read generation is accepted without advancing it.
- **`DNSManager.swift:57-59`:** this cites the activation preflight as an overlapping reader that needs the lock. That contradicts `:111-113`: the preflight's reads (`ActivationPreflight.swift:85-86`) take no lock. The manifest's statement that the preflight "still takes the DNSManager lock" is wrong for the same reason.
- **pm-sim `dropQueuedBehindHeldWork`** (`RuntimeHostEffectsScenarios.swift:~1451`): nothing shows positively that the drop was taken, so the check passes vacuously if the delivery never ran. Add a post-release ordering check: the `removeDNS` for `corp.example` lands before the Stop's clear. The unit test in `RuntimeHostControlOwnerTests` already covers this strongly.

### Test sufficiency

The added tests discriminate the real risks: queue-place freshness, the `runtimeStarted` window, retry ordering, and the VPN write staying off main with Stop ordering. Apart from the one test each for items 1 and 2, nothing more is needed:
- The config-change block and the settle refresh need no new held tests. A single lock scope rules out interleaving, and the existing functional tests cover them. `AppStateActivationParityTests.testAnInterceptRefreshThatStillFailsDoesNotStrandARetriedEntry` runs in all41, not in the focused run.
- Out-of-order resumption can't be induced on MainActor, so the place guards are verified by construction only until the retag.

### Measured vs. remaining limitations

- **Measured:** the focused attempt `0gXmmy` passed (260 tests, 147 sim assertions, imports, catalogue, decisions). Attempt `GMTsnV` failed only on the test-target autoclosure compile error, which the manifest records. all41 is pending, as are the AppState parity suites, TSan and CI.
- **Remaining and accepted:**
  - Head-of-line delay for the orchestrator behind unrelated `platformWork` (not measured).
  - Redundant idempotent correction writes.
  - Places taken by intercept refreshes leave harmless gaps that `newer=` counts.
  - Residue is now read against the operation's own config rather than the accepted view; this is documented.
  - Protection against priority-ordered resumption is untested until the RuntimeActor retag.

I'll wait for your next step.