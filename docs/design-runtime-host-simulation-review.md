# Real shared-host simulator coverage: owner review

Status: proposed, 2026-10-25. No dependency, access widening, harness or runtime
behavior is implemented by this review.

## Decision needed

Recommend allowing **pm-sim to depend on ConduitRuntime for headless real-host
scenarios**. Use FakeMachine, injected credential/network/process protocols and
scratch state only. Exercise production workflow and client adapters; never copy
the workflow into a simulator implementation. Keep the semantic store, baselines,
writer lease and live managers private. Prefer the same RuntimeClient/factory
boundary as client integration becomes available; do not add public or test-only
workflow accessors merely to get past a compilation fence.

This is an internal target dependency, not a new third-party package. The existing
simulator already links PlatformMac, ProxyAuth and ProxyPAC. It would now be able
to compose their actual shared runtime owner, increasing its reach and making
explicit fake-only composition essential. Do not use the installed app, helper,
real Keychain or machine networking settings.

## Current constraints

Sources/ConduitRuntime/AGENTS.md currently says:

> Only ConduitDaemon and the test target may depend on this target. ConduitUpdater
> must not gain a dependency on it, and neither may the app until it adopts the host.

It also limits package access to daemon needs or package protocol conformance.
The root AGENTS.md says:

> A new dependency in Package.swift.

and asks first before exposing a concrete type across a target boundary where a
protocol exists. Package.swift gives pm-sim no ConduitRuntime dependency. The earlier
store-core design explicitly kept pm-sim on PlatformMac's physical mechanisms.
These rules have protected the boundary during extraction; changing simulator
reach deserves an explicit owner selection. App/updater dependency restrictions
and the client's no-live-manager boundary remain unchanged.

The root also requires a pm-sim scenario for new runtime behavior. Existing
PlatformMac scenarios prove physical replacement and root authority, and the
framed-client scenario proves the client against a simulated host. Neither proves
the actual new RuntimeConfigurationWorkflow or its RuntimeHost integration.

## Alternatives

| Choice | Benefit | Tradeoff |
| --- | --- | --- |
| **Allow the internal simulator dependency (recommended)** | Scenarios can exercise the actual shared host/workflow, eventually through the same framed client. Supports the target architecture and avoids a copied implementation. | Expand the scoped module rule and dependency graph. Verify fake-only composition, narrow package interfaces and cleanup; the dependency alone does not create a valid client adapter. |
| **Keep real-host coverage in XCTest for this slice** | Preserve the existing graph. Internal workflow remains reachable with @testable; use focused tests, FakeMachine and independent bounded models. | Explicitly defer/waive real-workflow pm-sim coverage for this slice; existing physical/client-fixture scenarios do not fill that gap. Shared-host simulator coverage still needs a later decision. |

A new intermediary harness target has the same dependency problem with more
indirection. A protocol alone cannot link an implementation into the executable.
Moving workflow logic down to PlatformMac/ProxyKernel for simulator access would
break the selected responsibility boundaries. New test-only public APIs and a
simulated copy of the workflow are not recommended.

## Proposed next consumed cut

One internal MainActor RuntimeConfigurationWorkflow per RuntimeHost owns intent
and the store. The store reports verified per-file facts; the workflow gates apply;
the existing reconciler owns applied effects. The daemon opens the store after
startup migration and before constructing runtime/reconciler baselines. Preserve
explicit --config startup acceptance. Reload uses read-only store observation and
selected 0032 behavior; it gains no hidden migration/default write.

Start and Stop admission establish intent synchronously before recovery waits.
Start commits/verifies required inputs before runtime effects. Stop revokes each
unstarted replacement at the worker claim; a started replacement finishes through
read-back and its facts remain recorded. Apply checks current intent and Stop
fences after suspension. Required inputs and applied values stay distinct from
per-file store values; mixed apply remains held until the required pair verifies.
Normal editor reads and private editor reply sizing remain separate work.

Typed workflow events, focused integration tests and an independent bounded model
must accompany the cut. Any simulator dependency grant must be consumed by real
scenarios through production composition/client paths; do not add an unused graph
edge. No new external dependency, public access or production profile default is
selected here. RuntimeActor and the final AppState activation remain later gates.

## Review and status

Official Claude Code, authenticated through the owner's claude.ai Max subscription,
reviewed the source and confirmed the graph/rule conflict. No API fallback was used.
The reload decision is recorded in 0032; this simulator question is separate. No
simulator exception or implementation is authorized until the owner selects it.
