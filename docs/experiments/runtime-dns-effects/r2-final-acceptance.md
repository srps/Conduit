I checked the executed artifacts myself and **phase1b is accepted, with the limitations below**. I'm now waiting for the next phase. I made no edits, built nothing, made no network calls, and read nothing outside `runtime-actor-dns-r2-full-gates/`.

## What the artifacts show

- **Source stable for the whole run:** in `results.json`, `source_sha256` and `final_source_sha256` are both `06d02d0a…f1d7ab143`, and `stable` is true.
  - I can't link that fingerprint to the r2 snapshot hash `4ae722b5…` myself, because the two hashes cover different things. That link rests on the parent's statement that they match.
  - The gates ran in the parent's worktree, not in the frozen snapshot directory.
- **All 41 checks exited 0.** I counted the entries. They include the build, swift-tests, `pm-sim all`, sim-outcomes, perf-gate, the import, catalogue and decision checks with their own tests, and the updater end-to-end runs (signed and unsigned).
- **Swift tests** (`swift-tests.log:10521-10522`): "Executed 3710 tests, with 4 tests skipped and 0 failures", and "Test Suite 'All tests' passed".
  - The skips are the four expected environment gates: two need a live Kerberos ticket and two are log-only resource probes.
- **Every phase1b witness ran and passed in the full run:**
  - drop and reconnect during a held start block (`:4366`);
  - the start's intercept sweep settling a repair whose only residue it removed (`:4436`);
  - a VPN drop during a held retry (`:4456`);
  - a refused VPN-down removal staying pending behind a switch-on (`:4458`);
  - a flap and a Stop during the start's held tail (`:4462`);
  - the held VPN write leaving the owner free (`:7987`);
  - outcomes recorded in queue order (`:9247`).
  - The AppState parity tests, which were not in the focused run, also passed: `testAnInterceptRefreshThatStillFailsDoesNotStrandARetriedEntry` (`:890`, the settle-refresh path) and `testEntryFilesFollowTheVPN` (`:1321`).
- **Simulator:** all 103 scenario outcomes are `PASS` and there are no `[fail]` lines. The sim-outcomes check passes.
  - In `runtime-host-effects` (PASS), the three new checks pass at `pm-sim-all.log:2350`, `:2353` and `:2356`. They cover the drop queued behind the held action, the drop's removal landing before the Stop's restore, and no entry file outliving the tunnel or the Stop.

## Final phase1b acceptance

Phase1b is accepted for the frozen r2 source. No blocking `DNSManager` call or disk read is left on the owner. Every split-DNS operation follows one pattern: it is decided and queued in the same owner turn, it runs on the platform queue with its residue read under the same lock, and its outcome is recorded on the owner by queue place.

Both r1 findings are closed, each with a test that failed on the old code:
- the start's residue is read after its intercept sweep;
- a drop and reconnect while the start's block is out no longer leaves the tunnel up without its entry file.

These r1 points still hold:
- `runtimeStarted` is set in the same turn the start decides its tail correction;
- an outcome is dropped only when a later-queued one was already recorded, so a refused VPN-down removal is kept;
- an intercept refresh's result never overwrites a newer refresh's;
- no repair settles on stale evidence, so the resolver baseline is never promoted falsely;
- entry files land before the orchestrator hears of the VPN change.

## Limitations carried forward

- **Head-of-line latency, accepted and unmeasured:** the orchestrator's VPN handling waits behind unrelated queued platform work.
- **Redundant correction writes, accepted:** both post-write corrections can queue an idempotent apply. The r2 start tail adds one per gate report taken while its block was out, if entries are wanted.
- **Ordering under priority-based resumption:** the queue-place freshness and the intercept-refresh guard are correct by construction only, untested until the RuntimeActor retag.
- **`newer=` gaps:** queue places taken by intercept refreshes leave harmless gaps that `newer=` counts. `docs/events.md` describes this accurately.
- **Residue config:** residue is now read against the operation's own config rather than the accepted view, and at start after the sweep. This is documented.
- **Preflight reads:** the activation preflight still reads `DNSManager` from a global queue without the lock, as before 1b.
- **Doc nit, not blocking:** `DNSManager`'s lock comment says launch recovery's job "still overlaps" the queue. In practice it is joined before any surface work.
- **Not covered by this run:** TSan, CI, and real-machine validation of helper-backed `/etc/resolver` behaviour.