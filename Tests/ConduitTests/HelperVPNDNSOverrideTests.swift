// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ConduitShared
@testable import PlatformMac
@testable import ProxyKernel

final class HelperVPNDNSOverrideTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private let servers = ["192.0.2.53", "198.51.100.53"]

    func testTheOverrideReplyFieldsRoundTrip() throws {
        var reply = HelperResponse.error("VPN DNS override refused: changed")
        reply.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, originals: servers)
        reply.vpnDNSOverrideRefusal = .changed
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: try JSONEncoder().encode(reply))
        XCTAssertEqual(decoded, reply)
    }

    func testTheLastReleaseRoundTripsAndAnOlderReplyHasNone() throws {
        var reply = HelperResponse.ok()
        reply.vpnDNSOverrideLastRelease = "target_refused"
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: try JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.vpnDNSOverrideLastRelease, "target_refused")

        let older = Data(#"{"protocolVersion":5,"success":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperResponse.self, from: older).vpnDNSOverrideLastRelease)
        let wrongType = Data(#"{"protocolVersion":5,"success":true,"vpnDNSOverrideLastRelease":7}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperResponse.self, from: wrongType).vpnDNSOverrideLastRelease)
    }

    func testAnOlderClientIgnoresTheLastRelease() throws {
        struct OlderStatusReply: Decodable {
            var protocolVersion: Int
            var success: Bool
            var vpnDNSOverride: HelperVPNDNSOverrideStatus?
        }
        var reply = HelperResponse.ok()
        reply.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, originals: servers)
        reply.vpnDNSOverrideLastRelease = "relay_stopped"
        let older = try JSONDecoder().decode(OlderStatusReply.self, from: try JSONEncoder().encode(reply))
        XCTAssertTrue(older.success)
        XCTAssertEqual(older.vpnDNSOverride, reply.vpnDNSOverride)
    }

    func testOnlyAReleaseReasonThisClientKnowsReachesTheReply() {
        XCTAssertEqual(HelperToolPrivilegeClient.releaseReason("target_silent"), "target_silent")
        XCTAssertNil(HelperToolPrivilegeClient.releaseReason("a_reason_from_later"))
        XCTAssertNil(HelperToolPrivilegeClient.releaseReason("relay stopped 127.0.0.1"))
        XCTAssertNil(HelperToolPrivilegeClient.releaseReason(nil))
    }

    func testAnOlderHelpersReplyHasNoOverrideFields() throws {
        let older = Data(#"{"protocolVersion":5,"success":true,"features":["dns-relay-status"]}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: older)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.vpnDNSOverride)
        XCTAssertNil(decoded.vpnDNSOverrideRefusal)
        XCTAssertEqual(decoded.features, [.dnsRelayStatus])
    }

    func testARefusalOrStatusThisClientCannotReadIsDroppedNotABrokenFrame() throws {
        let later = Data(#"{"protocolVersion":5,"success":false,"vpnDNSOverrideRefusal":"later","vpnDNSOverride":{"serviceID":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: later)
        XCTAssertFalse(decoded.success)
        XCTAssertNil(decoded.vpnDNSOverrideRefusal)
        XCTAssertNil(decoded.vpnDNSOverride)
    }

    func testTheCommandsAndFeatureKeepTheirWireNames() throws {
        XCTAssertEqual(HelperCommand.vpnDNSOverrideApply.rawValue, "vpn-dns-override-apply")
        XCTAssertEqual(HelperCommand.vpnDNSOverrideRelease.rawValue, "vpn-dns-override-release")
        XCTAssertEqual(HelperCommand.vpnDNSOverrideStatus.rawValue, "vpn-dns-override-status")
        XCTAssertEqual(HelperFeature.vpnDNSOverride.rawValue, "vpn-dns-override")
        for refusal in HelperVPNDNSOverrideRefusal.allCases {
            XCTAssertEqual(VPNDNSOverrideRefusal(refusal).rawValue, refusal.rawValue)
        }
        XCTAssertEqual(VPNDNSOverrideRefusal.allCases.count, HelperVPNDNSOverrideRefusal.allCases.count)
    }

    func testReleaseAndStatusAreTeardownOnlyAndApplyIsNot() {
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.vpnDNSOverrideRelease))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.vpnDNSOverrideStatus))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.vpnDNSOverrideApply))
        for command in [HelperCommand.vpnDNSOverrideRelease, .vpnDNSOverrideStatus] {
            XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501, command: command), command.rawValue)
        }
        XCTAssertEqual(
            HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501, command: .vpnDNSOverrideApply, values: [service] + servers),
            .noConsoleUser
        )
        XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 501, lastConsoleUID: 501, command: .vpnDNSOverrideApply, values: [service] + servers))
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 502, consoleUID: 501, lastConsoleUID: 501, command: .vpnDNSOverrideRelease), .unauthorized)
    }

    func testARefusedApplyIsAuditedAsAFixedWord() {
        XCTAssertEqual(HelperAuditOutcome.declined.rawValue, "declined")
    }

    func testAHelperWithoutTheFeatureIsUnsupportedWithoutAPrompt() throws {
        var older = HelperResponse.ok()
        older.features = [.dnsRelayStatus]
        for request in [VPNDNSOverrideRequest.apply(service: service, expected: servers), .release, .status] {
            let helper = try FakeHelper(replies: [.error("Invalid request"), older])
            defer { helper.stop() }
            let probe = clientProbe(helper.path)

            XCTAssertEqual(try probe.client.vpnDNSOverride(request), .unsupported, "\(request)")
            XCTAssertEqual(helper.commandsSeen.last, .ping)
            XCTAssertFalse(probe.fallbackRan.withLockedValue { $0 })
        }
    }

    func testNoInstalledHelperIsUnsupportedWithoutAsking() throws {
        let helper = try FakeHelper(replies: [])
        defer { helper.stop() }
        let probe = clientProbe(helper.path, binaryPath: "/tmp/pm-no-helper-binary-\(UUID().uuidString.prefix(8))")
        XCTAssertEqual(try probe.client.vpnDNSOverride(.status), .unsupported)
        XCTAssertEqual(helper.requestsSeen, 0)
    }

    func testAHelperOnAnotherProtocolIsUnsupported() throws {
        var older = HelperResponse.error("Invalid request")
        older.protocolVersion = 4
        let helper = try FakeHelper(replies: [older])
        defer { helper.stop() }
        XCTAssertEqual(try clientProbe(helper.path).client.vpnDNSOverride(.release), .unsupported)
    }

    func testAnApplyCarriesTheServiceAndServersAndMapsTheReply() throws {
        var applied = HelperResponse.ok()
        applied.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, originals: servers)
        let helper = try FakeHelper(replies: [applied])
        defer { helper.stop() }

        XCTAssertEqual(try clientProbe(helper.path).client.vpnDNSOverride(.apply(service: service, expected: servers)), .applied)
        XCTAssertEqual(helper.commandsSeen, [.vpnDNSOverrideApply])
        XCTAssertEqual(helper.valuesSeen, [[service] + servers])
    }

    func testARefusedApplyIsTheRefusalWithoutAPing() throws {
        var refused = HelperResponse.error("VPN DNS override refused: changed")
        refused.vpnDNSOverrideRefusal = .changed
        let helper = try FakeHelper(replies: [refused])
        defer { helper.stop() }

        XCTAssertEqual(try clientProbe(helper.path).client.vpnDNSOverride(.apply(service: service, expected: servers)), .refused(.changed))
        XCTAssertEqual(helper.commandsSeen, [.vpnDNSOverrideApply])
    }

    func testStatusAndReleaseMapTheReply() throws {
        var held = HelperResponse.ok()
        held.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, originals: servers)
        var released = HelperResponse.ok()
        released.vpnDNSOverrideLastRelease = "target_refused"
        var pending = held
        pending.vpnDNSOverrideRestorePending = "owner_exited"
        let helper = try FakeHelper(replies: [held, released, pending, .ok()])
        defer { helper.stop() }
        let client = clientProbe(helper.path).client

        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(VPNDNSOverrideState(serviceID: service, originals: servers)))
        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(nil, lastRelease: "target_refused"))
        XCTAssertEqual(
            try client.vpnDNSOverride(.status),
            .status(VPNDNSOverrideState(serviceID: service, originals: servers), restorePending: "owner_exited")
        )
        XCTAssertEqual(try client.vpnDNSOverride(.release), .released)
        XCTAssertEqual(helper.commandsSeen, [.vpnDNSOverrideStatus, .vpnDNSOverrideStatus, .vpnDNSOverrideStatus, .vpnDNSOverrideRelease])
    }

    func testAStatusOutOfShapeIsAnError() throws {
        var held = HelperResponse.ok()
        held.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, originals: ["127.0.0.1"])
        let helper = try FakeHelper(replies: [held])
        defer { helper.stop() }
        XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.status))
    }

    func testAFailureFromAHelperWithTheFeatureThrows() throws {
        var current = HelperResponse.ok()
        current.features = HelperFeature.allCases
        let helper = try FakeHelper(replies: [.error("VPN DNS override release could not write the key: restore_failed"), current])
        defer { helper.stop() }
        XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.release)) { error in
            guard case .executionFailed? = error as? PrivilegeClientError else { return XCTFail("got \(error)") }
        }
    }

    func testARefusalAndAnUnreachableHelperThrow() throws {
        let helper = try FakeHelper(replies: [.refused(.noConsoleUser, "no console user yet")])
        defer { helper.stop() }
        XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.apply(service: service, expected: servers))) { error in
            guard case .refused(.noConsoleUser, _)? = error as? PrivilegeClientError else { return XCTFail("got \(error)") }
        }
        let missing = clientProbe("/tmp/pm-no-helper-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try missing.client.vpnDNSOverride(.status)) { error in
            XCTAssertEqual((error as? PrivilegeClientError)?.isHelperUnreachable, true)
        }
        XCTAssertFalse(missing.fallbackRan.withLockedValue { $0 })
    }

    func testAnApplyTheHelperWouldRefuseIsNeverSent() throws {
        let helper = try FakeHelper(replies: [.ok()])
        defer { helper.stop() }
        let client = clientProbe(helper.path).client
        for (service, expected) in [(service, ["127.0.0.1"]), (service, []), ("a/b", servers), (service, Array(repeating: "192.0.2.1", count: 17))] {
            XCTAssertThrowsError(try client.vpnDNSOverride(.apply(service: service, expected: expected)), "\(service) \(expected)")
        }
        XCTAssertEqual(helper.requestsSeen, 0)
    }

    func testAPingWithoutTheOverrideFeatureReadsAsUpdateAvailable() {
        var older = HelperResponse.ok()
        older.features = [.dnsRelayStatus]
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: older), .updateAvailable)
        var current = HelperResponse.ok()
        current.features = HelperFeature.allCases
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: current), .installed)
    }

    func testTheAuditingClientAndTheRecorderPassTheRequestThrough() throws {
        let base = RecordingPrivilegeClient()
        XCTAssertEqual(try base.vpnDNSOverride(.status), .unsupported, "the recorder answers as an older helper by default")
        base.vpnDNSOverrideReply = .applied
        let audited = AuditingPrivilegeClient(base: base, eventSink: { _ in })
        XCTAssertEqual(try audited.vpnDNSOverride(.apply(service: service, expected: servers)), .applied)
        XCTAssertEqual(base.vpnDNSOverrideRequests, [.status, .apply(service: service, expected: servers)])
        XCTAssertEqual(try AppleScriptPrivilegeClient(runner: { _ in CommandResult(exitCode: 0, standardOutput: "", standardError: "") }).vpnDNSOverride(.status), .unsupported)
    }

    private func machine() -> FakeMachine {
        let machine = FakeMachine(resolverDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pm-vpn-override-\(UUID().uuidString.prefix(8))"))
        machine.vpnDNSStore.connectFullTunnel(service, servers: servers)
        return machine
    }

    func testFakeMachineAppliesOnlyWhileItsRelayRuns() throws {
        let machine = machine()
        XCTAssertEqual(try machine.vpnDNSOverride(.apply(service: service, expected: servers)), .refused(.relayNotServing))
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertEqual(try machine.vpnDNSOverride(.apply(service: service, expected: servers)), .applied)
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), ["127.0.0.1"])
        XCTAssertEqual(try machine.vpnDNSOverride(.status), .status(VPNDNSOverrideState(serviceID: service, originals: servers)))
        XCTAssertEqual(machine.privilege.vpnDNSOverrideRequests.count, 3)
    }

    func testFakeMachineReleasesBeforeItsRelayStops() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))

        try machine.execute(.stopDNSRelay, values: [])

        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers)
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .released(service: service, reason: .relayStopped, write: .restored))
    }

    func testFakeMachineKeepsTheRecordAcrossARelayRestart() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        try machine.execute(.startDNSRelay, values: ["5054"])
        XCTAssertEqual(try machine.vpnDNSOverride(.status), .status(VPNDNSOverrideState(serviceID: service, originals: servers)))
    }

    func testFakeMachineHooksDriveTheHelpersOwnReleases() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])

        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        machine.vpnDNSProbe.verdict = .refused
        machine.tickVPNDNSOverride()
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), ["127.0.0.1"])
        machine.tickVPNDNSOverride()
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers)

        machine.vpnDNSProbe.verdict = .answered
        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        machine.vpnDNSOverrideOwnerExited()
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .released(service: service, reason: .ownerExited, write: .restored))

        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        machine.restartVPNDNSOverrideHelper()
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers)
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .released(service: service, reason: .helperStart, write: .restored))
        XCTAssertFalse(machine.dnsRelayRunning, "the relay died with the helper")
    }

    func testFakeMachineRunsAndStopsTheTCPRelayWithTheUDPOne() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertTrue(machine.dnsRelayRunning)
        XCTAssertTrue(machine.dnsTCPRelayRunning)
        try machine.execute(.stopDNSRelay, values: [])
        XCTAssertFalse(machine.dnsTCPRelayRunning)
        try machine.execute(.startDNSRelay, values: ["5053"])
        machine.restartVPNDNSOverrideHelper()
        XCTAssertFalse(machine.dnsTCPRelayRunning, "the TCP relay died with the helper")
    }

    func testFakeMachineRefusesTheOverrideWhenTCPCouldNotBind() throws {
        let machine = machine()
        machine.dnsTCPRelayBindFails = true
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertTrue(machine.dnsRelayRunning, "a TCP bind failure leaves UDP serving")
        XCTAssertFalse(machine.dnsTCPRelayRunning)
        XCTAssertEqual(
            try machine.vpnDNSOverride(.apply(service: service, expected: servers)),
            .refused(.relayNotServing)
        )
        XCTAssertEqual(machine.vpnDNSStore.writes, [])

        machine.dnsTCPRelayBindFails = false
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertTrue(machine.dnsTCPRelayRunning)
        XCTAssertEqual(try machine.vpnDNSOverride(.apply(service: service, expected: servers)), .applied)
    }

    func testFakeMachineReleasesWhenTheTCPRelayDiesOrARestartCannotBindIt() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        machine.killDNSTCPRelay()
        machine.tickVPNDNSOverride()
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers)
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .released(service: service, reason: .relayStopped, write: .restored))

        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.apply(service: service, expected: servers))
        machine.dnsTCPRelayBindFails = true
        try machine.execute(.startDNSRelay, values: ["5054"])
        XCTAssertTrue(machine.dnsRelayRunning)
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers)
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .released(service: service, reason: .relayStopped, write: .restored))
    }

    func testTheRelayStatusCarriesTCPAndAnOlderReplyHasNone() throws {
        var reply = HelperResponse.ok()
        reply.dnsRelay = HelperDNSRelayStatus(listening: true, targetPort: 5053, target: .answered, tcpListening: false)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: try JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.dnsRelay?.tcpListening, false)

        let older = Data(#"{"protocolVersion":5,"success":true,"dnsRelay":{"listening":true,"targetPort":5053,"target":"answered"}}"#.utf8)
        let olderStatus = try JSONDecoder().decode(HelperResponse.self, from: older).dnsRelay
        XCTAssertEqual(olderStatus, HelperDNSRelayStatus(listening: true, targetPort: 5053, target: .answered))
        XCTAssertNil(olderStatus?.tcpListening)
    }

    func testFakeMachineAnswersAsAnOlderHelper() throws {
        let machine = machine()
        machine.vpnDNSOverrideSupported = false
        XCTAssertEqual(try machine.vpnDNSOverride(.apply(service: service, expected: servers)), .unsupported)
        XCTAssertEqual(machine.vpnDNSStore.writes, [])
    }

    private struct ClientProbe {
        var client: HelperToolPrivilegeClient
        var fallbackRan: NIOLockedValueBox<Bool>
    }

    private func clientProbe(_ socketPath: String, binaryPath: String = #filePath) -> ClientProbe {
        let fallbackRan = NIOLockedValueBox(false)
        let client = HelperToolPrivilegeClient(
            eventSink: { _ in },
            socketPath: socketPath,
            fallback: AppleScriptPrivilegeClient(runner: { _ in
                fallbackRan.withLockedValue { $0 = true }
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }),
            transactionMilliseconds: 2_000,
            binaryPath: binaryPath
        )
        return ClientProbe(client: client, fallbackRan: fallbackRan)
    }
}
