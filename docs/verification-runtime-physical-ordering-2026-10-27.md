# Runtime physical ordering checkpoint, 2026-10-27

Status: local implementation; shared-owner/client and AppState adoption remain incomplete. This implements physical ordering under decision 0031, without changing control intent, persistence or package API signatures.

`ProxyOrchestrator` uses one small `PhysicalLifecycle` for each of proxy, DNS/intercept and native tunnels. It extracts the existing proxy claim rule: a physical effect waits for its predecessor, checks that its admission is current, then claims in the same owner turn. Once claimed, a bind or teardown finishes before another can touch its listeners. DNS config restart and tunnel reconcile retain the current physical admission instead of manufacturing a fresh Start after a Stop. Stale completions cannot publish running state or start health probing. Repeated Start keeps existing listener/session identity.

The new actual-loopback tests hold DNS inside its existing UDP-before-TCP seam and hold a tunnel effect before the next claim. They check Stop and replacement ordering, both DNS protocols, stale publication, stopped-module config edits and listener/session/pool preservation on repeated Start. The three helper tests are direct unit histories, not an independent exploration model. Actual shared-owner models and pm-sim remain required for the subsequent owner integration.

## Verification

The corrected source passed the exact verification wrapper: 574 focused tests, the existing actual-host simulator, event catalogue, decision history and whitespace checks. The parent separately executed [six production guard mutations](experiments/runtime-physical-guards/README.md); each failed its intended assertions, and the exact restored source passed all 15 focused physical tests. An independent subscription-backed Claude review accepted the claim mechanism and requested explicit restart-epoch capture plus held-teardown edit witnesses; those follow-ups and their mutations are complete. The full workflow and fresh review of the combined owner remain due.

The earlier independent baseline failed before any mutation. The first-attempt ephemeral UDP port was not necessarily the TCP pair that actually bound. Configured, currently free test pairs now make that ownership check explicit; tests and release probes are not retried. The fixture ambiguity is established from source, while the exact historical conflicting holder/schedule remains unidentified.

## Boundaries and remaining work

The orchestrator now orders its own calls; the lower-level forwarders are not made generally safe for arbitrary concurrent direct callers. Control intent, per-module lanes, store verification and client admission belong to the shared owner and are separately verified. Real-machine/VPN/auth and release acceptance are not established here.

Explicit native tunnel Stop and all-bind-failed cleanup still flush the upstream pool shared with transparent-proxy traffic. That predates this slice and is tracked in [#250](https://github.com/srps/Conduit/issues/250). Normal Start must leave that pool intact. Issue #31 is auth-memory ownership and #81 is request-spool ownership; neither covers this pool defect. Scoped connection retirement versus a separately budgeted pool remains unselected future work, with a real transparent-flow preservation witness required before claiming resource isolation.

No configuration schema, file naming, wire protocol, dependency, public/package test hook or installed daily-driver app changes follow from this physical slice.

The test seams are internal to ProxyKernel for `@testable` inspection: three lazy collaborator properties and the two DNS/tunnel physical lifecycle values. In particular, tests replace the DNS forwarder only before its first Start. No public/package hook was added. The helpers assume their owner serializes configuration pushes against starts; a caller pushing directly during a queued Start can leave that edit for a later push. Reading a newer configuration after the wait would violate the selected frozen-input rule, so it was not used as a fix. AppState's existing tunnel-lane gap and legacy termination bypass remain until the final owner activation/deletion.

The first follow-up test run failed because the observer counted repeated emissions of the same run state. It now records transitions relative to the state at registration. It still detects transient stale `running`, as the repeated DNS publication mutant confirms; no event-count or release invariant was removed.
