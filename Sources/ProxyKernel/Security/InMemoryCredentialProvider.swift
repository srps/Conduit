// SPDX-License-Identifier: Apache-2.0
// Kernel-side `CredentialProvider` for headless daemons (`pm-proxy`,
// `pm-tunnel`) that must not link `PlatformMac` (no Keychain) but still
// need to plug into `credentialBasedAuthenticatorProvider`. This is
// a real per-upstream dictionary store backed by
// `NIOLockedValueBox` (concurrency-safe across NIO event loops).
//
// Default-constructed `InMemoryCredentialProvider()` returns `nil` for
// every `credentials(for:)` lookup — gives the "no creds, fall
// back to Kerberos" behaviour. Callers that want to seed credentials
// (future `pm-proxy --credentials-file` flag, scenario-driven sim wiring)
// either construct with a populated dict or call `setCredentials(_:for:)`.

import Foundation
import NIOConcurrencyHelpers

package final class InMemoryCredentialProvider: CredentialProvider, @unchecked Sendable {
    private let store: NIOLockedValueBox<[UpstreamProxy: ProxyCredentials]>

    /// Construct with an optional initial credential map. Common callers
    /// pass nothing (empty store, nil for every lookup); test wiring may
    /// pre-populate per-upstream entries.
    package init(initialCredentials: [UpstreamProxy: ProxyCredentials] = [:]) {
        self.store = NIOLockedValueBox(initialCredentials)
    }

    package func credentials(for upstream: UpstreamProxy) throws -> ProxyCredentials? {
        store.withLockedValue { $0[upstream] }
    }

    package func setCredentials(_ credentials: ProxyCredentials, for upstream: UpstreamProxy) throws {
        store.withLockedValue { $0[upstream] = credentials }
    }
}
