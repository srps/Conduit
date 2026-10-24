# Verification note: configuration store core (2026-10-25)

Scope: the internal verified configuration store in `ConduitRuntime` over the kernel's frozen loader and the `PlatformMac` verified replacement. It
is not adopted. No app, daemon, `pm-proxy` or `RuntimeClient` path constructs it, and no Start, Stop, apply, lease-acquisition or journal
writer is connected. Not owner-validated, not real-machine validated, and not measured for memory, performance, Stop fairness, lease quiescence
or release. Decisions 0015, 0017 and 0027 are linked to this note as partial evidence; no accepted decision changed.

## Components and owners

| Owner | Component |
| --- | --- |
| ProxyKernel `Support/ConfigurationFileSchema.swift` | `ConfigurationComponent` (runtime, platform, preferences). This is the single identity; the store adds no second enum. |
| ProxyKernel `Support/ProxyConfigPersistence.swift` | `ConfigurationFrozenLoader.decode` (the one pure load over frozen bytes); `ConfigurationLegacyFallback` (the one classification and fixed text of a refused legacy component). Legacy `[String]` warnings derive from it. |
| PlatformMac `VerifiedConfigurationFileReplacement.swift` | One bounded observation, one conditional replacement with read-back, and the pre-read check against an opaque baseline. Renamed from the runtime-only file (the algorithm is unchanged). |
| ConduitRuntime `ConfigurationStore*.swift` | `ConfigurationStore` (MainActor): parsed values, one baseline record and version per component, one busy slot, typed results. Physical steps run on `PlatformWork`. |
| pm-sim `ScenarioConfigFileConditionalReplacement.swift` | Physical mechanism through `PlatformMac` only. It gains no `ConduitRuntime` dependency. |

## API facts

- `load(context:)` opens or reloads the three files from one observation and read-only. A refused observation keeps the last values for display and
  issues no baseline. A reload is the only way out of a latched component.
- `commitRuntimeAndPlatform(_:_:expecting:context:)` stages both candidates before any write. A staging refusal of either starts no write. The
  platform file is written or verified first. The runtime file is written only after the platform is verified (`persisted` or `unchanged`).
- `commitPreferences(_:expecting:context:)` is independent. It uses the same slot and the same physical path.
- `verifyUnchanged(_:expecting:context:)` checks components against their baselines without writing. A changed file latches its component.
- Every operation returns `.busy` when another holds the slot. A busy call queues nothing, retains no body and makes no read or write.
- A token is `(store incarnation, component, version)`. A token from another incarnation, an older version, or a latched component is refused as
  `baselineMismatch` or `noAuthoritativeBaseline`. The store issues a token only from its own adoption or verified write.
- Receipts are minted only from read-back or verification. Context is echoed, not authenticated.

## Persistence facts and absence

- A missing runtime file beside a present sidecar or journal is refused, as the startup gate always was. A missing runtime file with no sidecar
  and no journal is defaults.
- A missing platform or preferences sidecar beside a present runtime file takes that component's valid legacy value when the runtime file carries
  one. When its keys are absent, the shared loader adopts the defaults. Neither case writes a warning, and the legacy path stays pending migration.
  The shared loader is unchanged, and it still supplies the legacy or default `launchAtLogin` value.
- The defaults case is pinned for a canonical runtime file with no legacy platform or preferences keys, and no sidecars: `present: false`,
  `migrationPending: true`, no fallback and no warning (`testAMissingSidecarBesideAPresentRuntimeFileAdoptsDefaultsWithNoWarning`). Adoption of
  valid legacy values is not pinned by a store test in this note.
- A malformed legacy value refuses only that component. It adopts the defaults with the typed fallback `legacyPlatformRefusedUsingDefaults` or
  `legacyPreferencesRefusedUsingDefaults`, and nothing is pending. Pinned by two malformed-legacy witnesses (wrong-kind `launchAtLogin` and
  `showMenuBarIcon`).
- A missing file keeps an explicit absent baseline, so a later save on an absent file is a conditional create. Nothing is written at open.
- An unknown journal presence holds the whole load and issues no baseline.

## Latch, version and partial semantics

- `conflict`, `unknown` and an observed change latch the component's baseline until a reload. The version does not change on a latch. A reload
  after a latch always takes a newer version, even when the bytes are the old ones, because the latch cleared the baseline. Every token issued
  before the latch therefore stays refused. Pinned by `testAnObservedChangeLatchesUntilAReloadEvenWhenTheOldBytesReturn`.
- Versions never wrap. A verified write, or a reload that changes observed identity, needs one more version. At the maximum the write is refused
  before any I/O (`versionExhausted`). Verification still works, and a new store incarnation recovers.
- Coupled commit: the platform result decides the runtime write. An unverified platform (`notPersisted`, `unknown`, `conflict`) holds the runtime
  write as `heldBehindPlatform`, so the runtime file keeps its bytes.
- A committed platform file stays committed when the runtime write fails. There is no rollback and no retry. Each file reports its own outcome.
- A verified not-persisted write keeps its baseline. The read-back covers the larger of the staged and prior byte counts.

## Evidence (final focused wrapper run, exit 0)

The wrapper is `/private/tmp/conduit-runtime-stage1-20261024/verify-configuration-store.sh`. Its logs are in
`/private/tmp/conduit-runtime-stage1-20261024/configuration-store-checks/`.

| Check | Executed or observed | Result |
| --- | --- | --- |
| `xcrun swift build` | build.log | passed |
| Focused XCTest filter (`ConfigurationStore\|ConfigurationFrozen\|VerifiedConfiguration\|VerifiedRuntimeFile\|ConfigurationFile\|ConfigMigration\|ConfigExactPersistence\|ConfigSidecar\|AppStateHarnessSidecar\|Preferences`) | 167 tests, 0 failures, 0 unexpected | passed |
| `ConfigurationStoreTests` suite inside that filter | 30 tests | 0 failures |
| Runtime and platform bounded model | 8 seeds (1, 7, 42, 99, 123, 256, 1024, 2026), 24 iterations each (192 total); each seed opens with a fixed five-operation prefix | all eight required outcome classes covered: persisted, unchanged, unchangedAbsent, changed, conflict, noAuthoritativeBaseline, baselineMismatch, heldBehindPlatform |
| Preferences bounded model | 3 seeds (1, 7, 42), 3 segments, 4 operations each (36 total) | passed |
| Coupled fault matrix | 7 rows: platform (persisted, notPersisted, unknown, conflict) by runtime (persisted, notPersisted, unknown) | passed, with bytes, baselines and write counts asserted per row |
| Busy slot under a held read | 1 gated read in flight, 2 rounds of 4 refused operations, 1 refused load after a cancellation | passed; the fake's log is unchanged while held |
| Existing classifier matrix (`VerifiedRuntimeFileReplacementModelTests`) | 432 cases; 288 reach the write; outcomes notStarted 144, unknown 216, verifiedNotPersisted 54, verifiedPersisted 18 | passed |
| Adapter-fault mutants in the classifier harness (no source edit) | hideWriteFailure 192 of 432 caught; readFailureAsMissing 265; unboundedReadBack 288; echoStagedOnReadBack 288 | caught as designed |
| `scripts/check-kernel-imports.py` | 103 Swift files, 1 object file; both RuntimeEvents files limited to Foundation | passed |
| `scripts/check-event-catalogue.py` | 207 event names in product sources, none outside `docs/events.md` | passed |
| `scripts/check-decisions.py --require-history` and `scripts/test-decisions.py` | 4 fixture variants accepted, 49 mutations rejected, 5 history changes judged | passed |
| `pm-sim config-file-conditional-replacement` | outcome PASS | passed |
| `pm-sim runtime-file-replacement` | outcome PASS | passed |
| `pm-sim config-file-boundary` | outcome PASS | passed |
| `pm-sim config-sidecar-boundary` | outcome PASS | passed |

Not run by this wrapper: the full `.github/workflows/swift.yml` steps, `pm-sim all`, `scripts/perf-gate.sh` and the remaining `scripts/` checks.
The parent runs those before any push.

## Seeds, bounds and limits

- Bounds: three fixed records, one busy slot, no queue, no body retained after a call returns. The fake's observation log is capped at 16
  entries, and the model asserts the cap on each iteration.
- Byte budgets are the existing ones: the runtime file under its 8 MiB budget and each sidecar under the 128 KiB sidecar budget (decisions 0021 and 0026).
  Staged bytes exist only inside the call that stages and writes them. Memory per call is not measured.
- Length bounds on the typed reasons: a field label is at most 64 ASCII identifier characters; a loader reason is kept only when it is at most 160
  printable ASCII characters. Anything else is kept as its code.
- The bounded models run sequentially on the MainActor with fake file access. They do not explore interleavings and are not exhaustive. They do not
  assert physical power-loss durability.
- Adapter faults (failed writes, unknown read-back, a concurrent edit after the write, a read-back failure) are injected at the fake's seam or in the
  classifier harness. They are not source edits, and they do not mutate the production store.
- Not established: that a nonparticipating editor cannot race after the check (0027 names this), real-machine behaviour, Stop or Quit fences,
  host incarnation fences, apply holding (0025), the configuration event family, and the RuntimeClient configuration submission.

## Remaining owner adoption

- `AppState` and `RuntimeHost` do not construct the store. Their save paths, the editor baseline and the twin rules are unchanged.
- The root lease is not acquired at startup by the store's owner, and journal writers do not call it. Startup must acquire authority before
  migration and recovery (0017 and the design note).
- The `RuntimeClient` configuration submission, the configuration event emitter, the intent-generation fences and the mixed apply hold (0025) are not implemented.
- The runtime-warning `precondition` in `adopt` is a deliberate invariant of the frozen loader: runtime loads emit no warning. Review should check it.
