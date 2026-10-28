# Phase 1a final review: ready for commit

There are no confirmed remaining defects in the final patch (`5e798e53…`, base `0b5c533c`, snapshot `63677eef…`). The full workflow evidence checks out.

## Final patch
- **The seven files are the r2 set**, with one compile-driven change in pm-sim:
  - production: `RuntimeHost.swift`, `RuntimeReconciler.swift`;
  - pm-sim: `RuntimeHostEffectsScenarios.swift`, `SettingsRetryScenarios.swift`;
  - tests: `DaemonRuntimeHostTests.swift`, `RuntimeHostControlOwnerTests.swift`, `RuntimeReconcilerTests.swift`.
  
  None of the Root B lifetime files are in the patch; that fix is in the base, as `0b5c533c`.
- **The r2 fixes are all present:**
  - the zero-buffer stream: `bufferingNewest(0)`, patch `:414`;
  - the corrected `activeEffect` comment (`:369`);
  - the framed config-revision comparison (`:891`, `:904`);
  - the unconditional timer arm after the block (`:209`);
  - the two DNS tests (`:763`, `:793`).
- **The one change since r2 is equivalent:**
  - The 11-term `??` chain, which hit a type-checker timeout, is now `let exercises = [flagged, audited, …, shutdown]` followed by `exercises.lazy.compactMap(\.pinnedHost).first` (`:490-491`).
  - It has the same left-to-right order, the same first non-nil result, and reads only values that were already computed. Gating and root release are unchanged.

## Earlier findings
- **Pre-verification findings 1–4:** all closed (stream buffer, mirroring assertion, stale comment, missing tests).
- **Design items I accepted:**
  - same-turn enqueue;
  - quiescence covering settlement before Stop reads the baseline;
  - landed facts recorded per group only, with no stale whole-baseline promotion;
  - receipts preserved;
  - no deadlock through the resolver lock;
  - removing the timer guard.
  
  The tests now confirm these by running.

## Executed evidence (`runtime-actor-flags-full-gates`)
- **`results.json`:**
  - `head` is `0b5c533c`; `source_sha256` equals `final_source_sha256` (`105f6b8f…`), with `stable: true`.
  - All 41 records exit 0; no non-zero `exit` appears in the file.
- **Swift:** `swift-tests.log:10504-10506` reads "Executed 3704 tests, with 4 tests skipped and 0 failures". That is four more than Root B's 3700, matching the four new phase 1a tests.
- **pm-sim:** 103 pass-line matches. The only lines matching my failure pattern (`:1313-1314`) are expected scenario logs ("replying SERVFAIL"), not failures.
- **Focused run:** 231 tests and 145 pm-sim assertions with 0 failures, and the held-flag exercise passes 13 of 13. These figures come from the manifest and your report. I didn't read the `0nZy7V` directory, which was outside the scope you gave me.

## Notes (not defects)
- **Fingerprint link to record:** the full-gates `head` is the base `0b5c533c` with phase 1a uncommitted, identified by fingerprint `105f6b8f…`. The commit record should state that the phase 1a commit's source hashes to `105f6b8f…`, and that `105f…` and the snapshot's `63677eef…` cover different scopes.
- **Known gaps carried to later phases, honestly declared, not claimed fixed:**
  - Main-thread contention on the resolver lock between an inline VPN-transition write and a resolver block, until phase 1b.
  - Push and re-apply still start one turn late.
  - The split-DNS paths that remain inline (VPN reconcile, residue read, settle, retry, config-change reconcile).
  - `reconcileImmediateActions` still has no caller.
  - HeldCall generalisation (1e).

## Verdict
- **Phase 1a:** ready for commit, both as source and on executed evidence.
- **Not complete, not claimed:**
  - phase 1b and later phases;
  - the RuntimeActor retag;
  - hosted CI for the phase 1a commit;
  - native acceptance (the Mac is still locked);
  - release acceptance and merge.