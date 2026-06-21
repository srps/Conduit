// SPDX-License-Identifier: Apache-2.0
// Keychain-backed `CredentialProvider` conformer. Value types
// (`ProxyCredentials`, `CredentialManagerError`) live in
// `Sources/ProxyKernel/Security/ProxyCredentials.swift`
// so `ProxyAuth` + headless daemons can reference them without linking
// `PlatformMac`. This file carries only the Keychain-backed concrete.
//
// The protocol is keyed `credentials(for: UpstreamProxy)`. The UI stays
// profile-keyed (per-upstream credential UX is future work), so this
// implementation:
//
//   1. Ignores the `UpstreamProxy` parameter on the protocol methods —
//      every upstream returns the same profile-level credential. AppState
//      saves once per profile and every upstream auth handshake uses that
//      single credential.
//   2. Keeps the existing Keychain key shape `"\(domain)|\(username)|\(profileName)"`
//      unchanged — no migration needed because the storage shape didn't
//      change. When the per-upstream UX lands, the key shape evolves
//      to include `host:port` and a one-time lazy migration handles the
//      transition then.
//   3. Takes an `identityProvider` closure at construction so the
//      protocol-required methods can reach the active profile's identity
//      without taking config as a method parameter (which the protocol
//      doesn't allow). AppState wires it from the orchestrator's config
//      snapshot provider; tests can pass a fixed identity.
//
// The richer per-config API (`saveHash`, `clear`, `hasSavedCredentials`)
// stays as the AppState-facing surface — it predates the protocol and
// remains the right shape for the profile-level UX.

import Foundation
import ProxyKernel

package final class CredentialManager: CredentialProvider, @unchecked Sendable {
    /// `(domain, username, profileName)` triple. The protocol-required
    /// methods (`credentials(for:)`, `setCredentials(_:for:)`) call this
    /// to derive the Keychain account key without taking `ProxyConfig` as
    /// a parameter (which the protocol doesn't allow).
    package typealias Identity = (domain: String, username: String, profileName: String)

    private let keychain = KeychainStore()
    private let identityProvider: @Sendable () -> Identity

    /// Construct with an `identityProvider` closure. AppState wires this
    /// from the orchestrator's `configSnapshotProvider`; tests
    /// pass a fixed-identity closure.
    package init(identityProvider: @escaping @Sendable () -> Identity) {
        self.identityProvider = identityProvider
    }

    // MARK: - CredentialProvider conformance

    /// Profile-level lookup. The `UpstreamProxy` parameter is ignored —
    /// every upstream returns the same credential under the active
    /// profile's identity. See file header for rationale.
    package func credentials(for _: UpstreamProxy) throws -> ProxyCredentials? {
        let identity = identityProvider()
        guard let envelope = try keychain.load(account: accountKey(for: identity)) else {
            return nil
        }
        guard let credentials = try? ProxyCredentials(keychainPayload: envelope) else {
            throw CredentialManagerError.invalidPayload
        }
        return credentials
    }

    /// Profile-level write. Same `UpstreamProxy`-ignored shape as the read.
    package func setCredentials(_ credentials: ProxyCredentials, for _: UpstreamProxy) throws {
        let identity = identityProvider()
        let envelope = try credentials.keychainData()
        try keychain.save(secret: envelope, account: accountKey(for: identity))
    }

    // MARK: - Per-config AppState API (richer than the protocol)

    /// The hash is `SecretBytes` from the moment
    /// `NTLMAuth.ntHash(for:)` produces it at the AppState boundary.
    /// The envelope this method produces and sends to Keychain is also
    /// `SecretBytes` — defense-in-depth on the in-process lifetime of
    /// the serialised credential blob.
    package func saveHash(_ hash: SecretBytes, for config: ProxyConfig) throws {
        let credentials = ProxyCredentials(
            username: config.username,
            domain: config.domain,
            workstation: config.workstation,
            ntHash: hash
        )
        let envelope = try credentials.keychainData()
        try keychain.save(secret: envelope, account: accountKey(for: config))
    }

    package func loadCredentials(for config: ProxyConfig) throws -> ProxyCredentials {
        guard let envelope = try keychain.load(account: accountKey(for: config)) else {
            throw CredentialManagerError.missingCredentials
        }
        guard let credentials = try? ProxyCredentials(keychainPayload: envelope) else {
            throw CredentialManagerError.invalidPayload
        }
        return credentials
    }

    package func hasSavedCredentials(for config: ProxyConfig) -> Bool {
        (try? keychain.exists(account: accountKey(for: config))) ?? false
    }

    package func clear(for config: ProxyConfig) throws {
        try keychain.delete(account: accountKey(for: config))
    }

    // MARK: - Key derivation

    private func accountKey(for config: ProxyConfig) -> String {
        "\(config.domain)|\(config.username)|\(config.profileName)"
    }

    private func accountKey(for identity: Identity) -> String {
        "\(identity.domain)|\(identity.username)|\(identity.profileName)"
    }
}
