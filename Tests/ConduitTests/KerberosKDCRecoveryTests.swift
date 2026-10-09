// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel
@testable import PlatformMac

final class KerberosKDCRecoveryTests: XCTestCase {
    private let host = "proxy.corp.example"
    private func unreachable() -> KerberosAuthError {
        .serviceTicketUnavailable(host: host, major: 65536, minor: 0,
                                  mech: .status(major: 851968, minor: UInt32(bitPattern: -1_765_328_228)))
    }

    private struct Recoverer: KerberosTicketRecovering {
        let prime: @Sendable (String) throws -> Void
        func primeServiceTicket(host: String) throws { try prime(host) }
    }

    func testFreshProcessPrimingUnpinsTheSameLongLivedProvider() throws {
        let cachedFailure = NIOLockedValueBox(true)
        let calls = NIOLockedValueBox(0)
        let primes = NIOLockedValueBox(0)
        let events = RuntimeEventLog(capacity: 8)
        let failure = unreachable()
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { target in
            XCTAssertEqual(target, "proxy.corp.example")
            primes.withLockedValue { $0 += 1 }
            // Model Apple's process-negative-cache notification after the
            // separate process actually obtains and stores a service ticket.
            cachedFailure.withLockedValue { $0 = false }
        })
        let provider = SystemGSSTokenProvider(
            gate: GSSInitiatorGate(cooldown: 5), kdcRecovery: recovery,
            eventSink: { events.append($0) }, gssAttempt: { _, _ in
                calls.withLockedValue { $0 += 1 }
                if cachedFailure.withLockedValue({ $0 }) { throw failure }
                return Data([0x60, 1, 0])
            }
        )
        XCTAssertEqual(try provider.generateToken(host: host, inputToken: nil), Data([0x60, 1, 0]))
        XCTAssertEqual(try provider.generateToken(host: host, inputToken: Data([1])), Data([0x60, 1, 0]))
        XCTAssertEqual(primes.withLockedValue { $0 }, 1)
        XCTAssertEqual(calls.withLockedValue { $0 }, 3)
        XCTAssertEqual(events.events.map(\.event), ["auth.kerberos_recovery_started", "auth.kerberos_recovery_succeeded"])
    }

    func testAnOfflineKDCFallsBackAndRecoveryBudgetIsSharedAcrossHosts() throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1000))
        let primes = NIOLockedValueBox(0)
        let failure = unreachable()
        let events = RuntimeEventLog(capacity: 8)
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in
            primes.withLockedValue { $0 += 1 }
            throw KerberosTicketRecoveryError.workerFailed(69)
        }, now: { clock.withLockedValue { $0 } })
        let gate = GSSInitiatorGate(cooldown: 5, now: { clock.withLockedValue { $0 } })
        for step in 0..<12 {
            let provider = SystemGSSTokenProvider(gate: gate, kdcRecovery: recovery,
                                                 eventSink: { events.append($0) }, gssAttempt: { _, _ in throw failure })
            let auth = NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: provider),
                ntlmFallback: NTLMAuthenticator(credentials: ProxyCredentials(
                    username: "test", domain: "TEST", workstation: "WS", ntHash: SecretBytes.repeating(0xAA, count: 16))))
            XCTAssertTrue(try auth.initialToken(for: "proxy-\(step).example").hasPrefix("NTLM "))
            clock.withLockedValue { $0.addTimeInterval(5) }
        }
        XCTAssertEqual(primes.withLockedValue { $0 }, 1)
        XCTAssertEqual(events.events.map(\.event), ["auth.kerberos_recovery_started", "auth.kerberos_recovery_failed"])
        XCTAssertThrowsError(try recovery.run(host: host, inputToken: nil, eventSink: nil) { throw failure })
        XCTAssertEqual(primes.withLockedValue { $0 }, 2, "real attempts can resume after the one-minute bound")
    }

    func testRecoveryDoesNotRetryContinuationCredentialAbsenceOrUnknownCause() {
        let primes = NIOLockedValueBox(0)
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in primes.withLockedValue { $0 += 1 } })
        let failures: [(Data?, KerberosAuthError)] = [
            (Data([1]), unreachable()),
            (nil, .noTicket),
            (nil, .serviceTicketUnavailable(host: host, major: 65536, minor: 0)),
            (nil, .serviceTicketUnavailable(host: host, major: 65536, minor: 0,
                                          mech: .status(major: 851968, minor: UInt32(bitPattern: -1_765_328_377)))),
            (nil, .initSecContextFailed(851968, UInt32(bitPattern: -1_765_328_347))),
            (nil, .serviceTicketUnavailable(host: host, major: 65536, minor: 0,
                                            mech: .cachedStatus(major: 851968, minor: UInt32(bitPattern: -1_765_328_228))))
        ]
        for (input, failure) in failures {
            XCTAssertThrowsError(try recovery.run(host: host, inputToken: input, eventSink: nil) { throw failure })
        }
        XCTAssertEqual(primes.withLockedValue { $0 }, 0)
    }

    func testFailedPrimingWithoutNTLMKeepsTheOriginalFailure() {
        let failure = unreachable()
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in
            throw KerberosTicketRecoveryError.executableUnavailable
        })
        let provider = SystemGSSTokenProvider(gate: GSSInitiatorGate(cooldown: 0), kdcRecovery: recovery,
                                             gssAttempt: { _, _ in throw failure })
        let authenticator = NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: provider))
        XCTAssertThrowsError(try authenticator.initialToken(for: host)) { error in
            guard let error = error as? KerberosAuthError else { return XCTFail("unexpected failure") }
            XCTAssertEqual(error.diagnosticDetail, failure.diagnosticDetail)
            XCTAssertEqual(error.fallbackReasonCode, "service_ticket_unavailable")
        }
    }

    func testAParentRetryFailureIsReportedAndNeverLoops() {
        let failure = unreachable()
        let calls = NIOLockedValueBox(0)
        let events = RuntimeEventLog(capacity: 8)
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in })
        let provider = SystemGSSTokenProvider(gate: GSSInitiatorGate(cooldown: 0), kdcRecovery: recovery,
            eventSink: { events.append($0) }, gssAttempt: { _, _ in calls.withLockedValue { $0 += 1 }; throw failure })
        XCTAssertThrowsError(try provider.generateToken(host: host, inputToken: nil))
        XCTAssertEqual(calls.withLockedValue { $0 }, 2)
        XCTAssertTrue(events.events.last?.detail?.contains("stage=retry") == true)
        XCTAssertThrowsError(try provider.generateToken(host: host, inputToken: nil))
        XCTAssertEqual(calls.withLockedValue { $0 }, 3)
    }

    func testTheProcessGateSerializesPrimingWithEveryOtherHandshake() {
        let gate = GSSInitiatorGate(cooldown: 0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let failure = unreachable()
        let pinned = NIOLockedValueBox(true)
        let secondRan = NIOLockedValueBox(false)
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            XCTAssertFalse(secondRan.withLockedValue { $0 }, "another GSS call cannot enter while priming")
            pinned.withLockedValue { $0 = false }
        })
        let first = SystemGSSTokenProvider(gate: gate, kdcRecovery: recovery, gssAttempt: { _, _ in
            if pinned.withLockedValue({ $0 }) { throw failure }
            return Data([1])
        })
        let second = SystemGSSTokenProvider(gate: gate, gssAttempt: { _, _ in
            secondRan.withLockedValue { $0 = true }
            return Data([2])
        })
        DispatchQueue.global().async(group: finished) {
            do { _ = try first.generateToken(host: "one", inputToken: nil) }
            catch { XCTFail("first handshake failed: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async(group: finished) {
            do { _ = try second.generateToken(host: "two", inputToken: nil) }
            catch { XCTFail("second handshake failed: \(error)") }
        }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(secondRan.withLockedValue { $0 })
    }

    func testProbeCauseSurvivesIndependentLogGateTimingAndCacheEviction() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1000))
        let calls = NIOLockedValueBox(0)
        let diagnoser = KerberosMechDiagnoser(interval: 60, capacity: 2, now: { clock.withLockedValue { $0 } }) { _ in
            calls.withLockedValue { $0 += 1 }
            return .status(major: 851968, minor: UInt32(bitPattern: -1_765_328_228))
        }
        func failure(_ host: String) -> KerberosAuthError { .serviceTicketUnavailable(host: host, major: 65536, minor: 0) }
        _ = diagnoser.annotate(failure(host))
        clock.withLockedValue { $0.addTimeInterval(5) }
        XCTAssertTrue(diagnoser.annotate(failure(host)).diagnosticDetail?.contains("KRB5_KDC_UNREACH") == true)
        XCTAssertTrue(diagnoser.annotate(failure(host)).diagnosticDetail?.contains("krb5_probe=cached") == true)
        XCTAssertEqual(calls.withLockedValue { $0 }, 1)
        _ = diagnoser.annotate(failure("two"))
        clock.withLockedValue { $0.addTimeInterval(1) }
        _ = diagnoser.annotate(failure("three"))
        _ = diagnoser.annotate(failure(host))
        XCTAssertEqual(calls.withLockedValue { $0 }, 4, "the fixed-capacity cache evicted the oldest host")
    }

    func testWorkerValidatesBeforeProbeAndTransportsOnlyCodes() throws {
        let flag = KerberosTicketRecoveryReply.argument
        var probes = 0
        var output = Data()
        XCTAssertNil(KerberosTicketRecoveryWorker.run(arguments: [], probe: { _ in XCTFail(); return .probeFailed }))
        for args in [[flag], [flag, "bad host"], [flag, "--help"], [flag, "::::"], [flag, "a..b"],
                     [flag, host, "--dev"], ["--dev", flag, host], [flag, String(repeating: "a", count: 254)]] {
            XCTAssertEqual(KerberosTicketRecoveryWorker.run(arguments: args, probe: { _ in XCTFail(); return .probeFailed }), 64)
        }
        let code = KerberosTicketRecoveryWorker.run(arguments: [flag, host], probe: { target in
            probes += 1
            XCTAssertEqual(target, host)
            return .status(major: 1, minor: 0)
        }, write: { output = $0 })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(probes, 1)
        let reply = try CanonicalJSON.decoder().decode(KerberosTicketRecoveryReply.self, from: output)
        XCTAssertEqual(reply.major, 1, "CONTINUE_NEEDED is a produced initial token, not an error")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "{\"major\":1,\"minor\":0}\n")
        XCTAssertEqual(KerberosTicketRecoveryWorker.run(arguments: [flag, host], probe: { _ in .probeFailed }), 69)
        for host in ["proxy.example.", "localhost", "127.0.0.1", "[::1]", "2001:db8::1"] {
            XCTAssertTrue(KerberosTicketRecoveryReply.isValidHost(host))
        }
    }

    func testLauncherUsesBoundedDirectArgvAndRefusesFailedOrMalformedReplies() throws {
        let seen = NIOLockedValueBox(false)
        let launcher = SystemKerberosTicketRecovery(executable: URL(fileURLWithPath: "/tmp/Conduit with spaces")) {
            executable, args, timeout, outputLimit in
            XCTAssertEqual(executable, "/tmp/Conduit with spaces")
            XCTAssertEqual(args, [KerberosTicketRecoveryReply.argument, "proxy.corp.example"])
            XCTAssertEqual(timeout, 10)
            XCTAssertEqual(outputLimit, 512)
            seen.withLockedValue { $0 = true }
            return CommandResult(exitCode: 0, standardOutput: "{\"major\":1,\"minor\":0}", standardError: "ignored")
        }
        try launcher.primeServiceTicket(host: host)
        XCTAssertTrue(seen.withLockedValue { $0 })
        for result in [CommandResult(exitCode: 69, standardOutput: "", standardError: "private"),
                       CommandResult(exitCode: 69, standardOutput: "{\"major\":851968,\"minor\":2529639068}", standardError: "private"),
                       CommandResult(exitCode: 0, standardOutput: "garbage", standardError: "private"),
                       CommandResult(exitCode: 0, standardOutput: "{\"major\":851968,\"minor\":0}", standardError: "")] {
            let bad = SystemKerberosTicketRecovery(executable: URL(fileURLWithPath: "/tmp/test"), run: { _, _, _, _ in result })
            XCTAssertThrowsError(try bad.primeServiceTicket(host: host)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
        XCTAssertThrowsError(try SystemKerberosTicketRecovery(executable: nil).primeServiceTicket(host: host))
    }
}
