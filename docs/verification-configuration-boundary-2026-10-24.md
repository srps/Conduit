# Configuration boundary and exact persistence verification

Date: 2026-10-24. Automated scratch/fake verification, not owner or real-machine
validation. Implementation head: `fd1491eb97f8ee3129361ac14708e70ebcde7fca` on
`codex/bounded-configuration-files`. Source fingerprint, covering Sources, Tests,
scripts, workflows, resources and package/bundle inputs:
`03ab90246a8f43e5fa3dee5a39c495b87049b683da39b3bf28738f0d6f5b7b94`.
Documentation-only evidence updates follow this tested source head.

## Scope and review

Implements the runtime-file boundary and exact schema-two staging from decisions
0021–0024. Private request mapping transports bounded editable drafts; storage
representability and runtime eligibility remain separate. The private codec retains
strict framing, field types, resources and schema checks. PAC credential diagnostics
use fixed text rather than reflecting the supplied URL.

Claude Code implemented and verified bounded lexical/file adapters and the precision
and transport integration using the owner's claude.ai Max subscription, with API
credentials/overrides removed from its runner. Codex reviewed source and integration,
corrected escaped-key fixtures, reviewed refusal diagnostics and ran the complete
workflow. Existing source-policy gates remain in force. No installed Conduit or
helper was quit, replaced or installed; no VPN access was needed.

## Executed checks

- All 39 checks corresponding to `.github/workflows/swift.yml` passed on the
  unchanged source fingerprint above. This includes build, all Python/shell
  policy and regression checks, updater scratch end-to-end checks including
  signed stand-ins, HTTP/security/status/DNS diagnostics and the performance gate.
- Full Swift suite: 2846 tests, two skips, zero failures.
- `pm-sim all`: 92 result records, every record passed. New focused witnesses:
  `config-file-boundary` 13 assertions, `private-config-boundary` 16,
  `config-resource-bounds` 35, `config-exact-persistence` eight, and
  `auth-identity-length` eight.
- Integrated focused suite: 697 tests, zero failures, including all 106 AppState
  harness cases. Import fence, event catalogue and decision checks passed.
- Performance gate: 100 local concurrent tunnels, 10.21 s wall, 33,800,192 bytes
  maximum RSS and 92.0% CPU under this synthetic load. This is the existing proxy
  performance workload, not a worst-case configuration transfer memory measurement.

An earlier full run passed 38 of 39 checks but found three assertions in two old
AppState harness cases that contradicted the selected resource/save policy. The
corrected tests preserve a representable nonblocking intercept warning, separately
assert refusal of an oversized bypass list, and retain the prior requested baseline
after save failure. No production policy was loosened to satisfy them. The final
full suite above passed after those test corrections.

## Concrete evidence and limits

[RuntimeFileFilter.swift](../Sources/ProxyKernel/Support/RuntimeFileFilter.swift)
uses the shared strict cursor and scalar/list resource budgets. One filtered Data
buffer reaches a single typed document decode; unknown dense arrays and later
values are skipped without constructing their object graphs. Actual opened-file
reads use one bounded loop, one probe byte and fixed scratch storage. Legacy
component extraction no longer rereads the runtime path.

[ConfigurationFileBoundaryTests.swift](../Tests/ConduitTests/ConfigurationFileBoundaryTests.swift),
[ConfigurationFileGateTests.swift](../Tests/ConduitTests/ConfigurationFileGateTests.swift)
and [ConfigurationFileReaderTests.swift](../Tests/ConduitTests/ConfigurationFileReaderTests.swift)
exercise the exact 8 MiB boundary, one-over preservation, strict ignored contents,
escaped duplicate keys, resource parity, decoder depth, regular-file refusal and
migration staging. AppState harness tests cover import schema refusal before editor
assignment and actual save/apply gating. The reader's combined read/close error is
covered directly; no end-to-end injected OS close-failure claim is made.

The runtime file cap does not bound process RSS. Ordinary platform/preferences
sidecar reads remain unbounded, no new sidecar/journal physical cap or grammar is
selected here, and normal preferences browser-URL enforcement remains open.
The codec is not yet the adopted client engine: global one-body capacity,
Stop/status responsiveness during parsing/saving and supported-case memory/lifetimes
remain adoption gates. Exact staging is not a disk read-back receipt. Exclusive
writer adoption, asynchronous store ordering, component revisions, mixed-apply
holding, stale completion fences and total shutdown remain to implement and verify.

No hosted CI or automated bot review result is inferred from these local checks.
Release readiness is not claimed.
