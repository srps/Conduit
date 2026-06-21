// SPDX-License-Identifier: Apache-2.0
// Kernel-side credential-source seam. Decouples `AuthenticatorFactory` (in
// `ProxyAuth`) from concrete credential storage — `CredentialManager`
// (Keychain-backed, `PlatformMac`) and `InMemoryCredentialProvider`
// (kernel-side, used by headless daemons + tests) both conform.
//
// Widened from an earlier narrow shape:
//   - `credentials(for:)` now takes `UpstreamProxy` (not `ProxyConfig`) so
//     different upstreams can carry different credentials. Returns
//     `Optional` instead of throwing on the not-found case — that's the
//     common-path "no creds, fall back to Kerberos" branch and shouldn't
//     bleed try/catch overhead. Throws only on actual storage failures
//     (Keychain ACL denial, decode failure, etc.).
//   - `setCredentials(_:for:)` is the new write surface. Today's only
//     caller is `AppState.savePassword(_:)` which goes through the concrete
//     `CredentialManager.saveHash(_:for:)`; the protocol setter exists for
//     future control-plane reload paths and for in-memory test/sim wiring.
//
// The protocol is **storage-agnostic**: the `UpstreamProxy` parameter is a
// `Hashable` value type; conformers pick their own key shape. Conformers
// that don't yet support per-upstream keying may ignore the parameter and
// return the same credential for every upstream — that's the current
// shipped behaviour of `CredentialManager` (see below).
//
// Per-conformer key shapes today:
// - `CredentialManager` (PlatformMac) ignores the `UpstreamProxy`
//   parameter and keys the Keychain entry on
//   `"\(domain)|\(username)|\(profileName)"`. This gives
//   one credential per profile, shared across all upstreams
//   in that profile. Per-upstream credential UX is future work (when
//   it lands, the key shape evolves to include `host:port` and a
//   one-time lazy migration handles the transition).
// - `InMemoryCredentialProvider` (kernel) uses `UpstreamProxy` as the
//   dictionary key directly, so it's already per-upstream-ready.

import Foundation

package protocol CredentialProvider: Sendable {
    /// Return saved credentials for `upstream`. Returns `nil` (not throws)
    /// when none exist — that's the common case during Kerberos-only
    /// handshakes where the caller falls back without ceremony. Throws
    /// only for actual storage failures (Keychain ACL denial, decode
    /// failure, etc.).
    func credentials(for upstream: UpstreamProxy) throws -> ProxyCredentials?

    /// Persist `credentials` for `upstream`. Idempotent overwrite.
    func setCredentials(_ credentials: ProxyCredentials, for upstream: UpstreamProxy) throws
}
