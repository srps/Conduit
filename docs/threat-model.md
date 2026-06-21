# Conduit Threat Model

Status: baseline for the security-hardening work. Update this file whenever auth, credential storage, PAC evaluation, helper privileges, gateway mode, or tunnel routing changes.

## Scope

Conduit is a local macOS proxy runtime with privileged system-integration helpers. The primary assets are upstream credentials, Kerberos/NTLM tokens, routing decisions, system proxy/DNS state, local listener availability, and the integrity of CONNECT/SNI target mapping.

Trusted boundaries:

- `ProxyKernel` is side-effect-free and owns routing, DNS forwarding, tunnels, and structured events.
- `ProxyAuth` owns NTLM/Kerberos token generation.
- `ProxyPAC` owns CFNetwork PAC evaluation.
- `PlatformMac` owns Keychain, `networksetup`, helper IPC, login items, notifications, and `/etc/resolver`.
- `ConduitHelper` is privileged and accepts only versioned, validated IPC commands.

## Threats

### Malicious PAC

Asset: routing integrity and process availability.

Boundary: PAC text is remote input. It enters through `CFPACEvaluator` and is consumed by `PACRoutingEngine`.

Existing controls: PAC execution uses macOS CFNetwork rather than JavaScriptCore; PAC routing has evaluation timeout behavior, route cache bounds, and a local PAC serving layer that keeps browsers pointed at a stable loopback PAC.

Current gaps: PAC source authenticity is still inherited from the configured URL and the corporate network. Audit logging of PAC decisions is planned but not shipped.

Planned work: connection audit log, upstream certificate pinning, and `pm-sim pac-fallback`.

### MITM On Upstream Proxy

Asset: target routing, proxy authentication exchange, and user trust in upstream identity.

Boundary: the local runtime connects to configured corporate upstream proxies on the network.

Existing controls: upstream host/port values are validated through `ProxyConfig`; metadata endpoints are blocked across direct and proxied paths; auth headers are now redacted before logs/events.

Current gaps: upstream certificate pinning is not implemented, and most corporate proxy connections are explicit proxy TCP connections rather than a pinned TLS channel.

Planned work: per-upstream SPKI hash config with mismatch refusal and structured event.

### Keychain Credential Theft

Asset: saved NTLM credential material.

Boundary: `PlatformMac.CredentialManager` and `KeychainStore` are the only Keychain-backed credential providers; headless tools use `InMemoryCredentialProvider`.

Existing controls: plaintext passwords are not persisted; stored NT hash travels through `SecretBytes`; credentials cross module boundaries as `ProxyCredentials`, not arbitrary dictionaries or JSON; `pm-proxy` does not link `PlatformMac`.

Current gaps: Keychain ACL tightening and signed caller restrictions are not complete. The current helper installation model is LaunchDaemon-based rather than `SMAppService` signed-helper distribution.

Planned work: Keychain accessibility/caller audit as part of the security-hardening work, and Data Protection Keychain after Developer ID signing.

### In-Memory Token Snooping

Asset: Kerberos, NTLM, bearer, and proxy authorization tokens while live in process memory.

Boundary: token strings exist briefly in auth handlers and HTTP headers; logs/events are the durable exfiltration risk.

Existing controls: credential hashes use `SecretBytes` with redacted description and zero-on-deinit; `LogSink` and `RuntimeEvent` detail sanitization masks auth/cookie headers, bearer tokens, and long base64-like tokens.

Current gaps: Swift `String` remains unavoidable for one-shot HTTP header values and SwiftUI secure-field input.

Planned work: connection audit log with masked fields only; continue shrinking token lifetime at auth boundaries.

### Local Proxy Port Hijack

Asset: localhost listener availability and system proxy correctness.

Boundary: clients connect to local HTTP/SOCKS/DNS/PAC listeners; system proxy settings point clients at those listeners.

Existing controls: listeners bind loopback by default; gateway mode is explicit; port validation occurs before helper/relay casts; `ready.json` and snapshots expose actual bound ports; port retry and restart paths recover quick restarts.

Current gaps: daemon-first LaunchAgent ownership and socket/control-plane lifecycle are not shipped yet, so the GUI still owns runtime lifetime in app mode.

Planned work: the LaunchAgent daemon, control socket, atomic snapshot file, watchdog restart, and graceful upgrade.

### Helper Privilege Escalation

Asset: privileged system proxy, DNS, resolver, and relay operations.

Boundary: app-to-helper Unix socket / IPC contract.

Existing controls: helper commands are versioned and validated in `ConduitShared`; socket permissions and peer validation restrict access; port values are validated before relay startup; legacy unversioned requests are rejected.

Current gaps: every `PrivilegeClient` call does not yet emit a dedicated `auth.privilege_request` event.

Planned work: privileged-action audit trail and eventual `SMAppService` signed helper.

### IPv6 Family Confusion

Asset: metadata blocklist correctness and no-proxy/CONNECT target validation.

Boundary: client-supplied hostnames/IP literals and resolved addresses.

Existing controls: IPv6 metadata blocking is canonicalized; SOCKS5 supports ATYP 4; host/port parsing uses structured URL and socket address helpers where available.

Current gaps: ongoing coverage should include mixed IPv4-in-IPv6, zero-compression, and case variants whenever routing code changes.

Planned work: keep metadata and SNI property tests in the security gate.

### SNI And CONNECT Host Mismatch

Asset: target integrity for transparent proxying and TLS certificate validation by the client.

Boundary: transparent TCP proxy peeks TLS ClientHello SNI while preserving end-to-end TLS.

Existing controls: `SNIParser` validates per-label hostnames, rejects malformed handshakes, and never terminates TLS. Transparent proxy preserves the real hostname for CONNECT rather than requiring clients to use `localhost`.

Current gaps: random-garbage false-positive coverage was missing before the security-hardening work.

Planned work: deterministic SNI fuzz/property tests and continued pm-sim coverage for transparent proxy paths.
