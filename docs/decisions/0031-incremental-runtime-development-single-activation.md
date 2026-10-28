# 0031: Incremental runtime development with one AppState activation

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186: selected “Incremental development; one final AppState switch (Recommended)”)
- Implementation: partial
- Validation: none
- Supersedes: 0001, 0013
- Superseded by: none

## Context

[0001](0001-one-runtime-host.md) selected one shared runtime and separate AppState
lifecycle activations: DNS, tunnels, then proxy. [0013](0013-runtime-module-isolation.md)
settled the module graph and later isolation of the whole control-owner cluster.
The host/client/store foundations are now implemented separately from AppState
adoption. Source review found shared DNS/intercept, repair, recovery, configuration
and reconciler-baseline dependencies. Separate active switches remain feasible,
but require temporary private execution capabilities and coordination while
remaining lifecycle bodies still live in AppState.

The owner selected one final AppState switch after reviewing both alternatives
with Claude and Codex in [#186](https://github.com/srps/Conduit/issues/186).
Supersession changes the activation sequence and staged adoption order only;
the replacement record explicitly carries forward the other module, contract,
isolation and ownership decisions below. It does not treat the
current unadopted service or a test profile as production convergence.

## Decision

Develop and verify DNS, tunnels and proxy incrementally in the shared runtime,
with reviewable commits, focused parity checks, complete typed-event families
for the changed owners and independent bounded models. Activate AppState once,
after all three lifecycle paths and their combined configuration/recovery flows
meet acceptance. That integration deletes the replaced AppState runtime,
reconciler, observer and direct configuration-save paths together. Keep thin
app/daemon composition/client tests, consolidating twin suites only after parity.

Carry forward one host-neutral RuntimeHost in ConduitRuntime, hosted in process
by the app first and later reached through a daemon transport. AppState retains
drafts, editing/presentation, notifications, updates and AppKit policy. Its
runtime commands and observations use the actual async framed RuntimeClient;
no live manager or direct command shortcut crosses that client. One orchestrator,
semantic store/workflow, explicit lifecycle-intent owner and reconciler baseline
serve the activated app. Do not compose a second runtime beside AppState while
leaving its competing effect/writer owners active.

Carry forward the selected modules: ConduitRuntime owns host/composition/dispatch;
Foundation-only RuntimeEvents owns domain events; ConduitShared owns separate
control values/client/codec; ProxyControlBridge maps exhaustively. PlatformMac
owns machine protocols/managers/fakes and PlatformWork. No updater dependency on
host/auth/PAC composition is introduced. New first-party declarations stay package
scoped; broad kernel splitting is not a prerequisite.

Preserve current isolation during convergence. Afterwards move the entire runtime
control-owner cluster—including orchestrator, lanes, reconciler, retry/observer
and command/workflow coordination—to the shared RuntimeActor declared in a
low-level ProxyKernel abstraction. UI/AppKit remain MainActor, NIO state remains
on its event loops and blocking effects remain on PlatformWork. An actor is an
isolation domain, not a singleton, dedicated thread or cross-process lease.
Keep per-host resources/tokens explicit, short owner turns, freshness checks on
both sides of suspension and one bounded total shutdown. Moving RuntimeHost alone
does not meet #47/#79. Keep the existing GSS and path-based socket disciplines.

Selected [save-before-apply and Stop/Quit](0015-save-before-apply.md),
[mixed-apply hold](0025-hold-mixed-configuration-apply.md),
[private configuration](0018-private-configuration-request.md),
[root-writer authority](0017-exclusive-state-directory-writer.md),
[external-edit refusal](0027-refuse-external-configuration-edits.md) and
[fixed filenames](0028-fixed-writable-state-filenames.md) are unchanged. Implementing them changes current DNS
enable ordering and needs explicit policy tests. Required unresolved saves do
not authorize Start from last-applied values. StateRootSession retains its
private lease; its narrow replacement seam must reuse the existing verified
physical primitive. No snapshot registry, parallel AppState writer coordinator,
store relocation or generic raw-lease accessor follows from this decision.

## Alternatives

- **Separate lifecycle activations:** smaller user-visible increments, but need
  temporary narrow executors/capabilities and coordinated shared DNS/config/
  recovery effects until every lifecycle moves. All commands would still need
  the same framed client and authority. The extra API, parity and deletion work
  was not selected; this is a tradeoff rather than an inherent impossibility.
- **One unverified rewrite:** avoids intermediate activation but loses the small
  source/parity review increments. Not selected: development remains incremental.
- **Finish daemon ownership first:** requires production socket/LaunchAgent and
  real Keychain/Kerberos/CFNetwork evidence before the app can converge. The
  larger product/operational change remains a later milestone under 0002.

## Consequences

There is one larger activation review and broader acceptance gate. In exchange,
we do not maintain a temporary cross-owner runtime execution route. Developing
host capabilities independently remains useful work; the app dependency is added
only with its actual adoption. An unused production composition or writer-only
adapter does not count as progress on activation.

The final app switch prepares the later daemon transport swap. It does not
establish production daemon ownership, fix every legacy event, select remaining
resource budgets or remove real-machine/release checks. No interim build is
installed over the serving daily-driver app for verification.

## Invariants and verification

- DNS includes intercept ownership, reapply, repair/recovery and shutdown; shared
  manager serialization is per instance, so two objects are not one authority.
- One production composition point owns one semantic store/workflow per session;
  this is not a new claim flag or registry. The v1 status counters retain their
  existing meaning; new v2 freshness fields cannot silently repurpose them.
- The store supplies exact immutable verified inputs to one workflow/apply owner;
  no path re-read substitutes different content after verification.
- Start/save/Stop races, unknown/partial writes, stale incarnation/generation,
  external edits, callback ordering and cleanup have focused tests, typed events
  and independent bounded models. Saves never clear a newer session Stop.
- Before activation, inventory and delete every replaced writer/lifecycle/
  reconciler/observer path and prove absence of overlapping effects. One whole
  mixed-input gate and one applied baseline remain.
- Actual framed client/subscription behavior, bounded page work and responsive
  Stop/status under slow effects must be verified on the composed host. Resource
  defaults cannot be copied implicitly from experimental test fixtures.
- Every code slice runs the complete repository workflow, pm-sim and perf;
  activation additionally needs isolated native app verification and applicable
  real VPN/auth evidence. Keep owner/real-machine validation distinct from models.

## Implementation evidence

Partial: [`StateRootSession`](../../Sources/PlatformMac/StateRootSession.swift)
now owns the exhaustive component-to-file mapping and delegates replacement to
the existing primitive with its private lease.
[`ConfigurationStore`](../../Sources/ConduitRuntime/ConfigurationStore.swift)
consumes that session and removes its independent raw-plan/raw-lease constructor.
[`Session tests`](../../Tests/ConduitTests/StateRootSessionConfigurationTests.swift)
and [`pm-sim`](../../Sources/pm-sim/ScenarioConfigSessionReplacement.swift) cover
bootstrap refusal, alias preservation, conditional replacement and authority
lifetime. This is consumed store preparation, not production store/workflow
adoption or the final AppState activation. Existing foundations remain
implemented as historically recorded in 0013: the shared
[`RuntimeHost`](../../Sources/ConduitRuntime/RuntimeHost.swift), framed
[`RuntimeClient`](../../Sources/ConduitShared/RuntimeClient.swift), unadopted
[`service core`](../../Sources/ConduitRuntime/RuntimeServiceCore.swift) and
[`ConfigurationStore`](../../Sources/ConduitRuntime/ConfigurationStore.swift).
They are prerequisites, not evidence that AppState has adopted one authority.

The next [workflow integration checkpoint](../verification-runtime-workflow-2026-10-26.md)
consumes the store in production startup, and in a reload facade exercised only
by tests and pm-sim,
with exact verified inputs, typed decisions and independent model/actual-host
coverage. The service/client and AppState have not adopted that owner yet; the
[next client review](../design-runtime-editor-contract-review.md) records those
remaining integration obligations and limits.

The [physical-ordering checkpoint](../verification-runtime-physical-ordering-2026-10-27.md)
extracts the existing proxy claim rule into one small per-module
[`PhysicalLifecycle`](../../Sources/ProxyKernel/Proxy/PhysicalLifecycle.swift).
[`ProxyOrchestrator`](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift) consumes it for
DNS/intercept and native tunnels as well, so a claimed bind finishes before its
teardown and stale completions cannot publish over a newer admission.
[`Actual-loopback tests`](../../Tests/ConduitTests/RuntimePhysicalOrderingTests.swift)
cover Stop/restart ordering and repeated-Start listener/session preservation.
This is physical ordering, not AppState activation or complete resource isolation;
the remaining shared-pool Stop boundary is tracked in
[#250](https://github.com/srps/Conduit/issues/250).

The [shared module owner](../verification-runtime-module-owner-2026-10-27.md) now develops all three lanes through [`RuntimeHostLifecycle`](../../Sources/ConduitRuntime/RuntimeHostLifecycle.swift), with typed member/companion settlements and full-start completion joins. Inherited unconfigured DNS cleanup is distinguished from an ordinary configured-off Start, which preserves user resolvers. Strict guard mutations and actual-host/loopback witnesses accompany the implementation; the one AppState activation still follows actual client adoption.

Does not prove: actual app/client/store integration, RuntimeActor isolation,
production daemon ownership, real-session auth/PAC or release readiness.

The [audit-parity checkpoint](../verification-runtime-audit-parity-2026-10-27.md)
adds the shared host's guarded startup audit sink before activation, with actual
framed-client tests in [RuntimeHostAuditTests.swift](../../Tests/ConduitTests/RuntimeHostAuditTests.swift).
The legacy app construction remains until the single cut.

### Activation compatibility clarification (2026-10-27)

The app now reaches the selected preparation-time replacement rule (0037):
enabling DNS while a proxy Start is applying can supersede that Start and tear
down its partial resources. The app must report the interruption and require an
explicit retry, rather than follow the newer input. This differs from the
legacy app path; the owner has been notified, and the integration witness and
release acceptance remain due. See 0037's compatibility clarification.

### AppState activation implementation checkpoint (2026-10-28)

[`AppComposition`](../../Sources/Conduit/App/AppComposition.swift) now opens the
shared host with explicit effects. [`AppState`](../../Sources/Conduit/App/AppState.swift)
uses the ordinary/private clients; its replaced runtime, reconciler, machine
observer and direct configuration-writer paths are removed.
[`RuntimeEditorLedger`](../../Sources/Conduit/App/RuntimeEditorLedger.swift) owns
only draft/receipt authority, and
[`RuntimeObserver`](../../Sources/Conduit/App/RuntimeObserver.swift) owns bounded
client observation. The [activation checkpoint](../verification-appstate-activation-2026-10-28.md)
records focused tests, executed guard witnesses and independent source review,
with full/native/release gates separate. A subsequent hosted lifetime crash exposed unsafe unowned UI callbacks. The
internal client bridge now reads optional owner inputs before submission and
uses weak UI callbacks; observer Stop fences late results. The checkpoint records
the failure and corrected workflow evidence. This implementation is under
verification and unreleased. The complete RuntimeActor move remains unimplemented, so this
record's overall implementation status remains partial.

## Open questions

Complete the workflow freshness/private-editor observation API, preserving
client-observed prior component preconditions separately from runtime views and
intent fences. [0034](0034-private-editor-reply-frame-cap.md) selects the private
reply ceiling; actual-adapter custody and responsiveness still need verification.
Select the remaining coherent profile from measurements before
the affected adoption. [0032](0032-explicit-reload-and-reconcile.md) selects
read-only reload-and-reconcile of eligible inputs; that policy is resolved. Revisit the
activation sequence if a demonstrated delivery/compatibility need outweighs the
cost of temporary capabilities; return the concrete ownership/deletion plan for
owner review before changing this sequence. Subsystem actors or broad module
splits still require measured contention or dependency evidence.
