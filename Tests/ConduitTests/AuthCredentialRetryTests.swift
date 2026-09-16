// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class AuthCredentialRetryTests: XCTestCase {
    private struct CredentialGone: CredentialFailureClassifying {
        var isCredentialUnavailable: Bool { true }
    }

    private struct ProtocolBroken: CredentialFailureClassifying {
        var isCredentialUnavailable: Bool { false }
    }

    /// A store with no entry: unavailable, but waiting will not help.
    private struct CredentialMissing: CredentialFailureClassifying {
        var isCredentialUnavailable: Bool { true }
        var isCredentialRetryable: Bool { false }
    }

    private struct PlainFailure: Error {}

    /// Fails `failures` times with `error`, then answers.
    private final class ScriptedAuthenticator: ProxyAuthenticator, @unchecked Sendable {
        let scheme = "Negotiate"
        private let lock = NIOLock()
        private var remainingFailures: Int
        private let error: Error
        private(set) var calls = 0

        init(failures: Int, error: Error) {
            self.remainingFailures = failures
            self.error = error
        }

        var callCount: Int { lock.withLock { calls } }

        func initialToken(for host: String) throws -> String {
            try lock.withLock {
                calls += 1
                if remainingFailures > 0 {
                    remainingFailures -= 1
                    throw error
                }
                return "Negotiate token"
            }
        }

        func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
        func canHandle(scheme: String) -> Bool { true }
        func reset() {}
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NIOLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        private var slept: [TimeInterval] = []
        var now: Date { lock.withLock { current } }
        var sleeps: [TimeInterval] { lock.withLock { slept } }
        func sleep(_ seconds: TimeInterval) { lock.withLock { slept.append(seconds); current += seconds } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    private func makeRetry(_ clock: Clock, attempts: Int = 2) -> AuthCredentialRetry {
        AuthCredentialRetry(
            attempts: attempts,
            delay: 0.75,
            outageHold: 30,
            sleep: { clock.sleep($0) },
            now: { clock.now }
        )
    }

    func testTransientCredentialFailureIsRetriedAndSucceeds() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)
        let auth = ScriptedAuthenticator(failures: 1, error: CredentialGone())

        let token = try await retry.initialToken(from: auth, host: "proxy.example")

        XCTAssertEqual(token, "Negotiate token")
        XCTAssertEqual(auth.callCount, 2)
        XCTAssertEqual(clock.sleeps, [0.75])
        XCTAssertFalse(retry.isInOutage(host: "proxy.example"))
    }

    func testExhaustedRetriesThrowAndOpenAnOutage() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)
        let auth = ScriptedAuthenticator(failures: 10, error: CredentialGone())

        do {
            _ = try await retry.initialToken(from: auth, host: "proxy.example")
            XCTFail("expected the credential failure to surface")
        } catch {
            XCTAssertTrue(error.isCredentialUnavailable)
        }
        XCTAssertEqual(auth.callCount, 3, "one try plus two retries")
        XCTAssertEqual(clock.sleeps.count, 2)
        XCTAssertTrue(retry.isInOutage(host: "proxy.example"))

        // The next handshake during the outage fails at once.
        let next = ScriptedAuthenticator(failures: 10, error: CredentialGone())
        _ = try? await retry.initialToken(from: next, host: "proxy.example")
        XCTAssertEqual(next.callCount, 1)
        XCTAssertEqual(clock.sleeps.count, 2, "no further waiting while the outage holds")
    }

    func testOutageExpiresAndASuccessClearsIt() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)
        _ = try? await retry.initialToken(from: ScriptedAuthenticator(failures: 10, error: CredentialGone()), host: "proxy.example")
        XCTAssertTrue(retry.isInOutage(host: "proxy.example"))

        clock.advance(31)
        XCTAssertFalse(retry.isInOutage(host: "proxy.example"))

        _ = try? await retry.initialToken(from: ScriptedAuthenticator(failures: 10, error: CredentialGone()), host: "proxy.example")
        XCTAssertTrue(retry.isInOutage(host: "proxy.example"))
        let recovered = ScriptedAuthenticator(failures: 0, error: CredentialGone())
        _ = try await retry.initialToken(from: recovered, host: "proxy.example")
        XCTAssertFalse(retry.isInOutage(host: "proxy.example"), "a success ends the outage early")
    }

    func testOutagesAreKeyedByHost() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)
        _ = try? await retry.initialToken(from: ScriptedAuthenticator(failures: 10, error: CredentialGone()), host: "a.example")
        XCTAssertTrue(retry.isInOutage(host: "a.example"))
        XCTAssertFalse(retry.isInOutage(host: "b.example"))
    }

    /// Primary fails `primaryFailures` times, then answers; the fallback
    /// answers whenever it is allowed. Records each call's `allowFallback`.
    private final class DeferringAuthenticator: FallbackDeferringAuthenticator, @unchecked Sendable {
        let scheme = "Negotiate"
        private let lock = NIOLock()
        private var remainingPrimaryFailures: Int
        private(set) var allowFlags: [Bool] = []

        init(primaryFailures: Int) { self.remainingPrimaryFailures = primaryFailures }

        var flags: [Bool] { lock.withLock { allowFlags } }

        func initialToken(for host: String) throws -> String {
            try initialToken(for: host, allowFallback: true).token
        }

        func initialToken(for host: String, allowFallback: Bool) throws -> (token: String, usedFallback: Bool) {
            try lock.withLock {
                allowFlags.append(allowFallback)
                if remainingPrimaryFailures > 0 {
                    remainingPrimaryFailures -= 1
                    if allowFallback { return ("NTLM token", true) }
                    throw CredentialGone()
                }
                return ("Negotiate token", false)
            }
        }

        func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
        func canHandle(scheme: String) -> Bool { true }
        func reset() {}
    }

    func testFallbackIsWithheldUntilTheLastAttempt() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)

        // Primary comes back on the second try: no downgrade.
        let recovers = DeferringAuthenticator(primaryFailures: 1)
        let token = try await retry.initialToken(from: recovers, host: "proxy.example", outageKey: "proxy.example:8080")
        XCTAssertEqual(token, "Negotiate token")
        XCTAssertEqual(recovers.flags, [false, false])
        XCTAssertFalse(retry.isInOutage(host: "proxy.example:8080"))

        // Primary stays down: the last attempt allows the fallback, and the
        // downgrade opens an outage so later handshakes go straight to it.
        let down = DeferringAuthenticator(primaryFailures: 10)
        let fallback = try await retry.initialToken(from: down, host: "proxy.example", outageKey: "proxy.example:8080")
        XCTAssertEqual(fallback, "NTLM token")
        XCTAssertEqual(down.flags, [false, false, true])
        XCTAssertTrue(retry.isInOutage(host: "proxy.example:8080"))

        let next = DeferringAuthenticator(primaryFailures: 10)
        _ = try await retry.initialToken(from: next, host: "proxy.example", outageKey: "proxy.example:8080")
        XCTAssertEqual(next.flags, [true], "inside the outage the fallback is allowed at once")
    }

    func testOtherAuthFailuresAreNotRetried() async throws {
        let clock = Clock()
        let retry = makeRetry(clock)
        for error in [ProtocolBroken() as Error, PlainFailure() as Error, CredentialMissing() as Error] {
            let auth = ScriptedAuthenticator(failures: 1, error: error)
            _ = try? await retry.initialToken(from: auth, host: "proxy.example")
            XCTAssertEqual(auth.callCount, 1, "\(error) is not retryable")
        }
        XCTAssertTrue(CredentialManagerError.missingCredentials.isCredentialUnavailable)
        XCTAssertFalse(CredentialManagerError.missingCredentials.isCredentialRetryable)
        XCTAssertFalse(CredentialManagerError.invalidPayload.isCredentialUnavailable)
        XCTAssertEqual(clock.sleeps, [])
        XCTAssertFalse(retry.isInOutage(host: "proxy.example"))
    }
}
