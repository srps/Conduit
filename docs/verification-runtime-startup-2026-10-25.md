# Runtime startup ownership verification, 2026-10-25

Scope: startup adoption of the canonical state root's writer lease (decisions 0017, 0020 and 0028) in the
app and in `ConduitDaemon`. Not in scope: the configuration store, the journal writers' workflow, pm-proxy, pm-dns
and pm-tunnel read-only input, and the installed app or helper. No serving app was killed, installed or replaced.

## What changed

- `StateRootBootstrap.acquire` (`Sources/PlatformMac/StateRootSession.swift`) runs three steps before the lease, in
  order. It first runs `StateRootLayout.preflightWritableNames`, a pure check with no file-system parameter. A writer
  role's logical leaf must be its fixed slot, or a fold alias that the post-lease check decides. Any other leaf is
  `unsupportedFileName`, so an arbitrary `custom.json` or a link named `alias.json` creates nothing and takes no lock.
  It then creates a missing root and each missing ancestor, owner-only and outermost first. It then takes the lease,
  checks the root's identity before and after the layout, resolves the writer-owned layout, and takes the
  configuration's prior existence. A refusal drops the lease.
- The preflight and the post-lease check share one predicate, `slotSpelling`. A fold alias is a slot only on a volume
  that folds case, which only the post-lease check asks (`fixedSlotPath`).
- Directory setup (`StateRootLayout.prepareRoot`, `createMissingDirectories`). It climbs from the root until it meets an
  existing entry, and makes each missing name with one `StateRootFileSystem.createDirectory`, which is `mkdir(2)` with mode
  0700. This is the leaf-only regression fixed: explicit fresh roots and a fresh user's Application Support get their missing
  ancestors again. The earlier leaf-only wording was our implementation guidance, not an owner decision. The accepted
  root, name and lease policy are unchanged. An existing ancestor must be a directory once links are followed. A
  file, a dangling link or an entry that cannot be examined is refused, and nothing beneath it is created. An EEXIST from
  a racing creator is accepted only when the entry is a directory.
- Bound. `prepareRoot` refuses a root path whose C string, terminator included, exceeds `PATH_MAX` (1024 bytes on
  Darwin), as `rootUnavailable(ENAMETOOLONG)`, before any effect. The OS already enforces this bound, so the OS result
  is unchanged. The check makes it hold for every file system, fakes included. With the root at most `PATH_MAX - 1`
  bytes, the missing-name list in `createMissingDirectories` holds at most 511 entries (each prefix step adds a separator
  and a non-empty name, at least two bytes). Each entry is under `PATH_MAX` bytes. No count or size limit beyond the
  platform's own is introduced, and the array is never unbounded.
- `FakeStateRootFileSystem` follows the OS in two places. `createDirectory` needs an existing parent (ENOENT, or ENOTDIR
  under a file). `canonicalPath` of a link whose target is absent fails with ENOENT, as realpath(3) does. One
  existing expectation changed with the second fix: a case-sensitive dangling reserved alias reports
  `pathUnavailable(ENOENT)` where it reported `notRegularFile`.
- A dangling link at a fixed slot (for example `config.json` pointing at a missing file) is `path_unavailable` with ENOENT.
  No new reason class was added. The link and its missing target are left as they were.
- Presence (`testConfigPresenceIsReadOnlyAfterTheLeaseIsHeld`) is now an ordered witness. A shared effect log records
  the lease and every effect on the configuration path, and the test asserts that the first configuration touch
  comes after the lease. The earlier version only compared two sessions and is replaced.
- Case aliasing (F2). The parent's Darwin realpath probe did not reproduce the suspicion. `ConduitCase` and
  `conduitcase` resolve to the same stored spelling, device and inode on this volume. No lowercasing and no broader
  identity rewrite were made.
- Cleanup. New scratch cleanup goes through `removeScratch`, which reports a failed removal as a test failure. No
  unrelated `try?` was changed.

## Witnesses

- Overlong root (fake file system and fake lease, recording wrappers, through the production bootstrap): a root of
  `PATH_MAX` bytes is refused as `rootUnavailable(ENAMETOOLONG)` with an empty effect log and no lease attempt. The
  boundary is checked directly: `PATH_MAX - 1` bytes is accepted, `PATH_MAX` is refused.
- Nested fresh root with a custom name (OS file system and OS lease, recording wrappers): refused as
  `unsupportedFileName(.config)`, the effect log is empty, and no ancestor of the root exists afterwards.
- Every writer role (fake file system and fake lease): an arbitrary name refuses before any effect, for config,
  platform config, preferences and journal.
- Fold alias (fake): accepted on a folding volume with the lease before the case query. Refused as
  `unsupportedFileName` on a case-sensitive volume, again with the lease before the case query.
- Nested fresh root, Application Support shape `Library/Application Support/Conduit` (OS): every created directory is
  0700, and an existing directory keeps 0755.
- Order: the directories are made outermost first, all before the lease. The effect log is the order.
- Non-directory ancestor (OS): refused as `rootNotDirectory`. The file keeps its bytes, and nothing beneath it is created.
- Dangling ancestor link (OS): refused as `rootUnavailable(ENOENT)`. The link keeps its destination, and nothing is created
  through it.
- Raced root creation and raced ancestor creation (OS, racer on one named path): a racing directory is accepted, and a
  racing regular file is refused as `rootNotDirectory`. The racer reports that it reached its path, so a test cannot pass
  by never racing.
- Dangling fixed slot (OS): refused as `pathUnavailable(.config, ENOENT)`, with the link and its missing target
  unchanged.
- Fake layout checks: a missing nested root is created with its ancestors. A non-directory ancestor and an unavailable
  ancestor (EACCES) are refused. The preflight accepts the slot and fold spellings for each role.
- Production bootstrap through `pm-sim state-writer-lease` (33 checks, all pass): a busy root, a custom name refused
  with its bytes kept, a config link resolved to its contained target and kept, and the dropped session ending its
  authority.

## Checks run

Exact wrapper `verify-runtime-startup.sh`, run to completion.

- First run of this correction: the build compiled, and the test step failed to compile. One new test passed a
  `RuntimeEnvironment` initializer its arguments out of order. The script stopped at that step (`set -e`), so no test
  or later check ran. It was fixed and the wrapper was rerun.
- Final run, exit 0: `xcrun swift build` complete. `xcrun swift test` filtered: 387 tests, 0 failures, with
  `RuntimeStartupOwnershipTests` at 25 cases (was 13 before this change), `StateRootLayoutTests` at 42 (6 added in this
  change and the earlier one) and `RuntimeStartupDevPairingTests` at 3, all passed. The filter ran 369 tests with 0
  failures before the change set; the bound guard added two cases.
- `check-kernel-imports.py`: passed (106 Swift files).
- `check-event-catalogue.py`: passed (215 names).
- `check-decisions.py --require-history` and `test-decisions.py`: passed.
- `pm-sim state-writer-lease`: PASS, 33 checks. `pm-sim config-file-boundary`: PASS.

Note on the run record: a second copy of the wrapper was started by mistake while the first was still running. It
queued on SwiftPM's build lock and ran the same source to the same exit 0. Both runs produced the figures above, and the
logs under `runtime-startup-checks/` are from the later one.

## Does not prove

- Partial creation is not rolled back. If a directory fails after its ancestors were made, those directories stay. The
  refusal names the errno of the step that failed.
- A plausible fold alias on a case-sensitive volume creates the root and takes the lease before it is refused. The
  volume's answer is needed to decide it, so only a definitively unsupported name refuses before any effect.
- A `..` component in a missing configured path is not normalized, and this is observed compatibility, not a new
  regression. The parent's legacy probe (`/private/tmp/conduit-runtime-stage1-20261024/probe-legacy-dot-directory.swift`)
  ran Foundation `createDirectory(withIntermediateDirectories: true)` on `a/../b` and printed `a= true b= true`: the
  legacy path also creates both `a` and `b`. The literal prefix walk matches it. No dot-segment normalization and no ban
  were added.
- Case semantics on deployment storage. The probe covered one APFS scratch volume on this machine. Case-sensitive
  volumes, network volumes and the owner's deployment storage are not probed. The layout's folding is Foundation's,
  not APFS's own table.
- The configuration store is not constructed. Legacy writers still write through the session's resolved
  environment, pending the store workflow.
- Real-machine recovery, installed-app or helper handoff.
- A retarget after the last identity check is not excluded; this is a check, not a compare-and-swap.
- The busy entry-point proof as a scratch subprocess of the built `ConduitDaemon` and `Conduit` binaries is not in
  this wrapper. The parent runs it, together with the all-39 run and the FakeMachine and window logs.
- The app's busy behavior is stderr and exit, not an alert: no UI is up before SwiftUI, so the launch cannot show one.

## Result

Exact wrapper `verify-runtime-startup.sh`: exit 0, 387 tests with 0 failures, every static check and pm-sim scenario
above passing. This is the final frozen source; the bound guard run was the single run after the guard. The parent reruns the final source and the all-39 run. Logs are under
`/private/tmp/conduit-runtime-stage1-20261024/runtime-startup-checks/`.
