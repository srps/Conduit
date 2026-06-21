// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Stand-in authenticator that drives the 407 → 200 handshake with the fake upstream.
/// Stateful like a real SPNEGO authenticator so the codepaths exercised match production.
final class MockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    private let lock = NSLock()
    private var initialSent = false

    func initialToken(for host: String) throws -> String {
        lock.withLock { initialSent = true }
        return "Negotiate FakeInitialToken"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        "Negotiate FakeChallengeResponse"
    }

    func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    func reset() {
        lock.withLock { initialSent = false }
    }
}

final class SlowMockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    private let delayMs: UInt32

    init(delayMs: UInt32) {
        self.delayMs = delayMs
    }

    func initialToken(for host: String) throws -> String {
        usleep(delayMs * 1_000)
        return "Negotiate SlowFakeInitialToken"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        usleep(delayMs * 1_000)
        return "Negotiate SlowFakeChallengeResponse"
    }

    func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    func reset() {}
}
