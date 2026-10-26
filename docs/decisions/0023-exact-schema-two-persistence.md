# 0023: Keep schema two and refuse inexact committed durations

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #224 precision policy checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Save-before-apply in [0015](0015-save-before-apply.md) requires applied runtime
input to equal verified persisted intent. Schema2 stores connection-check timeout
in integer milliseconds and direct-connect cache TTL in integer minutes, while
the domain/private request use Double seconds. The actual scratch persistence
probe changed a1001ms timeout to1000ms through floating-point truncation and a
90.5-second TTL to60 seconds through integer-minute storage. These are separate
problems. The [precision review](../design-runtime-store-precision-review.md)
records the executed witnesses and Claude's subscription-backed source review.
The owner selected compatibility-preserving exact saves in
[#224](https://github.com/srps/Conduit/issues/224).

## Decision

Keep the existing schema2 file format and editor units. Fix representable whole-
millisecond round trips without truncating a floating-point approximation of
an integer. Reject nonfinite/out-of-range conversions before saving or admitting
untrusted runtime input. Do not introduce arbitrary general duration ceilings
under this representability policy; respect existing product bounds.

For an ordinary durable update, stage the bounded file encoding, decode it through
the same format, and require equality with the frozen required runtime values
before any physical write or runtime admission. If those values cannot round-trip
exactly, return a fixed field-coded representability error. A90.5-second TTL or a
sub-millisecond timeout cannot be silently committed. No automatic rounding or
normalization dialog is introduced. Preserve the rejected original file.

Representability belongs to the store boundary; private requests and RuntimeHost
keep canonical seconds and never silently quantize. Treat an integer-unit value
as representable only when conversion to the integer unit and decoding back yield
the original domain value. Apply safe conversion checks before narrowing; do not
first call a trapping integer initializer. Correct runtime consumers/getters as
well as file encoding so the accepted whole-unit intent is actually applied.

Read-back verification, expected revisions, partial component results and unknown
outcomes remain separate from pre-write representability. Keep Stop/Quit behavior
from0015: a persistence refusal cannot refuse the session stop/shutdown or permit
a stale completion to re-enable. Physical writer authority lasts until writes
are quiescent, independent of caller deadlines. No new schema/registry is needed.

## Alternatives

- **Schema3 with canonical seconds:** represents fractional-minute TTLs and aligns
  domain/file units, but introduces a migration and rollback barrier: checked
  schema2 readers refuse the newer file. Revisit for a demonstrated precision
  requirement or a deliberate broader schema upgrade, with every import/load
  gate and mixed-version behavior verified.
- **Explicit caller-visible normalization:** could retain schema2 and accept more
  editor inputs, but adds confirmation/draft state and changes requested intent.
  No such flow is selected. Silent normalization violates exact committed intent.
- **Dual old/new keys under schema2:** old named-key readers consume lossy values
  or defaults and cannot preserve new semantics; not selected.
- **Blind truncation or clamping:** hides changed intent and may still trap on
  nonfinite/out-of-range inputs; not selected.
- **Require a new schema for writer leases:** ownership coordination is separate
  from file units. Combining version barriers is not required by the architecture.

## Consequences

Some in-memory values previously accepted by broad validation are refused for an
ordinary committed update. Today's schema already changes those values silently;
the new behavior makes the limitation explicit and preserves old-reader/rollback
compatibility. Future daemon/client interfaces and receipts remain independent of
file encoding, so later schema evolution need not change their contract.

## Invariants and verification

Exercise1001ms and other whole-millisecond values across editor/domain/file/runtime
consumers, exact-minute TTLs, sub-unit neighbors, zero, range boundaries, NaN and
infinity. Test refusal before any write/admission and unchanged original bytes.
Use property/seeded cases around integer-unit boundaries with decode-equality
checks independent of the conversion implementation. No cumulative precision
loss is inferred from the original single-round-trip witness.

Verify required-field equality rather than only successful JSON decoding. Test
partial component writes, read-back ambiguity, late completions, Stop/Quit fences
and writer quiescence against an independent model as the store is introduced.
Use scratch files/fakes; no installed app/helper or user configuration changes.

## Implementation evidence

Partial, integrated on branch `codex/bounded-configuration-files`. Implemented:
checked whole-millisecond and whole-minute conversion in
[DurationUnits.swift](../../Sources/ProxyKernel/Models/DurationUnits.swift); the
staged save that refuses before any write and compares the decoded sections in
[ProxyConfigPersistence.swift](../../Sources/ProxyKernel/Support/ProxyConfigPersistence.swift);
finite, nanosecond-range, documented `vpnFlap` and upstream-port validation in
[ConfigValidation.swift](../../Sources/ProxyKernel/Models/ConfigValidation.swift);
probe, connect and direct-cache TTL consumers that read canonical seconds in
[ConnectionPool.swift](../../Sources/ProxyKernel/Proxy/ConnectionPool.swift) and
[ProxyOrchestrator.swift](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift); and checked NTLM
buffer lengths in [NTLMAuth.swift](../../Sources/ProxyAuth/NTLMAuth.swift). Tests:
[DurationUnitsTests.swift](../../Tests/ConduitTests/DurationUnitsTests.swift),
[ConfigExactPersistenceTests.swift](../../Tests/ConduitTests/ConfigExactPersistenceTests.swift) and
[NTLMIdentityLengthTests.swift](../../Tests/ConduitTests/NTLMIdentityLengthTests.swift); scenario
`pm-sim config-exact-persistence` in
[ScenarioConfigExactPersistence.swift](../../Sources/pm-sim/ScenarioConfigExactPersistence.swift).

Later on the same branch: the save refuses a finite duration the runtime cannot hold
in nanoseconds (`health.*` seconds past about 9.2e9), before any write, so a value the
boundary would refuse at start is not written. Persisted JSON uses `CanonicalJSON`.
The NTLM identity lengths are checked before any digest or offset is computed; a
Negotiate name that overflows only after uppercasing is refused. Runtime consumers
read durations through `DurationUnits.runtimeNanoseconds`, which traps on an
unrepresentable value. Each entry that can run an exchange refuses one first, by field,
through the one duration inventory `RuntimeDurationField` in `ConfigValidation.swift`:
the explicit health check, tunnel start and `pm-tunnel`. The direct-connect detector
takes a checked millisecond budget (`DurationUnits.checkedMilliseconds`) and starts no
probe without one, reported as `budget_refused`. Proxy start is validated already. A
representable repair draft with start-blocking problems is saved but not reconciled
into the runtime (`AppState.saveConfig`, [0015](0015-save-before-apply.md)); the
current thin gate still reconciles platform changes at the prior runtime config.
This does not implement the mixed-component verification gate selected in0025. Events:
`config.save_rejected` (emitted by the save path) and `config.apply_held`.
The 1001 ms witness is preserved at
[docs/experiments/config-precision](../experiments/config-precision/README.md). Its
single old-code test failed with exactly three assertions against the unchanged
pre-fix source at d86aae2 (domain 1.0 for 1.001, getter 1000 for 1001, file 1000 for
1001). It proves that one case, not the whole current suite.

The initial precision wrapper passed 440 tests. Integrated with runtime-file bounds
and editable private transport, the focused suite passed 697 tests and the final
full Swift run passed 2846 tests with two skips and no failures. The exact-persistence
and authentication-length scenarios each passed eight assertions. See the
[combined verification record](../verification-configuration-boundary-2026-10-24.md)
for the complete workflow evidence and limits. These are automated checks, not
owner or real-machine validation.

Does not prove: asynchronous store ordering, read-back ambiguity, expected
revisions, partial component results, physical write quiescence, Stop/Quit fences
beyond the quit path, or shutdown latency. The gate tests drive `AppState` through the
harness, not the Settings UI. The NTLM scenario calls the real authenticator with
synthetic credentials, not a network handshake. Real-machine behavior is not covered.

Evidence, limited to the assertions that exist:

- Explicit health check: `ConfigRuntimeRangeRefusalTests` asserts the result is
  `configurationRefused` (not `unreachable`), the summary names the field and not the
  value, and `config.duration_refused` with `scope=health_check` is emitted.
- Tunnel start: the same tests assert the tunnels are `failed`, the error names the
  field, and `config.duration_refused` with `scope=tunnels` is in the event log. The
  AppState launch test (`ConfigSaveGateTests`) asserts the same through the app's start
  path, and that no system proxy was applied.
- Proxy start: no new assertion. The app's start attempt in that test ignores its result,
  so the proxy refusal comes from the existing `LocalProxyServer` validation, not from
  `config.duration_refused`.
- System wake: the test only proves it does not trap. It asserts no event.
- Direct-connect detector: `budget_refused` is emitted and no probe starts without a
  budget. A corrected budget read later admits a probe, with no relaunch. A valid budget
  stays fixed when the provider later changes, including to an invalid value.
- Recovery: `AutoRecoveryTests` asserts a refused trigger runs no step and no health
  check, and a refusal from a step's check stops the ladder before the next step. The
  orchestrator's health loop is not driven end to end.
- `pm-tunnel`: built and reviewed by code, not run.
- DNS: a grep of the runtime conversions finds no DNS caller.

Provider wiring: the orchestrator passes a provider that reads the connect timeout from
its live config box. The detector latches only a valid value, and a valid value found at
construction latches immediately, as before. The provider is called with no detector lock
held; a valid value installed by a concurrent caller wins over the one this caller read. The orchestrator wiring itself is not
tested through a probe, because probes are reached only through proxy requests.

Parent review accepted the kernel-owned duration inventory and the thin existing save gate; the sole asynchronous store/workflow remains planned.

The store's canonical-comparison correction also protects exact text intent: Unicode-equivalent Swift
strings can have different persisted URL/text bytes. Current and candidate values use the existing stagers
on the store worker, preserving known repair values without reusing equality authority. The
[verification checkpoint](../verification-configuration-source-2026-10-26.md) records source mutations,
independent review and full local checks. The separate [apply-side correction (#246)](../verification-byte-exact-runtime-intent-2026-10-26.md)
keeps the runtime adoption predicate and PAC/credential cache identity sensitive to the bytes they consume;
its own evidence and remaining checks do not imply AppState convergence.

## Open questions

Revisit schema3 for a demonstrated need for sub-millisecond probes, fractional-
minute cache TTLs, or a broader deliberate format migration. Keep rollback and
all-reader/import evidence explicit. Listener handoff and later daemon deployment
remain separate affected-slice gates; this choice changes no resource/frame cap.
