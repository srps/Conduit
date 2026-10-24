# 0026: Bound platform and preferences files through the shared file contract

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 sidecar file-boundary checkpoint)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The runtime file already has a bounded reader/filter under 0021–0024. Platform and
preferences sidecars still use unbounded reads and lack the ordinary preferences
browser-URL check. Each contains six settings. The prior records explicitly left
sidecar physical caps and discarded-value grammar open; the recovery journal is
a separate runtime-state format.

Codex and Claude reviewed the actual persistence/field inventory through Claude
Code on the owner's claude.ai Max subscription. The owner selected **"128 KiB per
sidecar (Recommended)"** in the question that also proposed shared strict filtering,
valid unknown fields, first-key behavior and preserved rejected bytes. See the
[review checkpoint](../design-configuration-sidecar-boundary.md).

## Decision

Cap each platform/preferences input file at 131,072 actual bytes. Bound the actual
read with a single probe byte; metadata is not the bound. Apply the same ceiling
to staged canonical output before physical writes. Enforce the existing 16,384 raw
UTF-8 byte browser-test-URL limit before blank-value fallback or typed expansion.
No new URL grammar, normalization or other domain-field ceiling is selected.

Use the same bounded reader, strict lexical cursor, resource policy and file
filter as the runtime file, with component-specific schema roots derived from the
actual CodingKeys. Require valid syntax, UTF-8 and Unicode escapes throughout,
including discarded unknown and later duplicate values. Valid unknown fields
remain ignored; the first known key wins, including escaped spellings. Ignored
valid huge exponents do not need Double conversion. Later discarded values do
not consume domain-field budgets; all physical bytes count toward the file cap.

Refuse wrong-kind sidecars explicitly, rather than applying the legacy runtime
component's warning/default fallback. Stage candidates before migration writes.
Refuse oversized/malformed inputs at startup or reload, report a bounded safe
reason and preserve their original bytes. Never truncate or silently discard
configured values. Ordinary preference-save refusal reaches the existing user
error presentation. Independent preference effects and save-before-apply remain
as selected; these checks do not implement the sole store or mixed-apply gate.

This selects no new recovery-journal cap/grammar, registry, schema migration,
writer-lease mechanism, runtime eligibility policy or listener handoff.

## Alternatives

- **Reuse 8 MiB per sidecar:** more tolerance for large unknown content/padding,
  but up to 64 times the input/work for six settings. Not selected.
- **Post-decode URL checks only:** fails the selected pre-expansion requirement
  and leaves raw input allocation unbounded without another physical gate.
- **Preserve malformed ignored values:** requires a permissive lexical mode and
  competing ordinary file contracts. Not selected. Exact old sidecar tolerance
  was not separately probed; the recorded runtime decoder witness is motivation,
  not proof of a sidecar memory measurement.
- **Reject all unknown/duplicate keys:** discards the selected valid-file
  compatibility and is unnecessary for bounded filtering.

## Consequences

A 16 KiB raw URL needs at most 98,304 encoded bytes at six bytes per decoded byte,
plus fixed keys/booleans/pretty printing, below 128 KiB. The canonical-encoder
witness verifies that encoded expansion. This is an input/output cap, not RSS.
Valid hand-edited files exceeding the cap through extra content/padding will now
be refused but preserved. Files produced from approved typed values fit.

Keep caps/schema mechanics inside persistence so later daemon/client APIs remain
stable. Revisit for a concrete new supported field that cannot fit, with
compatibility fixtures and measured input/working-memory costs. A larger cap
requires no registry or new ownership model.

## Invariants and verification

Test exact/one-over physical and raw URL bounds, worst-case escaping, whitespace
before fallback, valid unknown fields and escaped duplicates, strict discarded
values, wrong-kind refusal, standalone/combined loads, migration staging,
unchanged rejected originals and actual Settings refusal presentation. Verify
one reader/filter/resource policy path. Test with scratch files/fakes; preserve
the serving app/helper. No global memory or real-machine validation is inferred.

## Implementation evidence

Implemented on branch `codex/bounded-configuration-sidecars`; PR integration is tracked separately:

- Shared reader, gate and schema. [ConfigurationFileReader](../../Sources/ProxyKernel/Support/ConfigurationFileReader.swift)
  reads any file under a caller's
  budget. [ConfigurationFileFilter.swift](../../Sources/ProxyKernel/Support/ConfigurationFileFilter.swift) holds the one format gate,
  `ConfigurationFileGate`, which applies the budget and then the strict filter. [ConfigurationFileSchema.swift](../../Sources/ProxyKernel/Support/ConfigurationFileSchema.swift)
  builds each root from the real `CodingKeys`: the runtime file, and the platform and preferences sidecars, which refuse a wrong
  kind instead of falling back. The sidecar budget is `DomainResourceLimits.sidecarFileBytes`, 131,072 bytes, in
  [DomainResourceLimits.swift](../../Sources/ConduitShared/DomainResourceLimits.swift).
- Sidecar read, staging and save, in [ProxyConfigPersistence.swift](../../Sources/ProxyKernel/Support/ProxyConfigPersistence.swift).
  Both sidecars read through the gate and never through `Data(contentsOf:)`. Preferences check the raw browser URL before
  encoding, and every sidecar byte is staged and checked before its one write. A combined migration stages every candidate
  first. If any stage fails, no migration file is written. Physical failures after all stages succeed are reported without
  rollback.
- The save refusal is `ConfigurationSidecarSaveRefusal`. It names the file and the field, never the value. AppState reports it
  through the existing save path, in [AppState.swift](../../Sources/Conduit/App/AppState.swift). The runtime save and apply are
  not vetoed by it.
- Tests: [ConfigSidecarBoundaryTests.swift](../../Tests/ConduitTests/ConfigSidecarBoundaryTests.swift) and
  [AppStateHarnessSidecarRefusalTests.swift](../../Tests/ConduitTests/AppStateHarnessSidecarRefusalTests.swift). The runtime
  reader, filter and gate tests were updated for the shared names.
- Headless scenario: [ScenarioConfigSidecarBoundary.swift](../../Sources/pm-sim/ScenarioConfigSidecarBoundary.swift), `pm-sim config-sidecar-boundary`.
- The run and its counts are recorded in [the verification note](../verification-config-sidecar-boundary-2026-10-24.md). That is
  a local run on synthetic files, not owner validation.

Does not prove: the asynchronous sole store, physical sidecar replacement or read-back, writer and startup adoption beyond these
reads, journal or diagnostic bounds, global memory, Stop or status fairness, real-machine behavior, or release readiness. No owner
or real-machine validation is claimed.

## Open questions

None for these two configuration documents. Journal policy, full writer adoption,
intent/revision ordering, Stop/Quit fences and total shutdown remain separate
implementation/validation gates.
