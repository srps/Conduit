# Daemon-First Runtime and Control Plane

Status: design prepared for the daemon-first control-plane implementation.

## Problem

Conduit currently embeds the real proxy runtime in the SwiftUI app process. The installed `ConduitHelper` survives UI exit, but it is only a privileged side-effect helper: `networksetup`, DNS resolver writes, and low-port TCP/UDP relays. It does not host `ProxyOrchestrator`, `LocalProxyServer`, local PAC, DNS forwarding, SOCKS5, transparent proxy, or tunnels.

That means an AppKit automatic-termination event, ControlCenter workspace invalidation, force-quit, app update, or UI crash tears down the actual proxy listeners. This violates the daemon-first product pillar: traffic must continue when the UI is gone.

## Goals

- The runtime runs as a user-session LaunchAgent and does not require a visible UI.
- The SwiftUI app, menu bar, and `pmctl` are clients of one control plane.
- The privileged helper remains narrow and privileged-only.
- `pm-proxy` remains side-effect-free for CI, simulators, and isolated reproductions.
- UI force-quit does not disrupt HTTP, SOCKS5, DNS, local PAC, transparent proxy, or tunnel traffic.

## Non-Goals

- Do not convert `ConduitHelper` into the full proxy daemon. It is root-owned and should not own user Keychain, Kerberos, CFNetwork PAC, or UI-session network state.
- Do not make `pm-proxy` apply system proxy settings, write `/etc/resolver`, touch login items, or call the helper. Its side-effect-free contract is what makes it safe in CI and for agents.
- Do not create a broad `PlatformIntegration` god protocol before the daemon has concrete call sites. Introduce narrow coordinators around actual ownership.
- Do not require the UI to be running for recovery, reload, or system-proxy repair.

## Current Ownership

```text
Conduit.app
  AppState
    ProxyOrchestrator
      LocalProxyServer
      LocalPACServer
      LocalDNSForwarder
      TransparentTCPProxy
      TunnelForwarder
      ConnectionPool / health / recovery / PAC routing
    PlatformMac managers
      SystemProxyManager
      EnvironmentManager
      DNSManager / SystemDNSManager
      NetworkMonitor / VPNStatusMonitor
      LoginItemManager

ConduitHelper
  privileged socket daemon
  networksetup / resolver / relay commands only
```

## Target Ownership

```text
ConduitDaemon (user LaunchAgent)
  DaemonRuntimeHost
    ProxyOrchestrator
    Platform side-effect coordinators
    ControlSocketServer
    EventFileWriter / SnapshotFileWriter
    LaunchAgent repair and crash-restart evidence

Conduit.app
  DaemonClient
    status / events / start / stop / reload / profile / diag
  SwiftUI views only mirror daemon state

pmctl
  DaemonClient over the same control socket

ConduitHelper
  privileged helper only

pm-proxy
  isolated side-effect-free runtime for tests and CI
```

## New Target

Add a production executable target:

```swift
.executableTarget(
    name: "ConduitDaemon",
    dependencies: [
        "ProxyKernel",
        "ProxyControlBridge",
        "ProxyAuth",
        "ProxyPAC",
        "PlatformMac",
        "ConduitShared",
    ],
    path: "Sources/ConduitDaemon"
)
```

The daemon is a user LaunchAgent. It may link `PlatformMac` because it owns user-session side effects. It must not run as root.

## Control Plane

The control socket is a Unix-domain socket at:

```text
$state-dir/control.sock
```

The shared DTOs live in `ConduitShared/ControlProtocol.swift`. They already cover the first cut of `status`, `reload`, `stop`, `events`, `diag`, and `test-upstream`; this work extends them rather than inventing another wire contract.

Required daemon commands:

- `status`: return the latest `ControlDaemonStatus`.
- `start`: start runtime and apply configured platform side effects.
- `stop`: stop runtime and clear configured platform side effects.
- `reload`: reload persisted config and apply `ConfigDiff` by subsystem.
- `set-profile <name>`: switch active profile, persist, reload.
- `test-upstream <name>`: run a bounded reachability/auth probe.
- `events --follow`: stream typed events.
- `diag`: return paths or bundle metadata for sanitized diagnostics.
- `kill-upstream <name> <ms>`: dev-build-only fault injection.

Protocol rules:

- Every request carries `protocolVersion`.
- Request frames are newline-delimited JSON with a fixed max size.
- Unknown versions fail closed with a structured error.
- Errors use stable codes plus human-readable messages.
- Event/detail fields are sanitized before crossing the socket or file boundary.

## Persistent Observability

The daemon writes two files in the state directory:

- `events.ndjson`: capped rolling event stream derived from `RuntimeEvent`, not log text.
- `snapshot.json`: atomic latest snapshot via temp-write + rename.

These files let `pmctl diag` work even when the control socket is unavailable.

## Platform Side Effects

The daemon owns runtime-adjacent side effects:

- macOS system proxy and local PAC URL.
- environment file export.
- DNS resolver management.
- system DNS management.
- tunnel resolver files.
- privileged TCP/UDP relay start/stop through `ConduitHelper`.
- launch-at-login reconciliation where applicable.

The UI must request these over the control plane. Direct `AppState` calls into `SystemProxyManager`, `DNSManager`, `EnvironmentManager`, and `LoginItemManager` become migration debt until removed.

## Credential and Auth Model

The daemon runs as the logged-in user, so it can use:

- login Keychain / future Data Protection Keychain.
- Kerberos ticket cache.
- CFNetwork PAC evaluation in the user session.
- `SCDynamicStore` and user network state.

The privileged helper never receives credentials and never performs auth.

## Migration Sequence

### Step 1: Lock the Contract

- Update `ControlProtocol` with missing commands and stable errors.
- Add shared `DaemonClient` socket code usable by both `Conduit` and `pmctl`.
- Add control-protocol unit tests for version mismatch, unknown command, frame limit, and redaction.

### Step 2: Add `ConduitDaemon`

- Add the executable target and a minimal main.
- Load `RuntimeEnvironment`, config, platform config, preferences, PAC evaluator, credential provider, and authenticator provider.
- Start no listeners by default until commanded or configured.
- Emit `daemon.ready` event and write initial `snapshot.json`.

### Step 3: Move Runtime Host Out of `AppState`

- Extract a daemon-side runtime host that owns `ProxyOrchestrator` and the platform coordinators.
- Keep `pm-proxy` on its current isolated entry point.
- Keep `AppState` temporarily able to run in-process only behind a dev fallback.

### Step 4: Serve the Control Socket

- Add daemon-side `ControlSocketServer`.
- Implement `status`, `start`, `stop`, `reload`, and `events`.
- Point `pmctl status/reload/stop/events` at the live daemon.

### Step 5: LaunchAgent Lifecycle

- Add `io.github.srps.Conduit.daemon.plist`.
- Add install/uninstall/upgrade scripts or app actions.
- Use `launchctl bootstrap/bootout` in the user domain.
- Add stale socket cleanup and state-dir ownership repair.
- Configure `KeepAlive { SuccessfulExit = false }`.

### Step 6: App Becomes Client

- Replace direct `AppState.startProxy()` / `stopProxy()` orchestration with `DaemonClient`.
- Subscribe to daemon snapshots/events and feed `RuntimePresentationAdapter`.
- Move settings save/reload through daemon commands.
- Keep dev-only in-process fallback until the daemon path is stable.

### Step 7: Targeted Reload and Side-Effect Reconciliation

- Use `ConfigDiff` to reload auth, routing, DNS, tunnels, health, logging, and platform side effects independently.
- Preserve active HTTP, CONNECT, SOCKS5, DNS, and tunnel sessions across unrelated config changes.
- Daemon repairs system proxy/PAC/DNS if drift is detected.

### Step 8: Delete or Hide In-Process Fallback

- Before 1.0, remove production access to UI-owned runtime.
- The GUI becomes a controller; the daemon is the product runtime.

## Acceptance Tests

- Force-quit `Conduit.app`; existing HTTP, SOCKS5, DNS, local PAC, transparent proxy, and tunnel traffic continue.
- Launch the app after daemon is already running; UI reflects daemon status within 5 seconds.
- Run `pmctl status` against the daemon and compare to `snapshot.json`.
- Run `pmctl events --follow`; trigger routing/auth/failover events and observe redacted event frames.
- Kill the daemon with `SIGKILL`; LaunchAgent restarts it and next start emits `lifecycle.crash_restart`.
- Reload DNS-only config; HTTP and tunnel sessions survive.
- Reinstall/upgrade the app bundle; daemon either survives or restarts with stale state repaired.
- `pm-proxy --state-dir /tmp/pm-test --port 0 --dns-port 0 --status-interval 2` remains side-effect-free.

## First Implementation Step

Keep the first coding change small:

1. Extend `ControlProtocol` with missing commands and error codes.
2. Extract a shared `DaemonClient` socket helper.
3. Add the empty `ConduitDaemon` target with `status` returning a loaded-but-stopped snapshot.
4. Add tests for the protocol and socket framing.

Do not move `AppState` ownership in the first step. The first step should make the daemon addressable; the next step can move runtime ownership.
