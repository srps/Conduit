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
//   4. Caches the last read, keyed by account, as `SecretBytes`-backed
//      `ProxyCredentials` (#98). Each NTLM fallback used to read the
//      Keychain, 1,248 reads on one day; now a save, a clear, a proxy start
//      (`warmCache`) or a rejecting 407 invalidates, an identity change
//      misses, and concurrent callers share one read. Capacity one entry.
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

    private let keychain: any SecretStore
    private let identityProvider: @Sendable () -> Identity
    private let failureRetryInterval: TimeInterval
    private let rejectionInterval: TimeInterval
    private let pendingReadWait: TimeInterval
    private let now: @Sendable () -> Date

    /// The last read of the store, for one account key: at most one entry,
    /// replaced when the identity changes.
    private struct CacheEntry {
        let account: String
        let result: Result<ProxyCredentials?, any Error>
        let at: Date
    }

    private let cacheCondition = NSCondition()
    /// Where the store is read, and where `warmCache` waits for it. Private
    /// serial queues get a thread of their own, where a global queue's work
    /// can wait for one: on a busy machine a `.utility` global block did
    /// not start for seconds, so handshakes gave up with `read_pending`
    /// though no prompt was up. `.userInitiated` because a handshake is
    /// waiting on the answer.
    private let readQueue = DispatchQueue(label: "io.github.srps.Conduit.credential-read", qos: .userInitiated)
    private let warmQueue = DispatchQueue(label: "io.github.srps.Conduit.credential-warm", qos: .userInitiated)
    private var cacheEntry: CacheEntry?
    /// The account of the one store read that is out, if any. Never more
    /// than one: callers that need the store meanwhile wait for it instead
    /// of each asking the Keychain (and each raising its access prompt).
    private var readInFlight: String?
    /// Bumped by every invalidation, so a read that started before one does
    /// not store its now-stale answer.
    private var cacheGeneration = 0
    private var lastRejectionDrop: Date?

    /// Construct with an `identityProvider` closure. AppState wires this
    /// from the orchestrator's `configSnapshotProvider`; tests
    /// pass a fixed-identity closure.
    ///
    /// A failed read is held for `failureRetryInterval` before the store is
    /// asked again, except a refusal or a corrupt entry, which only the user
    /// can fix and which is held until the next save, clear or proxy start.
    /// A 407 that rejects the credentials drops them at most once per
    /// `rejectionInterval`, so a wrong password does not become a Keychain
    /// read per request. A handshake waits at most `pendingReadWait` for a
    /// read that is out; see `credentials(for:)`.
    package init(
        identityProvider: @escaping @Sendable () -> Identity,
        store: any SecretStore = KeychainStore(),
        failureRetryInterval: TimeInterval = 60,
        rejectionInterval: TimeInterval = 60,
        pendingReadWait: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identityProvider = identityProvider
        self.keychain = store
        self.failureRetryInterval = failureRetryInterval
        self.rejectionInterval = rejectionInterval
        self.pendingReadWait = pendingReadWait
        self.now = now
    }

    // MARK: - CredentialProvider conformance

    /// Profile-level lookup. The `UpstreamProxy` parameter is ignored —
    /// every upstream returns the same credential under the active
    /// profile's identity. See file header for rationale.
    ///
    /// Answered from the cache; the store is read once per invalidation.
    /// The read itself runs on `readQueue`, never on the caller's
    /// thread: callers are handshakes on the cooperative pool, and a read
    /// can sit on a Keychain access prompt for as long as the user leaves
    /// it (expected after every update). A caller waits for the read at
    /// most `pendingReadWait`, then throws `CredentialReadPending`
    /// (`read_pending`) and its handshake goes without NTLM; the read
    /// carries on and serves the handshakes after it.
    package func credentials(for _: UpstreamProxy) throws -> ProxyCredentials? {
        try cachedCredentials(account: accountKey(for: identityProvider()), waitLimit: pendingReadWait)
    }

    /// Drops credentials the upstream answered with a final 407, so a
    /// password changed in another process is picked up. At most once per
    /// `rejectionInterval`. Never reads the store, so it is safe on an
    /// event loop.
    package func dropRejectedCredentials(for _: UpstreamProxy) -> Bool {
        cacheCondition.lock()
        defer { cacheCondition.unlock() }
        guard case .success(.some)? = cacheEntry?.result else { return false }
        let current = now()
        if let lastRejectionDrop, current.timeIntervalSince(lastRejectionDrop) < rejectionInterval {
            return false
        }
        lastRejectionDrop = current
        invalidateLocked()
        return true
    }

    /// The read at proxy start, so a Keychain access prompt (expected after
    /// every update: the app is self-signed, and the item's partition is
    /// keyed by its code hash) appears once, at a predictable time, rather
    /// than in the middle of a burst of handshakes. Drops what is cached,
    /// then reads only when a password is saved for the active identity:
    /// every `AuthenticationMode` can use one, and without one there is
    /// nothing to prompt for. Blocks for as long as a prompt is up, so call
    /// it off the main actor. A failure goes to `eventSink` as
    /// `auth.credentials_unavailable` and stays cached for the handshakes.
    package func warmCache(eventSink: (@Sendable (RuntimeEvent) -> Void)?) {
        let account = accountKey(for: identityProvider())
        cacheCondition.lock()
        invalidateLocked()
        cacheCondition.unlock()
        do {
            guard try keychain.exists(account: account) else { return }
            // Already on `warmQueue`; this is the one caller that waits
            // for the prompt to be answered.
            _ = try cachedCredentials(account: account, waitLimit: nil)
        } catch {
            eventSink?(RuntimeEvent(
                kind: .auth, event: "auth.credentials_unavailable",
                detail: "reason=\(error.credentialReadFailureReason) source=proxy_start"
            ))
        }
    }

    /// `warmCache` on its own queue rather than the caller's actor or the
    /// cooperative pool, since an access prompt holds the thread until the
    /// user answers. Both hosts call it once their listeners are up;
    /// handshakes that need the password meanwhile wait for it at most
    /// `pendingReadWait`. The task finishes when the read has.
    @discardableResult
    package func warmCacheInBackground(eventSink: (@Sendable (RuntimeEvent) -> Void)?) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.warmQueue.async {
                    self.warmCache(eventSink: eventSink)
                    continuation.resume()
                }
            }
        }
    }

    /// With `waitLimit` nil, waits for the read however long it takes; only
    /// `warmCache`, already off the cooperative pool, does that.
    private func cachedCredentials(account: String, waitLimit: TimeInterval?) throws -> ProxyCredentials? {
        let deadline = waitLimit.map { Date().addingTimeInterval($0) }
        cacheCondition.lock()
        defer { cacheCondition.unlock() }
        while true {
            if let entry = cacheEntry, entry.account == account, isCurrent(entry.result, loadedAt: entry.at) {
                return try entry.result.get()
            }
            if readInFlight == nil {
                startReadLocked(account: account)
            }
            guard let deadline else {
                cacheCondition.wait()
                continue
            }
            guard Date() < deadline else {
                throw CredentialReadPending()
            }
            _ = cacheCondition.wait(until: deadline)
        }
    }

    /// Caller holds `cacheCondition`. Hands the store read to `readQueue`,
    /// so the only thread that can sit on an access prompt is its own.
    private func startReadLocked(account: String) {
        readInFlight = account
        let generation = cacheGeneration
        readQueue.async {
            let result = Result { try self.readStore(account: account) }
            self.cacheCondition.lock()
            self.readInFlight = nil
            if self.cacheGeneration == generation {
                self.cacheEntry = CacheEntry(account: account, result: result, at: self.now())
            }
            self.cacheCondition.broadcast()
            self.cacheCondition.unlock()
        }
    }

    private func isCurrent(_ result: Result<ProxyCredentials?, any Error>, loadedAt: Date) -> Bool {
        guard case .failure(let error) = result else { return true }
        switch error.credentialReadFailureReason {
        case "denied", "invalid_payload":
            return true
        default:
            return now().timeIntervalSince(loadedAt) < failureRetryInterval
        }
    }

    private func readStore(account: String) throws -> ProxyCredentials? {
        guard let envelope = try keychain.load(account: account) else {
            return nil
        }
        guard let credentials = try? ProxyCredentials(keychainPayload: envelope) else {
            throw CredentialManagerError.invalidPayload
        }
        return credentials
    }

    /// Caller holds `cacheCondition`. A read that is out stays out, and its
    /// answer is dropped when it lands; the next caller starts a fresh one
    /// then, so there is still never more than one.
    private func invalidateLocked() {
        cacheGeneration += 1
        cacheEntry = nil
        cacheCondition.broadcast()
    }

    private func invalidateCache() {
        cacheCondition.lock()
        invalidateLocked()
        cacheCondition.unlock()
    }

    /// Profile-level write. Same `UpstreamProxy`-ignored shape as the read.
    package func setCredentials(_ credentials: ProxyCredentials, for _: UpstreamProxy) throws {
        let identity = identityProvider()
        let envelope = try credentials.keychainData()
        defer { invalidateCache() }
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
        defer { invalidateCache() }
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
        defer { invalidateCache() }
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

/// A handshake gave up waiting for a credential read that is still out,
/// typically behind an unanswered Keychain access prompt. Not cached: the
/// read carries on and answers the handshakes after it.
package struct CredentialReadPending: Error, LocalizedError, CredentialReadFailureDescribing {
    package var credentialReadFailureReason: String { "read_pending" }
    package var errorDescription: String? {
        "The saved proxy password is still being read from the Keychain; check for an access prompt."
    }
}
