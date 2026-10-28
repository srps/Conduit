I re-read the key lines in the r2 snapshot during this turn. I treated the earlier attempt that ended in the TLS (EPROTO) error as a network failure, not as review evidence. I made no edits, built nothing and made no network calls.

## r2 verdict: Source ready

Both blocking findings from r1 are fixed in production, and each has a test that failed on the old code. No assertion was weakened, and the pm-sim ordering check can genuinely fail. The parent's corrected all41 run is still outstanding; I'm drawing no conclusion about execution from it.

### Finding 1 (residue read before the start's intercept sweep): closed
- **Fix:** `RuntimeHost.swift:715-716` now reads `Observation.after(...)` after the sweep's do/catch at `:705-714`. It is still inside the same `resolvers.serialized` scope, behind the same `!token.isSuperseded` guard, at the same queue place. This matches the config-change path.
- **Test:** `DaemonRuntimeHostTests.swift:3779-3816` sets up the exact case:
  - a pending remove/stop repair;
  - a journal-recorded file for a disabled intercept rule, planted through the host's own `dnsManager`;
  - checked preconditions: the file is present, the journal names it, and `unconfiguredRecordedFilesPresent` is true.
- **Expected result:** the sweep removes the file and its record, nothing is left pending, and exactly one `operation=apply by=start` repair event is emitted.
- **Old-code proof:** the manifest separates the invalid fixture of attempt 467rOz from the corrected sb1zk7 run. In sb1zk7, the sweep assertions passed but the pending, repaired-count and prefix assertions failed on r1 production. That is the behaviour I described in r1.

### Finding 2 (drop and reconnect while the start's block is out): closed
- **Fix:** `:662` captures `gateReportSeen` in the same turn as `vpnConnected`. The correction condition at `:737-739` adds `entriesWanted && applied != gateReportSeen`.
  - It uses the existing `VPNObservationOrder.applied`, so there is no new state or API.
  - The correction is still decided and queued in the `runtimeStarted = true` turn (`:730`).
- **Test:** `:3731-3774` runs with real observers, started by `startDNS`, and positively confirms each report.
  - While the start is held off main: the drop is taken, the reconnect is taken, `runtimeStarted` is still false, and nothing has run ahead.
  - After release, it asserts the exact command list `[applyDNS, removeDNS, applyDNS]`, an entry file present, no failures and nothing pending.
- **Old-code proof:** on r1 production this failed at `:3769` (only `[applyDNS, removeDNS]` ran) and at `:3771` (no entry file).

### No assertions weakened
- Every r1 test hunk in the r2 patch is unchanged, including the migrated switch-on test and the flap/Stop test.
- The widened condition does not change what the r1 flap/Stop test expects. Its ordering assertions use the first/last index, so a redundant correction cannot break them.

### pm-sim post-release order check: non-vacuous, not tautological
At `RuntimeHostEffectsScenarios.swift:1444-1470`:
- The command baseline is taken before the drop is emitted.
- `removal` and `restore` are each searched independently from that baseline. `restore` is not searched only after the removal.
- The witness stays false unless a `corp.example` `removeDNS` exists *and* comes before the first system-proxy write.
  - If the drop queued nothing, the check fails.
  - If the removal were queued behind the Stop, the check fails.
- Every member of the setter set exists in `PrivilegedOperation` (`PrivilegeClient.swift:14-24`), and the set covers the batched setters the Stop's restore uses. That fixes the earlier `.clearSystemProxy`-only bug from attempt JTRfxu.
- A drift-reconcile write triggered by the drop could only land after the removal, so it cannot make the check pass falsely.
- **What it doesn't prove:** this check alone can't tell an inline removal from a queued one. The in-hold check and the stronger unit test `RuntimeHostControlOwnerTests` cover that distinction.

### Cheap fixes: applied and correct
- `recordSplitDNS(startedAt: Int)` is now required (`:1143`).
- The `record` doc no longer mentions using a read generation as `startedAt`.
- The `DNSManager` lock comment no longer cites the preflight.
  - Cosmetic nit, not blocking: it still says launch recovery "still overlap[s]" the host's queue. In practice, launch recovery is joined before any surface work, so the lock is defensive there.

### Remaining limitations (accepted or unmeasured)
- **Head-of-line latency:** the orchestrator's VPN handling waits behind unrelated `platformWork`. This is unmeasured.
- **Redundant idempotent correction applies:** r2 widens the start tail. Any report the gate took while the block was out, such as connected→reasserting, now costs one extra apply while entries are wanted.
- **Ordering under priority-based resumption:** the place-based freshness check and `recordInterceptRefresh` are correct by construction only, untested until the RuntimeActor retag.
- **Gaps in `newer=`:** queue places taken by intercept refreshes leave gaps that `newer=` counts. They are harmless, and `docs/events.md` is accurate about them.
- **Residue config:** residue is now read against the operation's own config rather than the accepted view, and at start after the sweep. This is documented.
- **Preflight reads:** the activation preflight still reads `DNSManager` from a global queue without the lock. This is unchanged from before phase1b.
- **Not run here:** all41, the AppState parity suites (where the settle-refresh path is exercised), TSan and CI. All are parent-owned.