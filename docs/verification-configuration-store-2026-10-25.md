# Verification note: configuration store core (2026-10-25)

Scope: the internal verified configuration store in `ConduitRuntime` over the kernel's frozen loader and the `PlatformMac` verified replacement. It
is not adopted. No app, daemon, `pm-proxy` or `RuntimeClient` path constructs it, and no Start, Stop, apply, lease-acquisition or journal
writer is connected. Not owner-validated, not real-machine validated, and not measured for memory, performance, Stop fairness, lease quiescence
or release. Decisions 0015, 0017, 0026 and 0027 are linked to this note as partial evidence; no accepted decision changed.

## Components and owners

| Owner | Component |
| --- | --- |
| ProxyKernel `Support/ConfigurationFileSchema.swift` | `ConfigurationComponent` (runtime, platform, preferences). The single identity. Every legacy key is in the runtime file's one membership: a shadowed legacy key is observe-only. |
| ProxyKernel `Support/ConfigurationFileFilter.swift` | The one strict scan. It reports the legacy components whose first known key holds a non-null value (`legacyValuesPresent`), read or shadowed, and it skips a shadowed value exactly as an unknown key is skipped. |
| ProxyKernel `Support/RuntimeFileDocument.swift` | `carriedLegacyComponents`: the legacy components whose values a rewrite would drop. A shadowed component with a non-null key carries them. A read component carries them only when it decoded. |
| ProxyKernel `Support/ProxyConfigPersistence.swift` | `ConfigurationFrozenLoader.decode` (the one pure load over frozen bytes, also used by `loadAllMigrating`); `ConfigurationLegacyFallback` (the one classification and fixed text of a refused legacy component). |
| PlatformMac `VerifiedConfigurationFileReplacement.swift` | One bounded observation, one conditional replacement with read-back, and the pre-read check against an opaque baseline. |
| PlatformMac `PlatformFakes.swift` | `FakeStateFileAccess`, which enforces the OS adapter's read precondition (a configuration role, no more than its budget). |
| ConduitRuntime `ConfigurationStore*.swift` | `ConfigurationStore` (MainActor): parsed values, one baseline record and version per component, one busy slot, and typed results. Physical steps run on `PlatformWork`. |
| pm-sim `ScenarioRuntimeFileReplacement.swift` | Physical mechanism through `PlatformMac` only. Its refusals are measured with a counting fake, so no read runs before a refusal. |

## API facts

- `load(context:)` opens or reloads the three files from one observation and reads only. A refused observation keeps the last values for display
  and issues no baseline. A reload is the only way out of a latched component. The load report carries each component's fresh typed fallback.
- `commitRuntimeAndPlatform(_:_:expecting:context:)` stages both candidates before any write. A staging refusal of either starts no write. The
  platform file is written or verified first. The runtime file is written only after the platform is verified (`persisted` or `unchanged`).
- Authority is decided per component. A refused component keeps its own reason. An authorized component is held behind the refused one:
  `heldBehindPlatform` for the runtime, `heldBehindRuntime` for the platform. No refusal does I/O.
- `commitPreferences(_:expecting:context:)` is independent. It uses the same slot and the same physical path.
- `verifyUnchanged(_:expecting:context:)` checks components against their baselines without writing. A changed file latches its component.
- Every operation returns `.busy` when another holds the slot. A busy call queues nothing, retains no body and makes no read or write.
- A token is `(store incarnation, component, version)`. A token from another incarnation, an older version, or a latched component is refused as
  `baselineMismatch` or `noAuthoritativeBaseline`. The store issues a token only from its own adoption or verified write.
- Receipts are minted only from read-back or verification. Context is echoed, not authenticated.

## Legacy preference values and the preservation guard (decision 0026)

- A runtime file can carry legacy platform and preferences keys. Only a non-null value counts. A null key is absent to the typed decoders, so
  it creates no dependency.
- A required component (its sidecar absent) carries its values only when it decoded. A refused component (a wrong-kind value, or a decoder
  refusal) keeps its defaults and its typed fallback. It is not vetoed, and its warning is not a dependency.
- A shadowed component (its sidecar present) carries its values when a non-null key is present. Its keys are observed by the same scan and
  skipped without a shape check, so the file's acceptance does not change.
- `carriedLegacy` is recomputed on each reload and cleared only by a verified canonical runtime write.
- Before the runtime replacement, and after the platform verifies, the store runs one physical step on `PlatformWork`. The step re-verifies
  the preferences sidecar against its current baseline, even when the store last saved it, and then replaces the runtime file. The sidecar
  check never writes. The guard runs only when the runtime file would be rewritten. A verified unchanged runtime file is not guarded.
- Hold reasons, typed as `ConfigurationPreservationHold`:
  - `sidecarAbsent`: the sidecar does not exist. Saving the preferences first, through `commitPreferences`, is the migration path.
  - `noAuthoritativeSidecarBaseline`: the store holds no baseline for the sidecar. No I/O is made.
  - `sidecarChanged`: the sidecar was deleted, created, or edited. Its baseline is latched until a reload.
  - `sidecarUnreadable(error)`: the check could not read the sidecar. Nothing is latched.
  - `refused(refusal)`: the check was refused before any I/O.
- A platform file that already verified in the same commit is not undone. The result reports it as a persisted platform with a held runtime.
- Shadowed values (a sidecar present) are observe-only: their presence is observed, and their value is skipped without a shape check. Witnesses
  pin a shadowed wrong-kind value (adopted, no fallback, guard passes on the current sidecar), a shadowed null (no dependency, even after the
  sidecar is deleted), a null first occurrence before a later duplicate (first wins, required and shadowed), an explicit default that is present
  (held until the same value is saved), and a deleted platform sidecar with shadowed platform values (the platform check holds the runtime, and
  no preferences guard runs). `ConfigurationFileGateTests` pins filter parity: shadowed keys produce the same output bytes and refusal as the
  same file without them, and strict JSON still applies.
- Warnings have one lifetime: the load report. The store keeps no sticky warning state. A reload after the runtime rewrite reports only what the
  file then holds, and an external repair to valid values reloads with no fallback.

## Persistence facts and absence

- A missing runtime file beside a present sidecar or journal is refused, as the startup gate always was. The store refuses it at its boundary
  (`testASidecarBesideAMissingRuntimeFileIsRefusedByBothLoaders`). A missing runtime file with no sidecar and no journal is defaults.
- A missing platform or preferences sidecar beside a present runtime file takes that component's valid legacy value when the runtime file carries
  one. When its keys are absent, the shared loader adopts the defaults. Neither case writes a warning.
- A missing file keeps an explicit absent baseline, so a later save on an absent file is a conditional create. Nothing is written at open.
- An unknown journal presence holds the whole load and issues no baseline.

## Latch, version and partial semantics

- `conflict`, `unknown`, an observed change, and a changed sidecar under the guard latch the component's baseline until a reload. The version does
  not change on a latch. A reload after a latch always takes a newer version, even when the bytes are the old ones.
- Versions never wrap. A verified write, or a reload that changes observed identity, needs one more version. At the maximum the write is refused
  before any I/O (`versionExhausted`).
- A committed platform file stays committed when the runtime write fails or is held. There is no rollback and no retry.
- A verified not-persisted write keeps its baseline. The read-back covers the larger of the staged and prior byte counts.

## Evidence (final focused wrapper run, exit 0)

The source was re-reviewed before this slice with no new findings. This slice changes tests and this note only. It tightens a vacuous limit
witness and adds the compatibility edges that the observe-only rule needs. The bounded models remain sequential and bounded, not exhaustive, and
they are not a proof of the Host.

The wrapper is `/private/tmp/conduit-runtime-stage1-20261024/verify-configuration-store.sh`. Its logs are in
`/private/tmp/conduit-runtime-stage1-20261024/configuration-store-checks/`. The wrapper prints `PASS` only when every step exits 0.

| Check | Executed or observed | Result |
| --- | --- | --- |
| `xcrun swift build` | build.log | passed |
| Focused XCTest filter (`ConfigurationStore\|ConfigurationFrozen\|VerifiedConfiguration\|VerifiedRuntimeFile\|ConfigurationFile\|ConfigMigration\|ConfigExactPersistence\|ConfigSidecar\|AppStateHarnessSidecar\|Preferences`) | 193 tests, 0 failures, 0 unexpected | passed; 167 before this slice, plus 4 in `ConfigurationStoreTests`, 21 in `ConfigurationStorePreservationTests` and 1 in `ConfigurationFileGateTests` |
| `ConfigurationStoreTests` suite | 34 tests | 0 failures |
| `ConfigurationStorePreservationTests` suite | 21 tests | 0 failures |
| Runtime and platform bounded model | 8 seeds, 24 steps each. Each seed opens with a fixed prefix that renames the runtime, verifies it, and commits with fresh tokens | all nine outcome classes reached and asserted, including `heldBehindRuntime` on every seed |
| Preferences bounded model | 8 seeds, 3 segments, 4 operations each. The model removes or restores the runtime file, and it presents a saved token one commit in four | all required outcome classes and at least one refused load reached and asserted |
| Coupled fault matrix | 7 rows: platform (persisted, notPersisted, unknown, conflict) by runtime (persisted, notPersisted, unknown) | passed, with bytes, baselines and write counts asserted per row |
| Busy slot under a held read | 1 gated read in flight, refused operations while it is held, and a refused load after a cancellation | passed; the fake's log is unchanged while held |
| Existing classifier matrix (`VerifiedRuntimeFileReplacementModelTests`) | 432 cases; 288 reach the write | passed in this run; the figures are the prior run's, and this slice does not change the matrix |
| `scripts/check-kernel-imports.py` | 103 Swift files, 1 object file | passed |
| `scripts/check-event-catalogue.py` | 207 event names in product sources | passed |
| `scripts/check-decisions.py --require-history` and `scripts/test-decisions.py` | 4 fixture variants accepted, 49 mutations rejected, 5 history changes judged | passed |
| `pm-sim config-file-conditional-replacement` | outcome PASS, 16 assertions | passed |
| `pm-sim runtime-file-replacement` | outcome PASS, 17 assertions | passed |
| `pm-sim config-file-boundary` | outcome PASS, 13 assertions | passed |
| `pm-sim config-sidecar-boundary` | outcome PASS, 29 assertions | passed |

Not run by this wrapper: the full `.github/workflows/swift.yml` steps, `pm-sim all`, `scripts/perf-gate.sh` and the remaining `scripts/` checks.
The parent runs those before any push.

## Test-harness facts

- The fake's observation log holds 16 calls and traps past that. A test that makes more calls clears the log at an asserted phase boundary, and
  each phase asserts its call order. The preservation tests assert the order of the physical calls, so the guard's position is checked, not only
  its outcome.
- The fake's read enforces the OS adapter's precondition: a configuration role, and no more than the role's budget.
- `scheduleEditAfterNextRead` applies an external edit right after the next read of a path. It is used to pin the race below.
- The bounded models run sequentially on the MainActor with fake file access. They do not explore interleavings and are not exhaustive. They do
  not assert physical power-loss durability.

## Known limit, pinned and not claimed

- A noncooperating editor can delete or change the sidecar after the guard's check and before the runtime replacement, and that is not excluded.
  The runtime rewrite proceeds, the sidecar's bytes are lost, and so is the shadowed runtime value beside it.
  `testADeletionAfterTheGuardCheckIsNotExcluded` pins this outcome. The sidecar holds `false`, which differs from the default, so the reload
  shows the loss. The check is not a multi-file atomic claim (decision 0027). No source fix is made for this race.

## Seeds, bounds and limits

- Bounds: three fixed records, one busy slot, no queue, no body retained after a call returns.
- Byte budgets are the existing ones: the runtime file under its 8 MiB budget and each sidecar under the 128 KiB sidecar budget (decisions 0021 and 0026).
  Staged bytes exist only inside the call that stages and writes them. Memory per call is not measured.
- Length bounds on the typed reasons: a field label is at most 64 ASCII identifier characters; a loader reason is kept only when it is at most 160
  printable ASCII characters. Anything else is kept as its code.
- Adapter faults (failed writes, unknown read-back, a concurrent edit after the write, a read-back failure) are injected at the fake's seam or in the
  classifier harness. They are not source edits, and they do not mutate the production store.
- Not established: that a nonparticipating editor cannot race after the check (0027 names this), real-machine behaviour, Stop or Quit fences,
  host incarnation fences, apply holding (0025), the configuration event family, and the RuntimeClient configuration submission.

## Remaining owner adoption

- `AppState` and `RuntimeHost` do not construct the store. Their save paths, the editor baseline and the twin rules are unchanged. The current
  `AppState.persistConfiguration` writes the in-memory preferences after the config, so it rewrites the sidecar. That ordering is unadopted and is
  replaced when the store is adopted.
- The root lease is not acquired at startup by the store's owner, and journal writers do not call it. Startup must acquire authority before
  migration and recovery (0017 and the design note).
- The `RuntimeClient` configuration submission, the configuration event emitter, the intent-generation fences and the mixed apply hold (0025) are not implemented.
- The runtime-warning `precondition` in `adopt` is a deliberate invariant of the frozen loader: runtime loads emit no warning.
