// SPDX-License-Identifier: Apache-2.0
// Kernel-side credential value type + error. Extracted from
// `CredentialManager.swift` so `ProxyAuth` (`NTLMAuth` constructs
// `ProxyCredentials`) and kernel-side `CredentialProvider` +
// `InMemoryCredentialProvider` can reference the type without pulling in
// `PlatformMac`. The Keychain-backed `CredentialManager` lives in PlatformMac
// and imports this file via `import ProxyKernel`.
//
// The `ntHash` field is `SecretBytes` rather than
// the raw `Data` used previously. Opaque, zero-on-release, does
// not conform to Codable — accidental log / Mirror / JSON leak paths
// compile-error or redact structurally. See
// `Sources/ProxyKernel/Security/SecretBytes.swift` for the type + the
// protections it provides (and the ones it explicitly does not).
//
// Keychain round-trip: `keychainData()` now returns `SecretBytes` (the
// JSON envelope wrapped opaquely). The intermediate `Data` the JSON
// encoder produces is short-lived and scoped to this method — it's
// wrapped in SecretBytes on the way out. The matching
// `init(keychainPayload:)` decodes the envelope into a fresh
// `SecretBytes` for `ntHash`.
//
// The internal `KeychainPayload` keeps `ntHash: Data` because JSONEncoder
// / JSONDecoder need Codable concretes; the Data value inside the
// payload is materialised only during encode/decode and is zeroed by the
// garbage collector (not deterministically — but briefly). For the
// at-rest secret, Keychain's own encryption is the primary defense; the
// SecretBytes wrap is in-process defense-in-depth.

import Foundation

package struct ProxyCredentials: Equatable {
    package var username: String
    package var domain: String
    package var workstation: String
    package var ntHash: SecretBytes

    package init(username: String, domain: String, workstation: String, ntHash: SecretBytes) {
        self.username = username
        self.domain = domain
        self.workstation = workstation
        self.ntHash = ntHash
    }

    /// Serialise into the opaque Keychain envelope. Output is
    /// `SecretBytes` because the JSON envelope contains the ntHash (as
    /// base64 inside the JSON string). Passed directly to
    /// `KeychainStore.save(secret:account:)` which extracts the bytes
    /// via `withUnsafeBytes` for the Security-framework call.
    package func keychainData() throws -> SecretBytes {
        let payload = try ntHash.withUnsafeBytes { buf in
            try JSONEncoder().encode(KeychainPayload(
                username: username,
                domain: domain,
                workstation: workstation,
                ntHash: Data(buf)
            ))
        }
        return SecretBytes(payload)
    }

    /// Decode from the opaque Keychain envelope. Used by the Keychain-
    /// loaded path (`CredentialManager.loadCredentials` /
    /// `.credentials(for:)`). Renamed from `init(keychainData:)` to
    /// signal the parameter's SecretBytes nature.
    package init(keychainPayload envelope: SecretBytes) throws {
        let payload: KeychainPayload = try envelope.withUnsafeBytes { buf in
            try JSONDecoder().decode(KeychainPayload.self, from: Data(buf))
        }
        self.username = payload.username
        self.domain = payload.domain
        self.workstation = payload.workstation
        self.ntHash = SecretBytes(payload.ntHash)
    }

    /// Codable JSON payload shape. Kept `ntHash: Data` because Codable
    /// JSON encoding / decoding requires concrete types — we cannot make
    /// SecretBytes conform to Codable without defeating its purpose.
    /// The Data here is the intermediate form that only exists inside
    /// `keychainData()` / `init(keychainPayload:)`; both methods take
    /// care to re-wrap in SecretBytes at the egress so the raw Data
    /// never outlives the JSON step.
    private struct KeychainPayload: Codable {
        var username: String
        var domain: String
        var workstation: String
        var ntHash: Data
    }
}

package enum CredentialManagerError: Error, LocalizedError {
    case missingCredentials
    case invalidPayload

    package var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No saved proxy credentials were found."
        case .invalidPayload:
            return "Saved proxy credentials are invalid."
        }
    }
}
