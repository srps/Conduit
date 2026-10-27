# 0018: Private configuration request with frozen explicit values

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 private configuration checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0014](0014-runtime-client-stream.md) and [0015](0015-save-before-apply.md) need verified
durable intent before ordinary apply, with admission, apply outcome and Stop kept
separate. [0017](0017-exclusive-state-directory-writer.md) requires one exclusive writer
authority per state directory. Configuration values must now cross from the app to the
runtime, and some of them (the PAC, health-check and DoH URLs) can carry tokens.

The [configuration review](../design-runtime-config-transfer-review.md) compared a split
design (safe values on ordinary control, URL values through a private provider or
envelope) with one private request. The split design needs pairing states for missing,
stale and cancelled halves, plus explicit transfer across processes. The owner selected
the single private request for the #186 checkpoint on 2026-10-24.

Observed: a two-envelope split-frame probe was executed and is kept as historical
evidence in the [experiment README](../experiments/runtime-config-transfer/README.md).
The later single-envelope probe compiled and ran successfully, with eleven equal runtime
and platform round trips; its largest fixture is 5,584,533 bytes. Its candidate is
[`SingleRequestCandidate.swift`](../experiments/runtime-config-transfer/SingleRequestCandidate.swift).
Its numbers are sizing evidence only, not a configuration limit.

## Decision

1. **One private request with explicit frozen values.** A configuration update is one
   request. It carries the expected-prior runtime and platform revisions, a generation,
   the request ID, the expected host incarnation and the request budget. It also carries
   every frozen runtime field, including the PAC, health-check and DoH URL values, and every
   platform field except the app-owned launch-at-login setting. Values are explicit, not
   references. There is no snapshot registry, no reference expiry and no matching
   public/private halves.

2. **Explicit private codec, not general Codable.** The private configuration value does
   not conform to general `Codable`. Only its explicit private codec encodes or decodes it.
   URL-bearing fields use `SecretBytes` and a redacted URL wrapper. Redacted descriptions
   are logging hygiene, not a security boundary. JSON serialization can create temporary
   `String` and `Data` copies, so this record does not promise that all plaintext is zeroed.

3. **Serialization copies are explicit.** Scope temporary plaintext `String` and `Data`
   values inside the deliberate codec. This decision selects no new per-value limit.
   Total encoded-request and working-memory budgets are separate decisions.

4. **Secret-free surfaces.** Events, status, admission replies and outcome lookup carry no
   configuration value and no URL plaintext. [`RuntimeEvents`](../../Sources/RuntimeEvents)
   stays event-only. Diagnostics cannot gate control.

5. **Store and phases.** The configuration store is app-owned during convergence and
   daemon-owned later, under the writer authority of [0017](0017-exclusive-state-directory-writer.md).
   The client keeps drafts in both cases. A workflow validates, saves and verifies the
   required components through that one store, then passes the exact verified immutable
   input to `RuntimeHost`. Runtime admission waits for verified persistence. Save outcome,
   admission and apply outcome are distinct phases. Lookup distinguishes saving,
   persistence unknown or failed, runtime admission and settlement. The workflow never
   calls back a live `AppState` for newer values. One request ID follows the workflow;
   internal phase and operation IDs stay distinct types. A lost reply cannot authorize a
   blind mutation replay.

6. **Receipts are authoritative.** The store issues receipts after a verified write. A
   caller cannot supply them in the request. Required receipts follow the affected effect:
   a runtime-only change needs the configuration receipt, and a system-proxy repoint also
   needs the matching platform receipt. A failed UI preference write does not refuse runtime
   work. Multiple file writes are not an atomic transaction.

7. **Stop and deadlines.** Stop keeps its own admission capacity and sets the session fence
   before any save. A late configuration save or transfer cannot restart a stopped module.
   A caller deadline only detaches waiting. It does not revoke physical write ownership:
   started writes, their writer authority and their frozen inputs stay alive until
   quiescent or process exit. This is bounded active-operation state, not retained snapshot
   history.

8. **Module shape.** The private configuration values, the client contract and the explicit
   codec belong beside the control contract in `ConduitShared`. They do not depend on
   `ProxyKernel`. Mapping from `ProxyConfig` stays in `ProxyControlBridge`. The neutral,
   non-`Codable` `SecretBytes` implementation moves from `ProxyKernel` to `ConduitShared`,
   and `ProxyKernel` keeps a package typealias during migration. The moved implementation imports
   Foundation and Darwin only; existing Shared contracts may retain their imports. No new target, external dependency, public access,
   Shared-to-Kernel cycle or second secret wrapper is added.

9. **Refinements.** This record refines [0006](0006-module-boundaries.md), for `SecretBytes`
   placement and the private-codec exception, and [0014](0014-runtime-client-stream.md),
   for the configuration commit as a private contract rather than an ordinary typed
   command. It preserves [0015](0015-save-before-apply.md) and
   [0017](0017-exclusive-state-directory-writer.md) without superseding them. None of the
   accepted records is edited.

## Alternatives

- **Split public projection plus private URL bindings.** Viable only if both halves bind to
  the same committed input. It needs pairing and transfer states across processes. Not
  selected.
- **Snapshot registry with reference expiry.** Adds history and lifetime state, and does not
  by itself provide writer exclusion. Not selected.
- **`SecretBytes` kept in `ProxyKernel`, private contract in a bridge.** Configuration clients
  would depend on the kernel and bridge graph. That cost is a tradeoff, not a prohibition.
  Not selected.
- **General `Codable` for the private value.** Rejected: generic encoding would let an
  accidental event or status encode URL plaintext.
- **Caller-supplied receipts.** Rejected: a request cannot assert authority it does not hold.

## Consequences

- Benefit: no pairing state, one envelope and one place where URL bytes are encoded.
- Cost: configuration size stays unbounded in principle until the open budgets below are
  chosen. Accepted strings and counts remain as they are today.
- Operational risk: a stuck write holds writer authority until it is quiescent. The caller
  deadline only bounds waiting.
- Redaction is hygiene. Temporary copies can exist during serialization.
- Compatibility: no change to v1 control, helper IPC or on-disk configuration. No production
  v2 configuration command ships with this record.

## Invariants and verification

- The private value has no general `Codable` conformance. Only the explicit private codec
  encodes or decodes URL plaintext. A generic encoding path that accepts the private value
  disproves this.
- Events, status, admission replies and outcome lookup contain no configuration value or
  URL plaintext. Fixtures with artificial tokens must be absent from every secret-free
  surface. A token on one of them disproves this.
- Verified persistence precedes runtime admission. Save, admission and apply outcomes stay
  distinct in lookup. An apply without a verified save disproves this.
- The workflow never reads a live `AppState` after it starts. A callback that supplies newer
  values disproves this.
- A caller deadline never releases writer authority. A released lease with a write still in
  flight disproves this.
- Stop admission and the fence precede any save. A late save or transfer that restarts a
  stopped module disproves this.
- A caller-supplied receipt is never accepted as authority. Accepting one disproves this.
- The single-envelope candidate measures one complete envelope under its test-only mirror.
  That is sizing evidence for this shape, not a limit and not proof of the production codec.

## Implementation evidence

Partial: the `SecretBytes` placement in decision 8 is implemented, and so is a headless explicit codec for decision 2. The neutral,
non-`Codable` type is in [`SecretBytes.swift`](../../Sources/ConduitShared/SecretBytes.swift),
with its redaction, zero-on-release and constant-time equality unchanged.
[`ProxyKernel`'s `SecretBytes.swift`](../../Sources/ProxyKernel/Security/SecretBytes.swift) is
now a package typealias to it. [`SecretBytesTests`](../../Tests/ConduitTests/SecretBytesTests.swift)
keeps the behaviour tests and adds one check that both spellings name the same type.
Run on 2026-10-24 with the secret-move verification script in isolated headless mode: the
debug build passed, 86 focused credential, auth and Keychain tests passed with 0 failures
(20 of them `SecretBytesTests`), the kernel import fence passed, the decision checks passed
and `pm-sim security-boundaries` passed. Codex then ran all 39 workflow-equivalent
gates on unchanged source: 2,510 tests (two skips), all 85 simulator results and
perf passed; see the [verification checkpoint](../verification-private-config-foundation-2026-10-24.md).

Codec (headless, 2026-10-24, review correction pass): the private value types, the explicit
encoder, frame reader and decoder, and the bridge mapping to `ProxyConfig` are in
[`Sources/ConduitShared/PrivateConfiguration/`](../../Sources/ConduitShared/PrivateConfiguration/)
and [`PrivateConfigurationBridge.swift`](../../Sources/ProxyControlBridge/PrivateConfigurationBridge.swift).
The values have no general `Codable` conformance, and a test checks that no generic path
accepts them. The notes, limits, error mapping and copy inventory are in
[the codec notes](../private-configuration-codec.md). The corrected source has not been
rerun, so no validation is recorded for it.

Does not prove: the configuration store or workflow, any runtime admission or apply path,
any socket or transfer engine, the codec's allocation or Stop-latency bounds, or adoption
readiness. The frame cap is recorded under [0019](0019-private-configuration-frame-budget.md).
Their executed sizing output is in the experiment README; that candidate is sizing evidence
only and is not production code.

The local [actual-client checkpoint](../verification-runtime-client-owner-2026-10-27.md) now uses [`PrivateEditorClient`](../../Sources/ConduitShared/PrivateConfiguration/PrivateEditorClient.swift) and [`RuntimePrivateEditor`](../../Sources/ConduitRuntime/RuntimePrivateEditor.swift) for memory observations and frozen updates through the actual framed transport and sole store. Mapping/encoding occurs inside the reserved transfer. Final measurements and AppState adoption remain open.

## Open questions

- [0019](0019-private-configuration-frame-budget.md) selects one private frame and an
  eight-MiB encoded-request cap. Actual staging/decode-memory, capacity and lifetime
  bounds remain adoption work.
- Writer-authority coverage of the RuntimeEnvironment paths outside the config, platform,
  preferences and journal locations remains open, as does a stable coordination identity
  that survives atomic replacement. The [configuration review](../design-runtime-config-transfer-review.md)
  lists both as later gates under [0017](0017-exclusive-state-directory-writer.md).
- Listener handoff, total shutdown budgets, production peer authentication and readiness
  remain separate gates.
- No owner or real-machine validation of a configuration update is recorded.
