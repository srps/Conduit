# Design: VPN Flap Resilience and Direct-Mode UX

> **Status (2026-04-22): the design shipped (Phases 1–7).** File-path references throughout this doc use the pre-module-split layout (`Sources/ConduitCore/...`). Translation table for current paths:
> - `Sources/ConduitCore/Network/VPNStatusMonitor.swift` → `Sources/PlatformMac/VPNStatusMonitor.swift` (relocated during the module split)
> - `Sources/ConduitCore/Network/NetworkMonitor.swift` → `Sources/PlatformMac/NetworkMonitor.swift` (relocated during the module split)
> - `Sources/ConduitCore/Network/VPNStatusObserving.swift` → `Sources/ProxyKernel/Abstractions/VPNStatusObserving.swift` (kernel protocol; reorganized during the module split)
> - `Sources/ConduitCore/Network/VPNStateFuser.swift` → `Sources/ProxyKernel/Network/VPNStateFuser.swift` (extracted from the SCDynamicStore monitor during the module split)
> - All other `Sources/ConduitCore/...` paths in this doc now read `Sources/ProxyKernel/...` (mechanical rename during the module split).
>
> The "relocate to PlatformMac" forward-references in §"Production implementation" and §"Files added/modified" describe earlier plans that have since shipped.

## Problem

Conduit's current behavior under VPN-state changes is wrong in two correlated ways:

1. **Direct mode is loud and slow.** When all upstreams probe as unreachable, the orchestrator flips a single `directMode: Bool` and every failed direct request emits `.error` log lines (`Direct connect to <host>:<port> failed: …` in `Sources/ConduitCore/Proxy/HTTPProxyHandler.swift:298,344`, `Direct HTTP relay failed: …` at `:267`). The `trackFailureForErrorRate` warning (`Sources/ConduitCore/Proxy/ProxyOrchestrator.swift:912`) fires every ~5 s as long as the request rate stays above ~4/s. Connection stalls last 10 s per request because of `.connectTimeout(.seconds(10))` in `HTTPProxyHandler` and `SOCKS5Server`. The `cachedDirectReachable` short-circuit (`HTTPProxyHandler.swift:86`) is gated on `!directModeProvider()` so it never memoizes "host X is not directly reachable" while in direct mode.
2. **Brief VPN flaps tear down active streams.** `NWPathMonitor` reports `vpnConnected: false` on the first interface event of a flap; the existing handler runs `await refreshPACRouting(force: true) + await refreshConnectivityMode()` (~3 s blocking) and may flip into direct mode mid-stream. Historically `AutoRecovery.restartLocalProxy` called `LocalProxyServer.stop()` → `connectionPool.closeAll()`, which closed **every** entry in `allConnections` including dedicated CONNECT tunnels. **Phase 1 fixed this**: `AutoRecovery` now calls `recycleListener()` (renamed from `restartLocalProxy()`), which rebinds only the accept socket and preserves pool + dedicated tunnels. The `autoDisableOffVPN` setting (`Sources/Conduit/App/AppState.swift:566`) calls `toggleProxy()` on the first off-VPN event with no debounce. The circuit breaker (`ConnectionPool.swift:588`) trips after 5 consecutive failures with no time-window guard, so a single 1 s flap that fails 5 in-flight requests opens the breaker for 30 s.

The user impact: every brief VPN drop (sub-second to 5 s) kills active Cursor streams, Composer agent runs, and tool calls — even though macOS itself preserves the underlying TCP sockets across the transition.

## Goals

In priority order:

1. **VPN flaps are fully invisible.** No client connection torn down, no error logged, no warning emitted, no UI alarm for transient drops.
2. **Off-VPN is a first-class steady state.** No errors logged for direct-route failures of corp-internal hosts; UI says "Direct (VPN off)", not "⚠ Direct mode (upstreams unreachable)".
3. **User-initiated disconnect is fast.** Direct mode engaged within ~1 s of user clicking Disconnect, not after a 5 s grace.
4. **Real upstream outages while VPN is up still produce loud signals.** Don't make this so quiet that we hide actual proxy failures.
5. **Streaming connections survive the flap.** A CONNECT tunnel mid-download or an SSE stream completes successfully if VPN returns within ~120 s (TCP keepalive window).
6. **Resource usage stays low.** Fewer probes than today, scoped to the cases that need them.

## Non-Goals

- Reconnect arbitrary HTTP exchanges through a different upstream after partial transmission. TCP/TLS state is end-to-end; we cannot rejoin a stream we've already closed.
- Detect "VPN reasserting" for third-party VPN clients (Cisco Secure Client, GlobalProtect, etc.) via the NetworkExtension framework. See "Tier A rejected" below.
- Per-app or per-host VPN routing logic. Out of scope; orthogonal feature.
- Replace the existing `DirectConnectDetector` per-host reachability cache. The cache is correct; we just need to consult it from the direct-mode path too.

## Apple's Posture (Validating the Design)

From `[NEVPNStatus](https://developer.apple.com/documentation/networkextension/nevpnstatus)`:

> After the VPN transitions from the `disconnected` to the `disconnecting` state, the system doesn't close TCP connections, but ignores packets to and from established network connections. When the VPN transitions to another state — for example, from a Wi-Fi to a cellular network — the system ignores network traffic and the VPN client typically reconnects to the VPN server.

macOS itself preserves our sockets during VPN transitions. Our existing TCP keepalive defaults (`Sources/ConduitCore/Support/TCPKeepalive.swift`: 60 s idle + 15 s × 4 probes ≈ 120 s detection) were chosen for this exact case. The job of this design is to stop the *control plane* from overriding the kernel's conservatism.

## Detection Tiers

### Tier A — `NEVPNStatus.reasserting` via NetworkExtension framework

Rejected for v1. `NEVPNManager.shared()` only sees Personal VPN profiles configured natively in System Settings → VPN. `NETunnelProviderManager.loadAllFromPreferences` only sees configurations whose payload `VPNSubType` field equals our bundle identifier, per [Apple's docs](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager). Third-party enterprise clients (Cisco Secure Client, GlobalProtect, F5 Edge, Pulse, OpenVPN Connect) all return nothing. In a typical enterprise deployment context this is the entire population. Implementation cost (entitlement, signing, provisioning) does not match the addressable population.

Future hook: if an enterprise customer requests it and provisions a `.mobileconfig` with our `VPNSubType`, we can add Tier A as a strictly-better signal source without changing the public API of `VPNStatusObserving`.

### Tier B — `SCDynamicStore` on `utun`* interface state

Vendor-agnostic. `SystemConfiguration` framework, no entitlement required, no user prompt. Subscribe to dynamic store keys:

- `State:/Network/Interface/utun[0-9]+/Link` — link active/inactive
- `State:/Network/Interface/utun[0-9]+/IPv4` — assigned addresses
- `Setup:/Network/Service/[A-F0-9-]+` — service add/remove

Discrimination:

- **VPN flap**: `utun`* Link flips inactive briefly; interface key remains in store. Returns to active within seconds.
- **User clicked Disconnect**: VPN client deallocates the utun interface; the dynamic store key is *removed*, not changed. Unambiguous.
- **Hard outage**: Link inactive for extended period; client may eventually remove the interface.

### Tier C — `NWPathMonitor`

Already exists (`Sources/ConduitCore/Network/NetworkMonitor.swift`). After this change, **Tier C handles general network events only** (PAC URL re-fetch, DNS reconcile, description string for logging, wake-from-sleep handling). It no longer drives VPN-state inference. Tier B owns that exclusively.

This split eliminates the per-`NWPathMonitor`-event upstream-reprobe (~3 s blocking work) that today fires on every Wi-Fi roam, IPv6 RA, captive-portal check, and wake event.

## New Types

```swift
// Sources/ConduitCore/Network/VPNObservedState.swift (new)

package enum VPNObservedState: Sendable, Equatable {
    case unknown                                  // bootstrap, no signal yet
    case connected                                // ≥1 utun has Link active + IPv4 assigned
    case reasserting                              // utun present, Link inactive, within grace window
    case disconnected(reason: VPNDisconnectReason)
}

package enum VPNDisconnectReason: Sendable, Equatable {
    case userInitiated   // utun interface removed from dynamic store (clean teardown)
    case networkLost     // utun present but Link inactive past grace window
    case unknown         // tier C-only fallback (no utun observed at all)
}

// Sources/ConduitCore/Proxy/DirectModeCause.swift (new)

package enum DirectModeCause: Sendable, Equatable {
    case none                     // not in direct mode
    case transientNetworkChange   // grace-window state, fully silent
    case vpnDisconnected          // expected — silent, fast
    case noUpstreamsConfigured    // expected — silent
    case upstreamsUnreachable     // unexpected — current loud behavior, real signal
}

// Sources/ConduitCore/Proxy/ConnectionPool.swift (modified)

package enum CloseScope: Sendable, Equatable {
    case idleOnly                 // close idle pooled connections only
    case allButDedicated          // close pooled (idle + active) but preserve CONNECT tunnels
    case all                      // current behavior — total nuke (shutdown only)
}
```

`ProxyOrchestratorSnapshot` adds `vpnState: VPNObservedState` and `directModeCause: DirectModeCause`. The existing `directMode: Bool` field was removed in Phase 2's cleanup commit (no external NDJSON consumers exist; carrying it forward would require lockstep maintenance with `directModeCause` for no benefit). `vpnConnected: Bool` is similarly being replaced by `vpnState` in Phase 3 — same reasoning. If we ever need to publish a stable wire schema for external tools, schema versioning + migration is the right pattern; carrying deprecated fields on the hot path is not.

## Modules

### `VPNStatusObserving` protocol

```swift
// Sources/ConduitCore/Network/VPNStatusObserving.swift (new)

package protocol VPNStatusObserving: Sendable {
    var onChange: (@Sendable (VPNObservedState) -> Void)? { get set }
    func start()
    func stop()
}

package final class FakeVPNStatusObserver: VPNStatusObserving {
    package var onChange: (@Sendable (VPNObservedState) -> Void)?
    package func start() {}
    package func stop() {}
    package func emit(_ state: VPNObservedState) { onChange?(state) }
}
```

Production implementation lives at `Sources/ConduitCore/Network/VPNStatusMonitor.swift` (new). The module split will relocate it to `PlatformMac` per the import fence in `AGENTS.md`; until then a header comment marks the intent.

### `UtunDynamicStoreObserver`

Internal implementation detail of `VPNStatusMonitor`. Uses `SCDynamicStoreCreate`, `SCDynamicStoreSetNotificationKeys`. Runs on a dedicated `DispatchQueue(label: "io.github.srps.Conduit.VPNStateFuser")`. Emits raw events to `VPNStateFuser`.

### `VPNStateFuser` (Shape A — fuser owns the grace timer)

Single source of truth for `VPNObservedState`. The orchestrator never sees raw "link inactive" / "link active" events; it only sees terminal state transitions.

```
SCDynamicStore raw event → VPNStateFuser
                              ├─ Link inactive → start grace timer (default 5 s),
                              │                   emit .reasserting NOW
                              ├─ Link active   → cancel grace timer,
                              │                   emit .connected
                              ├─ utun removed  → cancel grace timer,
                              │                   emit .disconnected(.userInitiated)
                              └─ grace fires   → emit .disconnected(.networkLost)

                              Orchestrator only sees:
                              .reasserting | .connected | .disconnected(reason)
```

Grace timer primitive: `DispatchWorkItem` + `asyncAfter`, matching the pattern in `AppState.scheduleDNSReconcile`. Cancellable via `workItem.cancel()`. State (`[String: UtunInterfaceState]` keyed by interface name) mutated under the queue's implicit serialization.

Multi-utun policy: any utun with Link active = `.connected`. Track per-utun internally so per-interface emission can be added later without a schema break.

### `NetworkPathDebouncer` (Tier C only)

Wraps existing `NWPathMonitor` callbacks. Coalesces burst events from a single transition. Used only for general-network reactions (PAC, DNS, description). No VPN inference.

## Orchestrator Reactions

New method on `ProxyOrchestrator`:

```swift
package func handleVPNStateChange(_ state: VPNObservedState) async
```

Transition table:


| New `VPNObservedState`              | Action                                                                                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.reasserting`                      | Set `directModeCause = .transientNetworkChange`. Pause `healthChecker`. **Do not** close pool. **Do not** reprobe. Emit `RuntimeEvent(.vpn, "vpn.flap.start")`.                                           |
| `.reasserting → .connected`         | Reset `directModeCause = .none`. Call `pool.resetCircuitsAfterFlap()`. Run one upstream reprobe to verify. Resume health checks. Emit `vpn.flap.recovered` with duration + active-tunnel-count-preserved. |
| `* → .disconnected(.userInitiated)` | Set `directModeCause = .vpnDisconnected` immediately. Skip upstream reprobe (we know). Stop `healthChecker`. Start direct-mode reprobe at slow cadence (60 s). Emit `vpn.disconnected.user`.              |
| `* → .disconnected(.networkLost)`   | Same as `.userInitiated`, log `.warning`, emit `vpn.disconnected.lost`.                                                                                                                                   |
| `* → .disconnected(.unknown)`       | Use Tier C debouncer fallback; otherwise treat as `.networkLost`.                                                                                                                                         |
| `.disconnected → .connected`        | Reset breakers, full upstream reprobe, transition out of direct mode if reachable. Emit `vpn.connected`.                                                                                                  |


**Critical invariant**: no transition in this table closes active upstream channels. Phase 1 introduced `CloseScope.allButDedicated` and `.idleOnly` to express this safely — if Phase 4 ever needs to close *something* on a transition, it must use one of those two scopes (never `.all`). The discipline-layer rule is in `AGENTS.md` NEVER. Active tunnels are only ever torn down by:

- TCP keepalive declaring dead (kernel-driven)
- The peer (client or server) closing
- Explicit user action (proxy stop, restart on config change)

## Active Stream Preservation Policy

When `directModeCause ∈ {.transientNetworkChange, .vpnDisconnected}` and active tunnels exist, the snapshot reflects:

- `directModeCause = .vpnDisconnected` (routing-policy state for *new* requests)
- `activeConnections` unchanged (channel-health state)
- Stalled tunnels survive until TCP keepalive (~120 s) declares them dead

UI surfaces this split:

- Active connections counter shows `5 active (3 stalled)` when `vpnState ∈ {.reasserting, .disconnected}` AND active tunnels > 0.
- Per-connection state badge in the connections list deferred to v2.

NDJSON status snapshot includes `streamsPreservedAcrossFlaps` (cumulative). On `vpn.flap.recovered`, the value is incremented by the count of active tunnels that survived.

## Pool Hardening

### `closeAll(scope:)` audit

Implemented in Phase 1 via parameterized `LocalProxyServer.stop(scope:)` and `ProxyOrchestrator.stopProxy(scope:)`. `closeAll(scope:)` keeps `.all` as the default arg so existing call sites compile unchanged; only the call sites listed below were updated.


| Caller                                                                                                                  | Pre-Phase-1                                               | Post-Phase-1                                                           | Justification                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LocalProxyServer.stop()` (terminal teardown)                                                                           | `closeAll()`                                              | `closeAll(scope: .all)` (default)                                      | Final shutdown — correct                                                                                                                                  |
| `AutoRecovery` step 4                                                                                                   | `restartLocalProxy()` → `stop() + start()` → `closeAll()` | `recycleListener()` rebinds accept socket only; never calls `closeAll` | Step 4 nuking dedicated tunnels was the bug. Protocol method renamed `restartLocalProxy → recycleListener`.                                               |
| `applyConfigChange` proxy-restart path                                                                                  | `stopProxy()` → `closeAll()`                              | `stopProxy(scope: .allButDedicated)`                                   | Config changed but in-flight tunnels are byte-relays independent of the new listener identity                                                             |
| `tunnelConnectionPool.closeAll()` (3 sites: `startTunnels` failure cleanup, `stopTunnels`, `performTerminationCleanup`) | `closeAll()`                                              | `closeAll(scope: .all)` (default, unchanged)                           | Tunnel pool is owned by user-configured `TunnelDefinition`s — when user stops tunnels they want them stopped. Different lifecycle from VPN-flap teardown. |
| `pm-tunnel` signal handler                                                                                              | `pool.closeAll()`                                         | `closeAll(scope: .all)` (default, unchanged)                           | CLI process shutdown                                                                                                                                      |


Filter logic exposed as `ConnectionPool.connectionIDsToClose(from:scope:)` static helper for unit testing, mirroring the existing `stalledConnectionIDs(from:olderThan:)` pattern.

### Circuit breaker time-window guard

Add `firstFailureAt: Date?` to `UpstreamPoolState`. Trip only if:

```
state.consecutiveFailures >= circuitFailureThreshold (5, unchanged)
&&
now - state.firstFailureAt >= circuitBreakerWindowSeconds (default 10)
```

Reset `firstFailureAt = nil` on any success. Bursts of 5 synchronized failures within 100 ms no longer trip.

### `pool.resetCircuitsAfterFlap()`

New method. For every upstream:

```swift
state.consecutiveFailures = 0
state.firstFailureAt = nil
state.circuitState = .closed
state.openUntil = nil
state.nextOpenInterval = baseCircuitOpenInterval
// Preserves: ewmaLatencyMS (latency stats are still valid)
```

Called by the orchestrator on `.reasserting → .connected` and `.disconnected → .connected` transitions.

### `prewarmConnections` gating

Today `prewarmConnections` (`ConnectionPool.swift:212`) is launched unconditionally at `LocalProxyServer.start()`. Change: skip when `directModeCause != .none`. Saves N upstream TCP handshakes that would never be used in an off-VPN start.

## Logging and Event Posture

### Demote expected-direct errors to info

In `HTTPProxyHandler` (`handleDirectConnect`/`handleDirectHTTP`) and `SOCKS5Server.connectDirect`, change `.error` → `.info` when `directModeCause ∈ {.transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured}`. Keep `.error` for `.upstreamsUnreachable`. The cause is plumbed through the existing `directModeProvider` callback by changing its return type from `Bool` to `(Bool, DirectModeCause)`.

### Skip error-rate alarm in expected-direct

`trackFailureForErrorRate` (`ProxyOrchestrator.swift:912`) bails out when `directModeCause != .upstreamsUnreachable`. Counter still tracks (for telemetry); warning log is suppressed.

### `lastHealthSummary` strings derive from cause


| Cause                     | Summary                                                      |
| ------------------------- | ------------------------------------------------------------ |
| `.none`, healthy          | `"Healthy via <upstream> (<n> ms)"` (current behavior)       |
| `.none`, unhealthy        | `"<error> (<n> ms)"` (current behavior)                      |
| `.transientNetworkChange` | `"Network changing…"`                                        |
| `.vpnDisconnected`        | `"Direct (VPN off)"`                                         |
| `.noUpstreamsConfigured`  | `"Direct (no upstreams configured)"`                         |
| `.upstreamsUnreachable`   | `"⚠ Direct mode (upstreams unreachable)"` (current behavior) |


### New event category

Add `case vpn` to `RuntimeEventCategory`. Events:

- `vpn.flap.start`
- `vpn.flap.recovered` (detail: duration, streamsPreserved)
- `vpn.disconnected.user`
- `vpn.disconnected.lost`
- `vpn.connected`

## Configuration Surface

### `ConfigSections.health`

Add:

```swift
package var vpnFlapGraceSeconds: TimeInterval  // default 5, clamp 1...30
```

Decoded via `decodeIfPresent ?? 5`. Fully backward-compatible.

### Settings UI

`Settings → Health/Network`, alongside `healthCheckIntervalSeconds`. Tooltip:

> *"How long to wait before treating a VPN dropout as a real disconnect. During this window, brief flaps are silent and active streams are preserved."*

### Retired settings

- `autoDisableOffVPN` — silent migration. On read, drop the key, log `.notice` once if it was `true`. Behavior is now emergent from direct-mode being silent.
- `autoEnableOnVPN` — same.

### Advanced (config-file only, not in UI)

- `circuitBreakerWindowSeconds` — default 10, range 0...300
- Tier B grace timer queue label

## Telemetry

### `ProxyRuntimeMetrics`

Add:

```swift
package var vpnFlapCount: Int = 0
package var vpnFlapTotalDuration: TimeInterval = 0
package var lastVpnFlapAt: Date?
package var streamsPreservedAcrossFlaps: Int = 0
```

### Status view strip

A single line under the active-connections row:

```
Active 5 (3 stalled)  ·  Flaps 7  ·  Preserved 12  ·  Probes/min 2
```

### NDJSON status

New fields on every status snapshot. Decoder uses `decodeIfPresent ?? <default>` for back-compat. No schemaVersion bump required.

## Performance Posture

### Per-event cost (steady state)


| Source                                    | Frequency                       | Per-event cost     | Notes                                       |
| ----------------------------------------- | ------------------------------- | ------------------ | ------------------------------------------- |
| Tier B (SCDynamicStore)                   | push, on actual events only     | <1 ms callback     | Mach IPC; no polling                        |
| Tier C (NWPathMonitor)                    | bursty during transitions       | <1 ms callback     | Coalesced by debouncer                      |
| TCP keepalive on idle pooled connection   | 1 SYN-ACK / 60 s                | ~120 bytes         | Per socket                                  |
| Health check                              | 1 / 30 s                        | full HEAD via pool | Already gated; pauses during `.reasserting` |
| Direct-mode reprobe (expected cause)      | 1 / 60 s                        | N × SYN, parallel  | New cadence (was 15 s)                      |
| Direct-mode reprobe (unexpected cause)    | 1 / 15 s                        | N × SYN, parallel  | Unchanged for genuine outages               |
| `DirectConnectDetector` background probes | per-host on first miss with TTL | 1 SYN              | Bounded by `maxConcurrentProbes = 16`       |


### Wins

- **Per-`NWPathMonitor`-event upstream reprobe eliminated.** Was the single largest recurring cost; many events/day on typical macOS sessions.
- **No more `prewarmConnections` storm on flap-induced restart.** AutoRecovery no longer nukes the pool.
- **No more 30 s circuit lockout after every flap.** Time-window guard + post-flap reset.
- **Pool keep-alive across flaps** (idle entries survive → no fresh TCP+auth handshake on recovery).
- **Slower direct-mode reprobe (15 s → 60 s)** when cause is expected. 4× cut in probe traffic during off-VPN time.

### Costs

- One additional `DispatchQueue` (fuser). Few KB stack.
- Two additional codable fields per snapshot. Few bytes per NDJSON line.
- Up to 5 s of "control plane in flap state" before committing direct mode for the link-inactive path. Mitigation: utun-removed (user-initiated) path emits immediately, no grace.

## Phase Plan

Each phase is independently shippable and reviewable.

### Phase 1 — Stop closing what shouldn't be closed (LANDED)

Smallest diff with the biggest single safety win. One new type (`CloseScope`).

Shipped:

- `CloseScope` enum on `ConnectionPool` with cases `.idleOnly`, `.allButDedicated`, `.all`.
- `closeAll(scope: CloseScope = .all)` — default arg preserves all existing call sites.
- `connectionIDsToClose(from:scope:)` static helper for unit testing the filter (mirrors `stalledConnectionIDs` pattern).
- `LocalProxyServer.stop(scope: CloseScope = .all)` — parameterized so `applyConfigChange` can pass `.allButDedicated`.
- `LocalProxyServer.recycleListener()` — rebinds the accept socket only via the extracted `bindListener(...)` helper. Falls through to `start()` if there's no prior listener (cold-start safety).
- `RecoverableProxyService.restartLocalProxy → recycleListener` rename (package-scoped protocol; affected `AutoRecovery` and the test mock).
- `RecoveryStep.recycleListener` (renamed from `.restartProxy`) with description "Recycle proxy listener".
- `ProxyOrchestrator.stopProxy(scope: CloseScope = .all)` — parameterized; `applyConfigChange` proxy-restart path passes `.allButDedicated`.
- `PooledUpstreamConnection.makeForTesting(...)` package factory exposing `inUse` / `isDedicatedTunnel` / `authenticated` for unit tests (production code MUST NOT use it; documented inline).
- Discipline-layer entry in `AGENTS.md` NEVER section: "Never close active upstream channels … outside of explicit shutdown."

Tests: full suite passes (642 tests, 0 failures, 3 pre-existing skips). New tests cover `connectionIDsToClose` for `.all`, `.allButDedicated`, `.idleOnly` (including `inUse=true` and `isDedicatedTunnel=true` axes), and empty-collection cases. AutoRecoveryTests updated for the renamed protocol method.

Deviations from the original phase plan (all documented in the commit and the audit table above):

- Renamed `restartLocalProxy → recycleListener` (plan didn't specify; justified by clarity since the method no longer restarts).
- Parameterized `stop(scope:)`/`stopProxy(scope:)` (plan implied this via the `applyConfigChange` bullet but didn't prescribe the shape).
- Extracted `connectionIDsToClose` static helper (plan didn't mention; needed for testability).
- `recycleListener()` cold-start fallthrough (plan didn't specify the no-prior-listener case).
- Helper named `bindListener` not `buildServerBootstrap` (binds and returns the channel, not just the bootstrap; absorbs the retry loop).
- Log format change: `"Local proxy stopped (scope: .all)"` (was `"Local proxy stopped."`).

### Phase 2 — `DirectModeCause` plumbing (LANDED)

Shipped:

- `DirectModeCause` enum (`.none`, `.transientNetworkChange`, `.vpnDisconnected`, `.noUpstreamsConfigured`, `.upstreamsUnreachable`) with helpers `.isDirect`, `.isExpected`, `.healthSummary`.
- `ProxyOrchestratorSnapshot.directModeCause` is the single source of truth for direct-mode state. The legacy `directMode: Bool` stored field was added then removed in the same phase (cleanup commit) per the back-compat policy above.
- `setDirectMode(_ DirectModeCause)` writes only the cause to the snapshot and the shared box.
- `directModeProvider` closure: `() -> Bool` → `() -> (Bool, DirectModeCause)`. Plumbed through `LocalProxyServer`, `HTTPProxyHandler`, `SOCKS5Server`, and pm-sim test fakes.
- `HTTPProxyHandler.directFailureLogLevel(for:)` static helper: expected causes → `.info`, `.upstreamsUnreachable` → `.error`. Cause captured once at request entry to avoid mid-request flap races.
- `trackFailureForErrorRate` skips the alarm when `cause.isExpected` (broader than the design doc's literal `cause != .upstreamsUnreachable`, which would also have suppressed the alarm for `cause == .none` — i.e., when we ARE routing through upstreams normally and getting failures, the alarm SHOULD fire).
- All `lastHealthSummary` strings derived from `cause.healthSummary`.
- `RuntimePresentationAdapter.directModeCause` mirrored as `@Published`; `directMode` is a computed property (`directModeCause.isDirect`).
- `MainView.proxyDetail` uses `cause.healthSummary`.
- `refreshConnectivityMode` infers cause: empty `enabledUpstreams` → `.noUpstreamsConfigured`, otherwise `.upstreamsUnreachable` when probes fail. VPN-state-driven causes land in Phase 4.

Tests:

- `DirectModeCauseTests` (10 tests): predicate semantics, healthSummary mapping (with explicit ⚠-glyph-only-on-unexpected check), `directFailureLogLevel` demotion, Codable round-trip for the enum and for the snapshot.
- `pm-sim` scenario `direct-mode-silence` (registered in Main + runAll). Spins up two `LocalProxyServer`s with fixed `(true, .vpnDisconnected)` and `(true, .upstreamsUnreachable)` directModeProvider returns, sends a CONNECT to an RFC 5737 unreachable target, verifies the resulting "Direct connect ... failed" log line is `.info` and `.error` respectively.

Deviations from the original phase plan:

- Extracted `HTTPProxyHandler.directFailureLogLevel(for:)` as a `static func` for testability (mirrors Phase 1's `connectionIDsToClose` pattern). Plan didn't ask.
- Added `.isDirect`, `.isExpected`, `.healthSummary` helpers on `DirectModeCause` rather than scattering equivalent logic at call sites. Helpers were referenced in the design doc table but not explicitly listed as deliverables.
- `trackFailureForErrorRate` gate is `cause.isExpected`, not the literal `cause != .upstreamsUnreachable`. The literal interpretation would suppress the alarm when `cause == .none`, which is exactly when it SHOULD fire.
- Removed the back-compat custom decoder + the `directMode: Bool` field per the back-compat policy above. The original plan's bullet "add custom `init(from:)` for backward-compat" was scratched on review — sole user, no external consumers, no persisted snapshots.

### Phase 3 — `VPNStatusMonitor` (Tier B)

- New `Sources/ConduitCore/Network/VPNObservedState.swift`.
- New `Sources/ConduitCore/Network/VPNStatusObserving.swift` with `FakeVPNStatusObserver`.
- New `Sources/ConduitCore/Network/VPNStatusMonitor.swift` containing `UtunDynamicStoreObserver` + `VPNStateFuser`.
- Wire into `AppState`. Do **not** yet act on the signal in the orchestrator.

Tests: unit tests on the fuser using synthetic dynamic store events. Assert all transitions in the table emit the expected `VPNObservedState`s in the expected order with the grace timer respected.

### Phase 4 — Orchestrator reactions (LANDED)

Shipped:

- `RuntimeEventKind.vpn` enum case (kept the existing `RuntimeEventKind` name; the design doc had said `RuntimeEventCategory` but the codebase uses `Kind`). Five events emitted: `vpn.flap.start`, `vpn.flap.recovered`, `vpn.connected`, `vpn.disconnected.user`, `vpn.disconnected.lost`.
- `orchestrator.handleVPNStateChange(_:)` is now `async` and implements the full transition table.
- `ConnectionPool.resetCircuitsAfterFlap()` — closes every breaker, preserves `ewmaLatencyMS`. Exposed via `LocalProxyServer.resetCircuitsAfterFlap()` so the orchestrator doesn't reach into the pool directly.
- `ProxyOrchestrator.deriveDirectModeCause(probeSummary:)` — single function unifying VPN-driven and probe-derived cause selection. VPN-driven causes (`.transientNetworkChange`, `.vpnDisconnected`) win; probe-derived (`.noUpstreamsConfigured`, `.upstreamsUnreachable`, `.none`) is the fallback when VPN state is `.connected` or `.unknown`.
- `ProxyOrchestrator.resumeNormalRoutingIfReachable(summary:)` — shared recovery helper for the `.reasserting → .connected` and `.disconnected → .connected` paths.
- `ProxyOrchestrator.flapStartedAt: Date?` — tracks flap entry timestamp for the `vpn.flap.recovered` event detail (`duration=Nms streamsPreserved=N`).
- Reprobe cadence split: `directReprobeIntervalUnexpected = 15 s`, `directReprobeIntervalExpected = 60 s`. Picked via `directReprobeInterval(for: cause)` based on `cause.isExpected`.
- `handleNetworkChange` decoupled from upstream probe. Tier C now refreshes PAC and logs the path change; that's it. The historical per-`NWPathMonitor`-event 3-second probe storm is gone.
- `handleSystemWake` explicitly does PAC refresh + reprobe + UI update. Wake is the one Tier-C-shaped event where we DO want a probe (sleep can hide changes that wouldn't fire either tier).
- `LocalProxyServer.start()` skips `prewarmConnections` when `directModeProvider().isDirect` is true.
- Reactions are skipped while the proxy listener is stopped (snapshot still mirrors `vpnState` for UI; no events fire).

Tests:

- `VPNTransitionTableTests` (9 tests) — every transition in the table, cause-derivation priority, idempotence, no-op while stopped, vpn.flap.recovered carries duration + streamsPreserved.
- `DirectModeReprobeIntervalTests` (2 tests) — locks in the `isExpected` contract that drives the interval helper.
- `ResetCircuitsAfterFlapTests` (1 test) — covers design-doc scenario 6.7 at the unit level.

Deviations from the original phase plan:

- `handleVPNStateChange` became `async` (the recovery branches need `await refreshConnectivityMode()`). AppState's wrapper now does `Task { @MainActor in await orchestrator.handleVPNStateChange(state) }`.
- Single `deriveDirectModeCause` helper rather than per-call-site cause selection. Plan didn't prescribe the abstraction; I unified VPN+probe cause derivation into one function so the priority lives in exactly one place.
- `handleSystemWake` keeps its upstream probe. Plan said "decouple PAC refresh from VPN events" but didn't address wake; sleep can hide changes that fall through both Tier B and Tier C, so the explicit reprobe stays.
- Reactions skipped while proxy is stopped. Plan didn't specify; emitting events / scheduling timers with no listener to react is wasted work.
- `unknown → connected` is treated as a real event (emits `vpn.connected` and runs a probe). Plan's table didn't explicitly cover the cold-start case; without this, cold start would never emit a `.vpn` event in logs.
- `vpn.flap.recovered` duration + streams-preserved data is in the event `detail` string only. Plan said to add `vpnFlapTotalDuration` etc. on `ProxyRuntimeMetrics` — that lands in Phase 7 (Telemetry) instead. Phase 4 emits the data inline.
- `RuntimeEventKind.vpn` (not `RuntimeEventCategory.vpn`). Codebase uses `Kind`; doc had said `Category`. Pure naming alignment.
- `**resetCircuitsAfterFlap` was implemented in Phase 4 because the transition table has a hard dependency on it.** The design doc had it in Phase 5; Phase 5's scope correspondingly shrinks (see below).
- `.disconnected(.unknown)` is treated as `.networkLost` rather than running a Tier C debouncer fallback. The design doc had said "Use Tier C debouncer fallback; otherwise treat as `.networkLost`." I took the simpler interpretation. The case rarely fires in production (modern VPNs all use utun). Easy to add later if a user hits it.

### Phase 5 — Circuit breaker hardening (LANDED)

Scope shrank because Phase 4 already shipped `resetCircuitsAfterFlap` (transition-table dependency). Phase 5 is just the time-window guard.

Shipped:

- `HealthSection.circuitBreakerWindowSeconds: TimeInterval` (default 10, file-only config). `0` is meaningful — it disables the guard, restoring the legacy burst-trip behavior. Used by tests that want to exercise the threshold-trip semantic in isolation.
- `ProxyConfig.circuitBreakerWindowSeconds` flat accessor; Codable round-trips it; missing-field decode falls through to default.
- `UpstreamPoolState.firstFailureAt: Date?` — anchor for the failure run. Set on first failure; preserved across subsequent failures (so the window measures total elapsed time, not time-since-last-failure); cleared on success and on `resetCircuitsAfterFlap`.
- `ConnectionPool.recordFailure` splits the trip decision into two arms with explicit branch-order documentation:
  1. `halfOpen` branch: trip immediately on a single failed probe. Time-window guard does NOT apply — re-tripping after a probe is the whole point of half-open.
  2. `closed` branch: requires `consecutiveFailures >= 5` AND `now - firstFailureAt >= circuitBreakerWindowSeconds`.
- `ConnectionPool.recordSuccess` clears `firstFailureAt` (extension beyond the design doc's literal "reset in `resetCircuitsAfterFlap`" — see deviations).

Tests:

- `CircuitBreakerWindowTests` (6 tests): sync-burst no-trip, span-window do-trip, `windowSeconds=0` legacy mode, success-resets-window, `resetCircuitsAfterFlap`-resets-window, half-open re-trip semantics documentation.
- `CircuitBreakerWindowConfigTests` (4 tests): default value, accessor mirroring, Codable round-trip, missing-field default.
- Two pre-existing tests (`testCircuitBreakerOpensAfterThresholdAndClosesOnSuccess`, `testResetCircuitsClosesOpenBreakerAndPreservesEWMA`) now set `circuitBreakerWindowSeconds = 0` to keep their threshold-trip semantics. The sync-burst-no-trip behavior they previously implicitly depended on is now covered explicitly by `CircuitBreakerWindowTests`.

Deviations from the original phase plan:

- `circuitBreakerWindowSeconds = 0` explicitly meaningful as a disable. Plan said "range 0...300" but didn't spell out the disable semantic. The two existing tests above use `0` as an escape hatch to test threshold behavior in isolation.
- `firstFailureAt` reset extended to `recordSuccess`. Plan only listed `resetCircuitsAfterFlap`. Without this extension, a long-quiet-then-burst pattern would falsely trip (the `firstFailureAt` would still be anchored to a long-ago failure, satisfying the window even though recent failures are bursty). The design intent — "burst doesn't trip" — requires the success reset; the literal plan text didn't include it.
- Half-open re-trip behavior preserved with explicit branch-order documentation. Plan implied this in the design narrative ("re-tripping is the whole point") but didn't prescribe how to encode it in `recordFailure`. Two-branch `if`/`else if` makes the policy auditable.

Scenarios 6.6 and 6.7 from the original Phase 6 list are now covered by unit tests (`CircuitBreakerWindowTests` and `ResetCircuitsAfterFlapTests` respectively); Phase 6's scope correspondingly shrinks to 6.1–6.5.

### Phase 6 — `pm-sim` scenarios

Scope shrinks from 7 scenarios to 5: 6.6 and 6.7 are now covered by unit tests (Phase 5's `CircuitBreakerWindowTests` and Phase 4's `ResetCircuitsAfterFlapTests` respectively). Phase 6 covers end-to-end behavioral scenarios that exercise the full pipeline (real `LocalProxyServer` + `FakeUpstreamProxy` + `FakeOrigin` + `FakeVPNStatusObserver`) and assert on `RuntimeEvent` stream + snapshot transitions, not log strings.

New fault-injection knob: `--inject-vpn-state <state> [--for <seconds>]` driving the `FakeVPNStatusObserver` from pm-sim's `Main.swift`.


| #   | Scenario                    | Asserts                                                                                                                                                                                                                                             |
| --- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 6.1 | `vpnFlapShortIdleTunnel`    | Bring up CONNECT tunnel, simulate utun Link inactive 2 s, then active. Tunnel never received `channelInactive`; snapshot's `directModeCause` never transitioned out of `.none` for routing purposes; exactly one `vpn.flap.recovered` event.        |
| 6.2 | `vpnFlapShortActiveStream`  | Start streaming HTTP response (slow body), simulate 2 s flap, response completes successfully and was not truncated.                                                                                                                                |
| 6.3 | `vpnFlapLongOutage`         | Simulate utun Link inactive 30 s. Snapshot transitions to `directModeCause == .vpnDisconnected` after the 5 s grace, then back to `.none` (or probe-derived) when Link returns.                                                                     |
| 6.4 | `vpnUserDisconnectFastPath` | Simulate utun interface *removal*. Snapshot transitions to `directModeCause == .vpnDisconnected` within 1 s, no probe cycle (`vpn.disconnected.user` event without preceding probe events).                                                         |
| 6.5 | `vpnRapidFlapBurst`         | Fire 6 utun Link flaps in 1.5 s. **Open**: see "Phase 6 open questions" below — the original assertion ("exactly one `vpn.flap.recovered` event") doesn't match the current implementation, which emits one `vpn.flap.recovered` per up-transition. |


Implementation notes:

- The grace window default is 5 s, which makes Scenario 6.3 take ≥ 30 s wall time at default config. Phase 6 should make `VPNStatusMonitor.graceSeconds` injectable per scenario (or expose `vpnFlapGraceSeconds` config that the harness can override) so tests run in <5 s wall time.
- Scenarios 6.1 and 6.2 need a real `FakeUpstreamProxy` that holds the CONNECT tunnel open. The pm-sim harness already has this from prior baseline scenarios.
- Scenario 6.4 ("no probe cycle") is asserted by checking the `RuntimeEventLog` for the absence of probe-emit events between the user-disconnect signal and the resulting `directModeCause` change.

#### Phase 6 design decisions (resolved, then revised — see below)

- `**vpnFlapGraceSeconds` config field** (pulled forward from Phase 7): added to `HealthSection`, mirrored on `ProxyConfig` flat accessor, surfaced via Codable. `VPNStatusMonitor` reads it from config. pm-sim sets a small value (e.g., 0.2 s) so scenario 6.3 doesn't take 30 s wall time.
- **All 5 scenarios (6.1–6.5)** in source; 6.1 and 6.2 excluded from `runAll` due to authenticator plumbing (see "What's deferred" below). 6.3, 6.4, 6.5 in `runAll` and PASS.

#### Phase 6 (revised) — coalesce policy switched to min-visible debounce

The originally-shipped Phase 6 used **post-recovery suppress** (orchestrator tracks `lastFlapRecoveredAt`; `.reasserting` within `vpnFlapClusterWindowSeconds` of last recovery is suppressed). On review, this had two issues:

1. **Asymmetry**: the FIRST flap of a burst was visible (event + UI flicker), only subsequent flaps in the cluster were silent. A user couldn't tell from the events whether their VPN was hiccuping briefly or about to enter a burst.
2. **Hidden-disconnect edge case**: if a real disconnect happened within the cluster window after a flap recovery, the `.reasserting` was suppressed — the UI stayed at "Healthy" until the grace window expired and `.disconnected.lost` fired. The intermediate transient state was hidden.

**Revised design (shipped as a follow-up commit on top of Phase 6)**: minimum-visible-flap debounce in the fuser. When utun Link goes inactive after being connected, the fuser does not immediately emit `.reasserting` — it asks the caller to start a min-visible timer. If the link recovers before the timer fires, the fuser observes the recovery and returns `.noChange` (the fused state stayed at `.connected` throughout — debouncing counts as "still connected" from the orchestrator's POV). If the timer fires while the link is still down, the fuser commits the flap by transitioning to `.linkDownAwaitingRecovery` and emitting `.reasserting` (which then arms the existing grace timer for the second-stage `.disconnected.lost` decision).

Net behavior table:


| Flap duration                                  | Events                                               | UI                               |
| ---------------------------------------------- | ---------------------------------------------------- | -------------------------------- |
| < min-visible (sub-second blip)                | None                                                 | Stays "Healthy"                  |
| min-visible to grace (1–5 s default)           | One `vpn.flap.start` + one `vpn.flap.recovered`      | Briefly "Reconnecting…"          |
| > grace (5+ s)                                 | One `vpn.flap.start` + one `vpn.disconnected.lost`   | "Reconnecting…" → "Disconnected" |
| Burst of sub-min-visible flaps                 | None                                                 | Stays "Healthy"                  |
| Burst with at least one super-min-visible flap | One per visible flap; no hidden-disconnect edge case | Mixed                            |


Implementation:

- New `HealthSection.vpnFlapMinVisibleSeconds` (default 1 s, file-only, `0` disables debounce). **Replaces** the now-removed `vpnFlapClusterWindowSeconds`.
- New `UtunInterfaceState.Phase.linkDownDebouncing`. Treated as "still connected" by `fuseCurrentState` so the orchestrator sees no transition during sub-window blips.
- New `VPNStateFuser.Decision.startMinVisibleTimer(interfaceName: String)` — caller starts a per-interface timer; if it fires, caller invokes `markMinVisibleExpired(interfaceName:)` to commit the flap.
- New `VPNStatusMonitor.minVisibleSeconds` constructor parameter (mirrors `graceSeconds`). Per-interface `minVisibleWorkItems` dictionary parallel to the single `graceWorkItem`.
- Orchestrator simplified: `lastFlapRecoveredAt` and `reassertingSuppressed` removed; the `.reasserting` and `.connected` branches no longer have suppression logic. Every `.reasserting` we see is a real (super-min-visible) flap.
- Tests rewritten: 4 orchestrator-level coalesce tests removed; 4 fuser-level min-visible tests added (`testLinkDropAfterConnectedRequestsMinVisibleTimer`, `testSubWindowBlipRecoversSilently`, `testMinVisibleExpiryCommitsTheFlap`, `testMinVisibleExpiryAfterRecoveryIsNoOp`, `testFlapPathCommittedToConnectedRecovery`).
- pm-sim scenario 6.5 (`vpnRapidFlapBurst`) rewritten: drives `VPNStateFuser` directly with synthetic raw observations, asserts that 6 sub-window flaps yield `startMinVisibleTimer × 6 + noChange × 6 + emit × 0`. The min-visible timer never expires in the test (the simulated burst is faster than a real timer); production would arm and then cancel each timer per blip.

Why this is better than the originally-shipped post-recovery suppress:

- **Symmetric**: a single 200 ms blip and the FIRST blip of a burst behave identically (both silent). No "first flap visible" asymmetry.
- **No hidden-disconnect edge case**: a real disconnect arriving any time produces a normal flap → grace → disconnect sequence; nothing is suppressed.
- **Simpler code**: orchestrator drops 2 ivars + a branch; fuser gains 1 phase + 1 method; net code is simpler at the integration boundary.
- **Better honest signal**: `vpn.flap.start` events now mean "something user-visibly happened"; sub-second blips aren't logged as flaps because, functionally, they aren't.

Trade-off accepted: a legitimate "I lost VPN" event is delayed by `vpnFlapMinVisibleSeconds` seconds before user-visible (default 1 s). During that second, TCP keeps active connections alive transparently, so the delay is invisible to active streams — only the UI "Reconnecting…" label is delayed.

Phase 7 implications:

- `vpnFlapMinVisibleSeconds` Settings UI exposure (alongside `vpnFlapGraceSeconds`) — two sliders, both labeled clearly.
- `streamsPreservedAcrossFlaps` metric increments only for super-min-visible flaps. Sub-window blips don't count, which matches the user's mental model — nothing was "preserved" across a blip the user didn't notice.
- Telemetry strip "Flaps N" counts user-visible flaps, closer to the user's mental model.

### Phase 7 — UI / telemetry surface (LANDED)

Shipped:

- `**ProxyMetrics` flap telemetry fields** added on the existing `ProxyMetrics` struct (rather than a new `ProxyRuntimeMetrics` type — see deviation below):
  - `vpnFlapCount: Int`
  - `vpnFlapTotalDuration: TimeInterval`
  - `lastVpnFlapAt: Date?`
  - `streamsPreservedAcrossFlaps: Int`
  All four increment only on `.reasserting → .connected` (i.e. on `vpn.flap.recovered`). Sub-window blips never reach the orchestrator (absorbed by `VPNStateFuser`'s min-visible debounce). Real outages (`* → .disconnected → .connected`) emit `vpn.connected`, not a flap event, and do not increment.
- **Orchestrator wiring**: `ProxyOrchestrator.handleVPNStateChange(_:)` updates the four counters inside `mutateSnapshot` on the recovery branch, alongside the existing `vpn.flap.recovered` event emission. Duration-in-seconds (TimeInterval) derived from the same `flapStartedAt` timestamp the event-detail string already used.
- `**ProxyMetrics` Codable backward compatibility**: explicit `init(from:)` with `decodeIfPresent ?? 0` for the four new keys. Pre-Phase-7 NDJSON snapshots (or any saved `ProxyMetrics` payload) decode cleanly with the new fields defaulted. `ProxyMetrics.empty` and the memberwise `init` get default arguments for all new fields.
- `**RuntimePresentationAdapter`**: four new `@Published` properties (`vpnFlapCount`, `vpnFlapTotalDuration`, `lastVpnFlapAt`, `streamsPreservedAcrossFlaps`) mirror the `ProxyMetrics` counterparts on the coalesced tier — same cadence as `requestsHandled`/`failedRequests`. Counter-grade telemetry doesn't need immediate publishing.
- `**MainView` richer per-reason `vpnState` rendering**:
  - `.connected` → "Connected" (default color)
  - `.reasserting` → "Reconnecting…" (amber to flag the transient state)
  - `.disconnected(.userInitiated)` → "Disconnected (user)"
  - `.disconnected(.networkLost)` → "Disconnected (network lost)"
  - `.disconnected(.unknown)` → "Disconnected"
  - `.unknown` → "Not detected"
- **Active connections counter split**: `Active N (M stalled)` shown only when `vpnState ∈ {.reasserting, .disconnected}` AND there are active CONNECT tunnels. Otherwise falls back to a plain `Active N`. The split is rendered inside the telemetry strip's first chip, not as a separate row.
- **Telemetry strip** sits directly under the status grid in `MainView`. Four chips: `Active`, `Flaps`, `Preserved`, `Probes/min`. Visible whenever the proxy is `.running` (or `.warning`); hidden only when the proxy is stopped (cumulative counters are reset on stop). Zero values during normal operation are an honest "nothing's wrong" signal — not noise. Carries an `accessibilityLabel` that reads the full strip in one breath for VoiceOver users.
- **"Probes/min" derivation**: directly read from `directModeCause.isExpected` cadence (60 s = 1/min for expected causes, 15 s = 4/min for `.upstreamsUnreachable`, 0 when not in direct mode). No separate time-windowed metric — the strip is honest about the system's current cadence rather than a backwards-looking rate.
- `**Flaps` chip hover tooltip** surfaces `lastVpnFlapAt` (relative time, e.g. "2 min ago") and `vpnFlapTotalDuration` ("12.3s total"). These cumulative metrics would otherwise be NDJSON-only; the tooltip uses the data we collect without cluttering the strip itself. Suppressed in zero-state (no flaps yet → no tooltip).
- `**VPNStatusFormatter`** namespace enum in `Sources/Conduit/App/` holds the pure mapping helpers (`label(for:)`, `color(for:)`, `activeConnectionsLabel`, `stalledTunnelCount`, `probesPerMinute`, `flapsTooltip`). Extracted from `MainView` so the UI mapping is unit-testable without standing up a SwiftUI view tree, and so any future surface (menu-bar popover, floating window) shares the same mapping.
- **Settings UI sliders** in `Settings → Network → VPN Flap Resilience`:
  - "Min Visible Flap (s)" — slider, range 0…5 (0.25 s steps), label shows "off" when zero, hover tooltip explains the sub-window-blip semantic.
  - "Flap Grace Window (s)" — slider, range 1…30 (1 s steps), hover tooltip explains the keepalive-preserves-streams semantic.
  - Below the sliders, a one-paragraph caption explains the two-stage debounce in operator-friendly language.
- **NDJSON schema additions**: no separate code path needed — `ProxyOrchestratorSnapshot` is `Codable` and contains `runtimeStatus.metrics: ProxyMetrics`, so the new fields ride automatically. `ProxyMetrics`'s `decodeIfPresent ?? default` decoder makes legacy NDJSON streams forward-compatible.

Tests added (721 total in suite, +17 from Phase 7 + Phase 7 review):

- `RuntimePresentationAdapterTests.testVpnFlapTelemetryMirrorsMetricsAfterCoalesce` — confirms the four telemetry fields land on the coalesced tier and mirror `ProxyMetrics`.
- `ProxyMetricsCodableBackcompatTests.testLegacyPayloadDecodesWithZeroFlapMetrics` — pre-Phase-7 NDJSON payload still decodes; new fields default to 0.
- `ProxyMetricsCodableBackcompatTests.testRoundTripPreservesPhase7Fields` — encode → decode round-trip preserves all four new fields.
- `ProxyMetricsCodableBackcompatTests.testEmptyEqualsZeroDefaults` — `.empty` static still means "all counters zero," including the new ones.
- `VPNTransitionTableTests.testFlapRecoveryIncrementsTelemetryMetrics` — `.reasserting → .connected` increments all four counters by exactly one cycle.
- `VPNTransitionTableTests.testDisconnectedTransitionDoesNotIncrementFlapMetrics` — outage transitions (`.disconnected(_)`) do NOT touch the flap counters; neither does a real-outage recovery (`.disconnected → .connected`).
- `VPNTransitionTableTests.testMultipleFlapsAccumulateCounters` — three back-to-back flap-recovery cycles yield `vpnFlapCount == 3` (and accumulated duration > 0).
- `ConfigArchitectureTests.testVPNFlapFlatAliasesReadWriteAndRoundTrip` — `config.vpnFlapMinVisibleSeconds` / `config.vpnFlapGraceSeconds` flat accessors read/write through to `HealthSection` and survive a Codable round-trip (the round-trip path the Settings sliders take via `AppState.saveConfig`).
- `ConfigArchitectureTests.testVPNFlapFlatKeysAbsentDecodesWithDefaults` — legacy `ProxyConfig` payloads without the two flap keys decode with `HealthSection`'s init defaults applied (5 s grace, 1 s min-visible).
- `VPNStatusFormatterTests` — full coverage of the extracted UI mapping helpers: every `VPNObservedState` branch maps to its expected label, the active-count split correctly omits `(N stalled)` when zero, `stalledTunnelCount` is zero when VPN is `.connected` or `.unknown` and reflects active-tunnel count when reasserting/disconnected, `probesPerMinute` returns 0 / 1 / 4 across every `DirectModeCause` case, and `flapsTooltip` pluralizes correctly, formats duration to one decimal, embeds the relative-time phrase only when a date is present, and returns `nil` in zero-state. (10 tests.)

Deviations from the plan (all small, none invalidating):

- **Field set lives on `ProxyMetrics`, not a new `ProxyRuntimeMetrics` type.** The plan said "Add to `ProxyRuntimeMetrics`" but no such type exists in the codebase — `ProxyMetrics` is the existing per-runtime-status metrics struct, and the four new fields are conceptually peers to `requestsHandled` / `failedRequests`. Adding them in place keeps the snapshot shape stable and avoids a wrapper type that would only forward to the underlying fields.
- `**lastVpnFlapAt` records the recovery moment, not the flap-start moment.** The plan didn't specify; "last flap" most naturally means "the time we last completed a flap event" (i.e. the time the user would say "the VPN just flickered"). This also keeps the timestamp aligned with `vpnFlapCount` — the increment and the timestamp move together.
- **Telemetry strip is visible whenever the proxy is running, not gated on flap activity.** First Phase 7 pass suppressed zero-state; the Phase 7 review reverted that. Rationale: the strip is the project's only persistent surface for the active-connection count and the probe cadence, so hiding it during normal operation removes context. Honest zeros during steady-state are a feature; the strip transitions to non-zero values the moment anything happens. Hidden only when the proxy is stopped (cumulative counters get reset on stop and the strip would be lying).
- `**lastVpnFlapAt` and `vpnFlapTotalDuration` are surfaced in the `Flaps` chip hover tooltip, not in chip text.** Plan didn't specify — these are richer-than-counter values that would crowd the strip if rendered inline. Tooltip is opt-in (hover) which keeps the steady-state strip narrow while still using the data we collect on every flap recovery. NDJSON consumers see the raw fields directly.
- **"Probes/min" is cadence-derived, not a windowed counter.** Plan didn't specify the source. A true rate counter would need its own time-window state machine; the cadence-derived value is honest about what the orchestrator is currently doing and follows from the `directReprobeInterval(for:)` contract that already exists.
- **Active-count split lives inside the telemetry strip's first chip,** not a separate prominent row. The strip already groups the four flap-related numbers and the split is most legible alongside the related counters.
- **Min-visible slider exposes 0…5 s, even though `HealthSection.vpnFlapMinVisibleSeconds` accepts 0…30.** A min-visible above 5 s would silently swallow user-noticeable flaps without the UI ever flipping to "Reconnecting…" — past 5 s the user is already wondering what's wrong. The model accepts up to 30 as a defensive ceiling for a config-file power-user; the UI exposes only the realistic operator range. Same posture applies to other settings where the model is more permissive than the slider.
- **Settings UI lives in the Network tab's "VPN Flap Resilience" subsection,** not "Health & Diagnostics" or "Advanced." `vpnFlapMinVisibleSeconds` / `vpnFlapGraceSeconds` are first-class user-controlled latency knobs that affect what the user sees in the main window — they belong with the user-facing network controls, not buried in Advanced. Plan said "Health/Network alongside `healthCheckIntervalSeconds`" — the latter is in Advanced; the new sliders are in Network. Both interpretations defensible; chose user-discoverability over textual proximity.
- **Settings sliders ship a hover `.help()` tooltip alongside the visible caption.** Caption explains the feature; tooltip explains the individual knob. Both are additive — the caption catches first-time users, the tooltip serves users who already know the feature exists and just want to recall what each slider does.
- **UI mapping helpers extracted to a `VPNStatusFormatter` enum** rather than left as `private` computed properties on `MainView`. Pure mapping functions deserve unit tests in their own right; the orchestrator transition tests cover the data layer but not the string/color rendering. Extraction also future-proofs the menu-bar popover and floating window paths from drift.
- `**circuitBreakerWindowSeconds`** stays config-file-only as planned.

### Phase 7 review fixes (post-LANDED)

Code-review pass surfaced four issues; all fixed without changing the public surface of any phase:

- **`VPNStatusMonitor` retain/release for SCDynamicStore context.** Original code passed `Unmanaged.passUnretained(self).toOpaque()` while the comment claimed it was retaining for the C callback. Switched to `Unmanaged.passRetained(self)`, stored the opaque pointer in `LifecycleState.contextOpaque` (raw `UnsafeMutableRawPointer` is `Sendable`; `Unmanaged` itself isn't), and added the matching `release()` in `stop()` after `SCDynamicStoreSetDispatchQueue(store, nil)` drains in-flight callbacks. Two race windows hardened along the way: `installStore()` now bails out (and releases) if `stop()` won the race and marked `started=false` between the dispatch and the queue picking up the work; the SCDynamicStore-create-failed branch also releases. Without these: every `start()` permanently leaked one `VPNStatusMonitor` + its `SCDynamicStore` handle.
- **`AppState.performTerminationCleanup` never stopped the Tier B observer.** Added `vpnStatusMonitor.stop()` alongside the existing `networkMonitor.stop()` / `wakeObserver` cleanup. Without this, the kernel-side `SCDynamicStore` notification subscription and any pending grace / min-visible `DispatchWorkItem` timers persisted until process exit — the only "monitor-shaped" resource missing from the explicit teardown sequence.
- **Settings-driven `vpnFlapGraceSeconds` / `vpnFlapMinVisibleSeconds` edits didn't propagate.** `VPNStatusMonitor` stored both as construction-time `let` constants, so a slider change only took effect after a full app restart. Refactored to closure providers (`graceSecondsProvider`, `minVisibleSecondsProvider`), read fresh on every transition that arms a timer — mirrors the `configProvider` closure pattern used by `ConnectionPool` and `LocalProxyServer`. `AppState` wires them to a small `NIOLockedValueBox<VPNFlapWindowConfig>` updated by the existing `$config` Combine sink, so the cross-isolation boundary between MainActor (where the slider writes) and the monitor's `monitorQueue` (where the closures fire) goes through one explicit lock. Tests / pm-sim that don't pass closures get default `{ 5 }` / `{ 1 }` providers — no callsite migration outside `AppState`.
- **`stopProxy` left cumulative flap-telemetry counters from the previous start cycle.** The `mutateSnapshot` in `stopProxy` cleared `openConnections` / `inboundConnections` (instantaneous gauges) but left `vpnFlapCount`, `vpnFlapTotalDuration`, `lastVpnFlapAt`, `streamsPreservedAcrossFlaps` (cumulative counters) untouched, so the `MainView` telemetry strip would reappear on the next `start()` showing inherited counts. Both this design doc's Phase 7 entry ("cumulative counters are reset on stop") and `MainView.showsFlapTelemetryStrip`'s comment ("at which point the cumulative counters have been reset") had already promised the reset. Added explicit zeroing inside the existing `mutateSnapshot` plus an orchestrator-level `flapStartedAt = nil` so a stop mid-flap doesn't compute a duration against a cross-cycle timestamp on the next recovery. New test `VPNTransitionTableTests.testStopProxyResetsFlapTelemetryCounters` locks the contract.

A second pass of review found two additional issues:

- **Race between `VPNStatusMonitor.stop()` and a pending grace / min-visible timer firing.** `stop()` submits the timer-cancel block via `monitorQueue.async` (so cancellation is serialized against any in-flight callback) and then synchronously detaches the SCDynamicStore. Pending work items scheduled via `monitorQueue.asyncAfter(deadline:)` only enter the queue at their fire deadline — if a deadline arrived between the cancel block's enqueue and its actual execution on the serial queue, the timer body would fire first (FIFO order) and emit a state transition (`.disconnected(.networkLost)` or `.reasserting`) to a consumer that has already torn down. Added `guard self.lifecycleBox.withLockedValue({ $0.started }) else { return }` inside both timer work items as the first line after the existing `[weak self]` capture. Mirrors the existing lifecycle guard at the top of `handleStoreChanges`. Picked the started-check approach over `monitorQueue.sync` to avoid any future deadlock if `stop()` is ever called from the monitor queue.
- **`testMetricsUpdateAfterCoalesceInterval` flaked on macos-26 CI.** Started failing immediately after the previous review-fix commit landed, even though neither the test nor `RuntimePresentationAdapter` had been touched in either commit. Root cause: the adapter scheduled its coalesce flush via `Timer.scheduledTimer`, which only fires when the main run loop is pumping in default mode; the test waits via `await Task.sleep(_:)`, which suspends the MainActor task using libdispatch. On Darwin the main run loop usually pumps incidentally as the main dispatch queue drains, but the macos-26 / Xcode 26.2 runner doesn't always honor that — the timer never fires and the values stay at defaults. Switched the adapter from `Timer.scheduledTimer` to `DispatchQueue.main.asyncAfter`, which dispatches directly onto the MainActor's queue and fires reliably across `Task.sleep` suspensions. Same coalesce window (0.15 s), same MainActor reentry via `Task { @MainActor in flushCoalesced() }`, no behavior change — just a scheduler swap that removes the run-loop dependency. 8/8 local re-runs of the previously-flaky test pass cleanly at ~250 ms each.

A third pass — first user report on a real enterprise corporate VPN — found a fundamental detection bug:

- **Phase 3's "watch `/Link.Active`" assumption is wrong on macOS.** The original Phase 3 design (this doc, "Tier B" section) said utun interfaces publish a `State:/Network/Interface/utun*/Link` key with an `Active` boolean. Empirically this is **not true on macOS 26 / Tahoe** (and probably never was) — only physical interfaces (`en*`, `awdl*`, `anpi*`, `bridge0`) carry `/Link`. utun virtual tunnels publish `/IPv4` and `/IPv6` only. Verification: `scutil -- list .*utun.*` against a live Cisco Secure Client tunnel returns zero `/Link` keys. The user impact was severe: VPN was permanently mis-detected as `.unknown` (UI showed "Not detected" for a connected VPN) because `UtunRawObservation.isFullyConnected` required `linkPresent && linkActive && hasIPv4Address` and `linkPresent` was always `false`. Validated against Apple's own developer-forum guidance ([SCDynamicStore IPv4 detection thread, accepted answer by Quinn "The Eskimo!" / Apple DTS](https://developer.apple.com/forums/thread/113446)) which uses exactly the per-interface `/IPv4` pattern we now subscribe to. Fix:
  - Replaced `linkPresent` / `linkActive` fields on `UtunRawObservation` with `ipv6Present` (signal that the kernel has not torn down the interface entirely; needed to disambiguate flap from removal). New definitions: `isFullyConnected = ipv4Present && hasIPv4Address`, `isInterfaceRemoved = !ipv4Present && !ipv6Present`.
  - Dropped `/Link` from the SCDynamicStore subscription patterns (it never fires for utun); added `/IPv6` so the fuser can tell "interface alive but lost IPv4 (flap)" from "interface deleted entirely (user clicked Disconnect)". `Setup:/Network/Service/<UUID>` subscription kept but still unused.
  - `primeInitialState` now reads `/IPv4` and `/IPv6` keys; `handleStoreChanges` re-reads both per affected utun.
  - Added an "apple-service-utun" filter at the top of `handleStoreChanges`: utuns that have never been observed with IPv4 (e.g. Apple's `cloud relay`, FaceTime audio bridge, AWDL) are skipped so they don't pollute the fused state with bogus `.removed` transitions. Once a utun has entered the fuser (because it had IPv4 at least once), all subsequent observations for it are processed regardless — this preserves the flap → grace → recovery state machine. Exposed via the new `VPNStateFuser.knowsAbout(interfaceName:)` method.
  - Trade-off: a user-initiated disconnect that leaves the IPv6 link-local in place (some VPN clients on some macOS versions) now manifests as `.disconnected(.networkLost)` after the grace expires rather than the immediate `.disconnected(.userInitiated)` the original design promised. The distinction is purely cosmetic (UI label); both end at `.disconnected` and trigger the same direct-mode behavior. Cisco Secure Client on macOS 26 deletes both `/IPv4` and `/IPv6` on disconnect, so it still surfaces as `.userInitiated` (verified live).
  - New diagnostic CLI: `pm-vpn-check`. Standalone tool that wires up only `VPNStatusMonitor` (no proxy, no Keychain, no auth, no system-proxy mutation — same constraints as `pm-proxy`) and prints every state transition. Built explicitly so users can validate VPN detection without running the full app, and so future "wait, why does the UI show X?" reports come with reproducible logs. Used to verify the fix end-to-end: with a Cisco corp VPN up, `pm-vpn-check --duration 60` showed `connected → reasserting (after 0.5 s minVisible) → disconnected(userInitiated) (after another 1 s, when /IPv6 was also removed) → connected` as the user toggled the VPN client.
  - Test updates: `UtunRawObservation`'s field set changed (compile error in any direct construction). `VPNStateFuserTests.swift` rewrote every fixture and test to use the new IPv4/IPv6 model; added 2 new tests covering `knowsAbout(interfaceName:)`. `VPNFlapScenarios.swift`'s rapid-flap pm-sim scenario also updated. Two test fixtures were renamed (`testFirstSightOfLinkDownInterfaceDoesNotEmitReasserting` → `testFirstSightOfIPv4LessUtunDoesNotEmit`, `testLinkDropAfterConnectedRequestsMinVisibleTimer` → `testIPv4DropAfterConnectedRequestsMinVisibleTimer`) to reflect the actual signal we now exercise.

Test count went from 721 → 724; full suite green (722 + 2 new `knowsAbout` tests, with the 2-test rename net-zero on count). The three pm-sim flap scenarios (`vpn-flap-long-outage`, `vpn-rapid-flap-burst`, `vpn-user-disconnect`) still PASS.

## Backward Compatibility

The proxy has a single user (the project author). There are no external NDJSON consumers. Snapshots are runtime-only — never persisted to disk. So "back-compat" here means "in-process callers compile cleanly," not "old wire payloads must decode."

Policy: do not carry deprecated fields on the hot path. If an external consumer ever shows up, introduce schema versioning + one-time migration. Until then, the type definition is the schema.

Concrete consequences:

- `ProxyOrchestratorSnapshot.directMode: Bool` was added in Phase 2 then removed in the same phase's cleanup commit. The single source of truth is `directModeCause: DirectModeCause`; consumers needing a Bool use `directModeCause.isDirect`. `RuntimePresentationAdapter.directMode` is a computed property derived from the cause, not a stored `@Published`.
- `ProxyOrchestratorSnapshot.vpnConnected: Bool` will be replaced by `vpnState: VPNObservedState` in Phase 3 (same pattern: drop the field, derive when needed).
- `ProxyConfig` keys removed (`autoDisableOffVPN`, `autoEnableOnVPN`): silently dropped on read; no decode failure. One-time `.notice` log if either was `true` so the migration is visible.
- `directModeProvider` closure signature change: internal API; no external surface affected.
- New `vpnFlapGraceSeconds` defaults to 5 s if absent (config decoder uses `decodeIfPresent ?? 5` for in-flight config-file reads only — config IS persisted).
- New event category `vpn`: event-stream consumers (us, `pm-sim`) tolerate unknown categories.

## Architecture Notes

### Module placement (interim)

All new files land in `Sources/ConduitCore/Network/` alongside `NetworkMonitor.swift` until the module split (`roadmap-v2.md §2.2`) separates Core. Files using `SystemConfiguration` carry a header comment:

```
// NOTE: module split — relocate to PlatformMac. Imports SystemConfiguration which
// is forbidden in ProxyKernel per the import fence (AGENTS.md).
```

### Import fence compliance

`VPNStatusMonitor.swift` is the only new file that imports `SystemConfiguration`. Other new files (`VPNObservedState.swift`, `VPNStatusObserving.swift`, `DirectModeCause.swift`) import only `Foundation`. The fuser uses `Dispatch` only.

### Side-effects-behind-protocols compliance

`VPNStatusObserving` protocol satisfies the AGENTS.md "always route side effects behind a protocol" rule. `pm-sim` injects `FakeVPNStatusObserver`, never touches the kernel.

## Open Items (Deferred)

Not required for v1 ship; revisit if signal warrants:

- **Tier A activation** for enterprise customers who provision a `.mobileconfig` with our `VPNSubType`. API surface (`VPNStatusObserving`) is stable enough to add without breaking changes.
- **Per-utun-interface emission** for split-tunnel / dual-stack VPN configurations. Internal state already tracks per-utun; only the public emission collapses.
- **Per-connection state badge** in the connections list (`flowing` / `stalled` / `flapped-recovered`). Telemetry strip is the v1 stand-in.
- `**vpn.flap.recovered` notification** ("3 streams survived a VPN flap"). Stays in metrics only for v1.
- `**circuitBreakerWindowSeconds` UI exposure**. Config-file only for v1.

## References

- `Sources/ConduitCore/Proxy/ProxyOrchestrator.swift` — current direct-mode logic (lines 244, 282, 407–431, 718–740, 786–857, 870, 877–907, 909–947, 949–952)
- `Sources/ConduitCore/Proxy/HTTPProxyHandler.swift` — direct connect/HTTP paths (lines 83, 152–219, 244–316, 318–350)
- `Sources/ConduitCore/Proxy/SOCKS5Server.swift` — SOCKS5 direct path (lines 230–267)
- `Sources/ConduitCore/Proxy/ConnectionPool.swift` — pool, circuit breaker, prewarm (lines 70–100, 212–237, 312–319, 588–608)
- `Sources/ConduitCore/Network/AutoRecovery.swift` — recovery cascade (lines 41–67)
- `Sources/ConduitCore/Network/NetworkMonitor.swift` — current Tier C
- `Sources/ConduitCore/Support/TCPKeepalive.swift` — keepalive defaults
- `Sources/Conduit/App/AppState.swift` — `handleNetworkChange`, `autoDisableOffVPN`, `autoEnableOnVPN` (lines 89–93, 554–569)
- `roadmap-v2.md §2.2` — module split
- `docs/STYLE.md` — engineering discipline (bounded everything, structured events first, side-effects behind protocols)
- `[NEVPNStatus` (Apple)](https://developer.apple.com/documentation/networkextension/nevpnstatus) — validates "macOS doesn't close TCP on VPN transitions"
- `[NETunnelProviderManager` (Apple)](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager) — `VPNSubType` association, why Tier A is rejected for v1

