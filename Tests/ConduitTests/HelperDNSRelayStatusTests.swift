// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ConduitShared
@testable import PlatformMac
@testable import ProxyKernel

final class HelperDNSRelayStatusTests: XCTestCase {

    func testACommandTheHelperDoesNotKnowFailsToDecode() {
        let later = Data(#"{"protocolVersion":5,"command":"some-later-command","values":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperRequest.self, from: later))
    }

    func testAStatusReplyRoundTripsAndAnOlderReplyHasNone() throws {
        var reply = HelperResponse.ok()
        reply.dnsRelay = HelperDNSRelayStatus(listening: true, targetPort: 5053, target: .refused)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: try JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.dnsRelay, HelperDNSRelayStatus(listening: true, targetPort: 5053, target: .refused))

        let older = Data(#"{"protocolVersion":5,"success":true}"#.utf8)
        let olderDecoded = try JSONDecoder().decode(HelperResponse.self, from: older)
        XCTAssertNil(olderDecoded.dnsRelay)
        XCTAssertNil(olderDecoded.features)
    }

    func testAVerdictThisClientDoesNotKnowIsNoStatusNotABrokenFrame() throws {
        let later = Data(#"{"protocolVersion":5,"success":true,"dnsRelay":{"listening":true,"targetPort":5053,"target":"later"}}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: later)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.dnsRelay)
    }

    func testAFeatureThisClientDoesNotKnowIsDropped() throws {
        let ping = Data(#"{"protocolVersion":5,"success":true,"features":["dns-relay-status","later"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HelperResponse.self, from: ping).features, [.dnsRelayStatus])
    }

    func testTheLastConsoleUserMayReadTheStatusAtTheLoginwindow() {
        XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501, command: .dnsRelayStatus))
    }

    /// Both fail the command as "Invalid request"; the ping's feature list says which helper this is.
    func testAHelperThatPredatesTheCommandIsNoStatusWithoutAPromptAndToldApartFromAFailure() throws {
        var current = HelperResponse.ok()
        current.features = [.dnsRelayStatus]
        for (ping, reason) in [(HelperResponse.ok(), "helper_predates_command"), (current, "helper_error")] {
            let helper = try FakeHelper(replies: [.error("Invalid request"), ping])
            defer { helper.stop() }
            let probe = clientProbe(helper.path)

            XCTAssertNil(try probe.client.dnsRelayStatus())
            XCTAssertFalse(probe.fallbackRan.withLockedValue { $0 })
            XCTAssertEqual(helper.commandsSeen, [.dnsRelayStatus, .ping])
            XCTAssertEqual(probe.events.withLockedValue { $0 }.map(\.event), ["auth.privilege_helper_relay_status_unavailable"])
            XCTAssertEqual(probe.events.withLockedValue { $0 }.first?.detail, "reason=\(reason) helper_error=Invalid request")
        }
    }

    /// The feature list is decoded strictly: helpers this client talks to send an array of strings, so anything else is a broken
    /// frame, not an empty list. Unknown names inside the array are still dropped.
    func testAFeatureListThatIsNotAnArrayBreaksTheFrame() {
        let ping = Data(#"{"protocolVersion":5,"success":true,"features":"dns-relay-status"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperResponse.self, from: ping))
    }

    func testAnUnreachableHelperIsReportedBeforeItThrows() {
        let probe = clientProbe("/tmp/pm-no-helper-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try probe.client.dnsRelayStatus())
        XCTAssertEqual(probe.events.withLockedValue { $0 }.map(\.event), ["auth.privilege_helper_relay_status_unavailable"])
        XCTAssertEqual(probe.events.withLockedValue { $0 }.first?.detail?.hasPrefix("reason=unreachable "), true)
    }

    func testAHelperOnAnotherProtocolIsNoStatus() throws {
        var older = HelperResponse.error("Invalid request")
        older.protocolVersion = 4
        let helper = try FakeHelper(replies: [older])
        defer { helper.stop() }
        let probe = clientProbe(helper.path)

        XCTAssertNil(try probe.client.dnsRelayStatus())
        XCTAssertFalse(probe.fallbackRan.withLockedValue { $0 })
        XCTAssertEqual(probe.events.withLockedValue { $0 }.first?.detail, "reason=protocol_mismatch protocol=4")
    }

    func testTheHelpersVerdictReachesTheCaller() throws {
        let cases: [(HelperDNSRelayStatus, DNSRelayStatus)] = [
            (.init(listening: true, targetPort: 5053, target: .refused), .relaying(targetPort: 5053, target: .refused)),
            (.init(listening: true, targetPort: 5053, target: .answered), .relaying(targetPort: 5053, target: .answered)),
            (.init(listening: true, targetPort: 5053, target: .silent), .relaying(targetPort: 5053, target: .silent)),
            (.init(listening: false, targetPort: nil, target: .notRunning), .notRunning),
        ]
        for (wire, expected) in cases {
            var reply = HelperResponse.ok()
            reply.dnsRelay = wire
            let helper = try FakeHelper(replies: [reply])
            defer { helper.stop() }
            let probe = clientProbe(helper.path)
            XCTAssertEqual(try probe.client.dnsRelayStatus(), expected, "\(wire.target)")
            XCTAssertTrue(probe.events.withLockedValue { $0 }.isEmpty)
        }
    }

    func testAStatusWhoseFieldsDisagreeIsNoStatus() throws {
        var reply = HelperResponse.ok()
        reply.dnsRelay = HelperDNSRelayStatus(listening: false, targetPort: 5053, target: .refused)
        let helper = try FakeHelper(replies: [reply])
        defer { helper.stop() }
        let probe = clientProbe(helper.path)

        XCTAssertNil(try probe.client.dnsRelayStatus())
        XCTAssertEqual(probe.events.withLockedValue { $0 }.first?.detail, "reason=unreadable_status")
    }

    func testAMissingHelperThrowsUnreachableWithoutAPrompt() {
        let probe = clientProbe("/tmp/pm-no-helper-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try probe.client.dnsRelayStatus()) { error in
            XCTAssertEqual((error as? PrivilegeClientError)?.isHelperUnreachable, true)
        }
        XCTAssertFalse(probe.fallbackRan.withLockedValue { $0 })
    }

    func testARefusalThrowsRefused() throws {
        let helper = try FakeHelper(replies: [.refused(.unauthorized, "peer is not the console user")])
        defer { helper.stop() }
        let probe = clientProbe(helper.path)
        XCTAssertThrowsError(try probe.client.dnsRelayStatus()) { error in
            guard case .refused(.unauthorized, _)? = error as? PrivilegeClientError else {
                return XCTFail("expected refused(.unauthorized), got \(error)")
            }
        }
        XCTAssertEqual(probe.events.withLockedValue { $0 }.map(\.event), ["auth.privilege_helper_refused"])
    }

    func testTheAuditingClientPassesTheHelpersStatusThrough() throws {
        let base = RecordingPrivilegeClient()
        base.relayStatus = .relaying(targetPort: 5053, target: .refused)
        let audited = AuditingPrivilegeClient(base: base, eventSink: { _ in })
        XCTAssertEqual(try audited.dnsRelayStatus(), .relaying(targetPort: 5053, target: .refused))
    }

    private struct ClientProbe {
        var client: HelperToolPrivilegeClient
        var events: NIOLockedValueBox<[RuntimeEvent]>
        var fallbackRan: NIOLockedValueBox<Bool>
    }

    private func clientProbe(_ socketPath: String) -> ClientProbe {
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let fallbackRan = NIOLockedValueBox(false)
        let client = HelperToolPrivilegeClient(
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            socketPath: socketPath,
            fallback: AppleScriptPrivilegeClient(runner: { _ in
                fallbackRan.withLockedValue { $0 = true }
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }),
            transactionMilliseconds: 2_000
        )
        return ClientProbe(client: client, events: events, fallbackRan: fallbackRan)
    }
}
