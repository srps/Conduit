# Verification: diagnostic destination guard (#222), 2026-10-24

Scope: the connection audit and runtime events writers refuse a destination that
aliases a protected runtime resource. No serving app, helper, real credential or
real log was read or written. Decisions 0014, 0017 and 0020 are unchanged.

## What was reproduced first

- `ProxyConfigPersistence.save` default: 2298 bytes of pretty JSON with no LF.
- A `RotatingRecordFile` pointed at that config, then a 20-byte synthetic audit
  NDJSON append: the tail check saw no LF and truncated the config, so the file
  held only the audit line. After a 20-byte record the rotation count was 1.
- Review regression log (`/private/tmp/conduit-runtime-stage1-20261024/auditguard-review-regressions.log`):
  `DiagnosticDestinationReviewRegressionTests` failed 3 assertions in 2 tests.
  (a) The event log and its events writer kept each other alive after their owner
  released them. (b) On a case-insensitive volume, `CONFIG.JSON` created a blank
  `config.json` before the guard refused it, because the check ran only after the
  open. Both witnesses are kept unchanged; only the fixture's construction moved.
- Parent witness log (`/private/tmp/conduit-runtime-stage1-20261024/auditguard-parent-regressions.log`):
  4 tests, 2 assertion failures, both in `testDestinationBeneathMissingConfigIsRefusedBeforeCreatingConfigDirectory`.
  The destination `config.json/audit.ndjson` (config missing) was admitted by the equality check, the writer's
  `createDirectory` made a directory where the future config file belongs, and the audit append succeeded.
  The witness is kept unchanged.
- Unicode witness log (`/private/tmp/conduit-runtime-stage1-20261024/auditguard-unicode-regressions.log`):
  3 tests, 1 failure. `testMissingUnicodeCaseAliasIsRefusedBeforeCreatingPreferences`
  (`preferenceſ.json`, long s U+017F, against `preferences.json`) was refused only after
  `preferences.json` had been created. Plain `lowercased()` leaves U+017F unchanged, so the
  missing-path fold did not match. The witness is kept unchanged.

## Behaviour now

- A destination is admitted only after its canonical path (through symlinks,
  including missing components) and device/inode identity are compared with the
  protected set. This happens before any directory or file creation.
- A destination is refused as `protected_path` when, compared by whole path components,
  it names a protected file, lies beneath one, or is an ancestor of one. Beneath a file,
  its parent directories would have to replace that file. As an ancestor, it would become
  a file where the protected file's directory must be. Missing and existing ancestors are
  refused alike; the guard before this pass admitted a missing one, and an existing directory
  ancestor used to fail later with a write error. Components compare with Swift
  string equality, which is canonical equivalence, so a canonically equivalent spelling of
  a protected path is refused on every volume, including a case-sensitive one
  (`testCanonicallyEquivalentSpellingIsRefusedOnCaseSensitiveVolume`).
- A name that differs from a protected path only by case or folding is compared on the
  destination's volume before anything is created, and only when a folded component
  overlaps a protected one. On a case-insensitive volume it is refused as `protected_path`.
  On a case-sensitive volume it is admitted as the distinct file it is. If the volume does
  not say, or the probe throws, it is refused as `inspection_failed`. A destination with no
  folded overlap never reaches the probe. An ancestor or descendant spelled with a folded
  name follows the same rule.
- The comparison key is the canonical caseless form: NFD, then case folding under the
  fixed locale `en_US_POSIX` (so no system locale changes the mapping), then NFD again.
  This maps long s (U+017F) to `s`, final sigma (U+03C2) and capital sigma (U+03A3) to
  `σ`, and micro sign (U+00B5) to `μ`. Diacritics are not removed, so `café` and `cafe`
  stay distinct. There is no blanket Unicode ban: a name is refused on the fold only when
  its folded components overlap a protected name's, and the volume answer then decides.
- After open, the descriptor's identity is compared before any truncate or write.
  The descriptor check stays: the path check does not see a hardlink created later.
- A dangling symlink is refused before its target could be created.
- The first refusal latches the writer, emits one `config.diagnostic_destination_refused`
  event (`sink=`, `reason=`, `resource=` codes only) and one log line derived from it.
  Later records are counted as drops. A refused events writer does not write its
  own refusal event.
- The orchestrator, audit sink and events writer share one `RuntimeEventLog`.
  The refusal gate holds that log weakly, so the writer's sink no longer closes a
  cycle through the gate. The log's owner must outlive the writer's drains. Production
  has the orchestrator own the log and drain the writers before it is released. If the
  log is already gone, the refusal still writes its console line.
- The protected path mapping lives in `ProxyControlBridge`
  (`ProxyControlBridgeProtectedDiagnosticResources.swift`), which knows the wire
  file names. `ProxyKernel` holds only the resource codes and the guard. The concrete
  guard is internal; composers receive `any RecordFileDestinationGuarding`.
- New package edge: `Conduit` (the app) depends on `ProxyControlBridge`. `pm-proxy`
  already depended on it. `pm-sim` has no bridge edge on this branch; its scenario
  file mirrors the mapping and says so.

## Limits and counts

- Protected resource codes: 13 (`ProtectedRecordResource.allCases`). The guard takes at
  most one entry per code and precondition-fails on a duplicate or an extra entry.
- Audit protected set: 12 entries. Adding `writer_lease` (`writerLeaseFile:`) makes 13.
  Events protected set: 11 entries, without `events` and the lease.
- New codes this pass: `daemon_ready` (the host writes `daemon-ready.json`) and
  `writer_lease` (opt-in; the bridge adds the entry only when a URL is passed; the lock
  name is not defined in Kernel).
- Ancestor climb: bounded by the input path, which must be under `PATH_MAX` (1024 on
  macOS). Paths at or above that refuse as `inspection_failed`. The missing-component
  list therefore holds at most 512 entries.
- Metadata: any `realpath` or `lstat` error other than ENOENT or ENOTDIR refuses the
  write. A climb continues only on those two codes.
- Relation checks reuse the bounded canonical paths. Each admit builds one component list
  per path, at most one per protected entry, and keeps no state. Nothing is cached or
  added to the public surface.
- Folding is a conservative approximation, not APFS's own table and not an exact
  filesystem identity. It is consulted only on a folded overlap. Its two directions are:
  - Over-refusal: a fold match on a case-insensitive or unknown volume is refused, including
    a name that volume keeps distinct. A case-sensitive volume admits it. This is conservative
    and does not expose a protected file.
  - Unprotected lookup: a name the volume aliases, but that neither canonical equivalence nor
    this fold maps onto a protected name, is not refused by the path check. If the protected
    file is missing, the open can create it under the alias name before the descriptor check.
    The descriptor check then refuses it before any truncate or write, but the blank file
    stays. This is not tested, and the owner's deployment volumes were not probed. The APFS
    alias probes cited under "Not verified" were run by the owner's Codex session, not by this
    pass.
  - Canonical equivalence is not in this gap. Swift equality refuses it on every volume.
- Owned tests: `DiagnosticDestinationGuardTests` 18 (14 before this pass, plus the canonical
  spelling refusal on a case-sensitive volume, the missing nested-config ancestor refusal,
  the sibling admission with no volume answer, and the folded ancestor/descendant rule),
  `AuditDestinationGuardTests` 10 (plus the nested-config writer check with a real sibling
  write), `DiagnosticDestinationReviewRegressionTests` 4 (the parent witness is the fourth,
  alongside the two case witnesses and the weak-lifetime test).

## Evidence

This run: `bash /private/tmp/conduit-runtime-stage1-20261024/verify-auditguard.sh` (no suffix),
printed `PASS: diagnostic guard focused build/tests/fences/decisions/scenario`. The script uses
`set -e`, so each step below exited 0. Logs are under
`/private/tmp/conduit-runtime-stage1-20261024/auditguard-checks/`, overwritten by this run.

- `build.log`: `xcrun swift build` completed (`Build complete! (8,46 sec)`). No `warning:` or
  `error:` lines.
- `tests.log`: filtered run `AuditDestination|DiagnosticDestination|ConnectionAuditSink|BoundedRecordWriter|RuntimeEventFile|AppStateHarness`:
  158 tests, 0 failures. Among them, all passed and none were skipped:
  - `DiagnosticDestinationReviewRegressionTests` 4: the parent witness
    (`testDestinationBeneathMissingConfigIsRefusedBeforeCreatingConfigDirectory`), the case-alias
    witness, the long-s witness (`testMissingUnicodeCaseAliasIsRefusedBeforeCreatingPreferences`),
    and the weak-lifetime test. The two case witnesses ran on the real volume, not skipped.
  - `DiagnosticDestinationGuardTests` 18, including the 4 tests added this pass.
  - `AuditDestinationGuardTests` 10, including the 1 test added this pass.
- `imports.log`: kernel import and `Process` fence passed (97 Swift files).
- `events.log`: catalogue check passed, 204 names.
- `decisions.log`: `check-decisions.py --require-history` passed.
- `sim.log`: `pm-sim diagnostic-destination-guard` PASS, all nine checks `[pass]`.

The filtered run is not the full suite. The earlier note's 152 was a different run and is not
reconciled against this 158 beyond the per-suite counts above.

## Not verified

- The full `swift test` run, the `.github/workflows/swift.yml` gate, `pm-sim all`, the other
  `scripts/` checks and `perf-gate.sh` have not been run. Only the filtered set above ran.
- The ENOENT/ENOTDIR climb, the lstat error branch and the `PATH_MAX` refusal have no
  direct test.
- The ancestor relations are tested with an injected volume answer and on a temporary
  directory. No test pins the reason code for an existing directory destination, which is now
  refused as `protected_path`, not failing later with a write error.
- The folded-ancestor and folded-descendant rules are tested only with injected probe answers.
  The real-volume case-alias witness covers the exact fold only.
- The APFS-versus-Unicode folding gap above (the unprotected-lookup direction) has no test
  and was not probed on any volume in this run. No exact APFS Unicode table is claimed. The earlier APFS alias probes
  (`Sigma.json`/`sigma.json`, `Σ.json`/`ς.json`, `preferences.json`/`preferenceſ.json`,
  `state-writer.lock`/`ſtate-writer.lock`, `μ.json`/`µ.json`) were run by the owner's
  Codex session, not by this pass, and are cited here, not re-run.
- The real-volume witnesses ran on this machine's temporary volume. The owner's deployment
  storage is not verified.
- Real `pm-proxy --config <root>/events.ndjson` with a live config outside tests.
- Concurrent external retargeting of a path between admission and write. The
  descriptor check narrows the window and does not close it.
- The pm-sim mirror of the bridge mapping must be replaced by the bridge call once the
  other branch's `pm-sim` → `ProxyControlBridge` edge lands.

## Codex composition follow-up

After Claude's158-test/9-assertion focused checkpoint, Codex executed the [actual pm-proxy loopback probe](experiments/diagnostic-destination/README.md): two local HTTP requests succeeded despite an audit-on-config refusal, one refusal event was emitted, config bytes stayed unchanged, and the child stopped normally. The initial probe's EOF assumption timed out and was corrected; only the successful bounded-response run is counted.

After stacking over the private-codec branch's existing pm-sim-to-Bridge edge, the diagnostic simulator uses the production bridge factory instead of a copied protected-resource mapping. Fixture cleanup errors are surfaced instead of discarded. Final integrated checks follow these source edits; earlier focused results do not cover those edits.
