# 0033: Headless real-host simulation with explicit effect injection

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186: approved “the scoped pm-sim dependency and explicit effect injection”)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The shared host now owns behavior that simulator scenarios must exercise without
copying the workflow. pm-sim can reach the kernel and PlatformMac physical
mechanisms, but its target graph and ConduitRuntime's module rules exclude the
actual host. XCTest already tests the real host through @testable; the additional
simulator coverage must exercise actual composition rather than a simulated host.
The owner reviewed the boundaries and approved the scoped dependency and explicit
effect injection in [#186](https://github.com/srps/Conduit/issues/186).

## Decision

Allow pm-sim to depend on ConduitRuntime for headless actual-host scenarios. It
may use the daemon's package composition/lifecycle surface, including package
access to the reload facade. Store/workflow implementation, writer leases,
private baselines and live managers remain private. Add no public test hook or
copied runtime implementation. Use the real client adapter as its commands are
integrated; initial scenarios may use the production lifecycle facade.

Require explicit machine-facing dependencies at composition. Selecting FakeMachine
alone must not leave optional arguments that fall back to real Keychain, helper,
network observers, Kerberos recovery, process execution or resolver directories.
Production assembly selects real adapters at its entry boundary; scenario assembly
supplies fakes and scratch paths to the same runtime implementation. Inventory
other effect-bearing adapters, including PAC/authentication and probes, before
claiming isolation. Pure limits and scheduling values may retain bounded defaults.

Scenarios own scratch state and listeners, inject their credential/network/process
services, and verify bounded cleanup. No installed app, privileged helper or real
machine setting is used. Local loopback listeners and real file/lease operations
inside the owned scratch root may verify actual mechanisms. This dependency does
not itself provide a sandbox; explicit composition and verification enforce scope.

AppState's later dependency/activation gate under 0031 and the updater's exclusion
remain unchanged. No new third-party dependency, RuntimeActor move or shipping
service-profile default is selected here.

## Alternatives

- **XCTest-only real-host coverage:** keeps the graph narrow and provides real
  integration/model coverage, but would waive and defer the root requirement for
  new-runtime-behavior simulator coverage. The owner selected actual-host simulator
  coverage instead; XCTest and independent models remain necessary.
- **An intermediary harness target:** retains the same implementation dependency
  with another layer; unnecessary for this consumer.
- **Move the workflow into a lower module:** puts runtime intent/composition in
  the wrong layer solely for test access.
- **Copy the workflow or expose public test hooks:** obscures whether production
  behavior was tested and weakens the selected interface boundary.

## Consequences

The simulator gains access to the runtime composition layer. That is useful for
reproducible scenarios but increases the effects it could reach if assembly is
incomplete. Mandatory effect inputs, exhaustive inventory, failure-path witnesses
and fake/scratch-only scenarios are therefore part of acceptance, not optional
follow-up. Do not add an unused dependency edge. Keep one host implementation.

## Invariants and verification

Build production and simulator assembly through the same explicit dependency
boundary. Run focused integration tests and actual-host pm-sim scenarios covering
startup/recovery, lifecycle work and shutdown without installed-machine effects.
Verify credential, observer, process/probe and path injections; cover exceptional
setup/cleanup and join logical work before releasing scratch-root authority.
Runtime workflow changes still require their independent bounded models and typed
events. Run the full repository workflow and performance gate before shipping.

## Implementation evidence

Source: [RuntimeHostEffects](../../Sources/ConduitRuntime/RuntimeHostEffects.swift),
[daemon composition](../../Sources/ConduitDaemon/DaemonRuntimeEffects.swift) and the
[consumed target edge](../../Package.swift) require explicit effects at the entry
boundary. [RuntimeHost](../../Sources/ConduitRuntime/RuntimeHost.swift) exposes a
bounded production lifecycle/settlement facade without opening store internals.

Tests: [host integration and producer model](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift)
cover effect use, helper events, dynamic timing, bounded settlement and coalescing.
Scenario: [actual-host simulation](../../Sources/pm-sim/RuntimeHostEffectsScenarios.swift)
uses fake effects, owned listeners and scratch state, and confirms cleanup before
root release. All 40 local checks pass on the frozen source (3,320 tests, two skips;
102 simulator records and perf), with independent subscription-backed Claude review.
See [verification and limits](../verification-runtime-host-effects-2026-10-25.md).
The reviewed alternatives remain in
[design-runtime-host-simulation-review.md](../design-runtime-host-simulation-review.md).

Does not prove: real VPN/auth/PAC behavior, installed-app validation or daemon handoff.

The [workflow integration checkpoint](../verification-runtime-workflow-2026-10-26.md)
extends the actual-host scenario to verified reload/Start/Stop and listener
supersession, using mandatory state-file and loopback-probe effects. The shared
held-PAC fake is consumed by tests and pm-sim. This retains the scoped production
facade and adds no store/lease exposure or public test hook.

The upstream connectivity probe behind each routing verdict is a mandatory effect too
([`RuntimeConnectivityProbe`](../../Sources/ConduitRuntime/RuntimeHostEffects.swift)). The
daemon and app compositions name `.system`, the orchestrator's own `UpstreamProber`; the
actual-host pm-sim scenarios inject `SimulatedUpstreams.unreachable`, so a routing verdict
dials nothing. The health loop is not injected: it runs the real health check through the
real connection pool. Each actual-host scenario (VPN detection, split DNS follows VPN, host
effects) therefore configures a `ClosingUpstream` it owns: a loopback listener on an
ephemeral port that closes each connection it accepts, which the health check reports as
unreachable, as the refused port did before. Opening it registers its close with the
scenario's cleanup, so the runner closes it after the scenario returns or throws, except when
the host-effects scenario pins a host whose shutdown is unconfirmed: that listener stays open
for the rest of the process, so the pinned host can reach only an owned service. The same
port is the host-effects tunnel's remote and its audit fixture's origin. Evidence (2026-11-17, local): under a `sandbox-exec`
profile that kills the process on any outbound connection to a non-loopback address or to
`127.0.0.1:9`, all nine scenarios passed every assertion in three runs, and the owned
upstream accepted 2 to 7 connections per run. The same nine at `03fdcf9f`, before the
fixture, were killed every time, and passed with only non-loopback dials forbidden, so the
port-9 dial was the only one. With a failure injected by a temporary local change (a throw
before the configuration save, before `RuntimeHost.open` and after the run's body in VPN
detection and split DNS, and before the save in host effects), each owned port refused a
loopback connect once the runner's cleanup had drained (errno 61). With the registration
removed, the same port still accepted. With the host-effects shutdown forced unconfirmed, the
listener stayed open on purpose. The XCTest host helpers still name `.system` and dial
`127.0.0.1:9` ([#318](https://github.com/srps/Conduit/issues/318)).

## Open questions

None for this scoped change. Private editor reply sizing and remaining service
profile defaults remain separate owner gates.
