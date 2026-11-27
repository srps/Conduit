// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ConduitShared
@testable import HelperSupport
@testable import PlatformMac
@testable import ProxyKernel

final class HelperVPNDNSOverrideTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private let servers = ["192.0.2.53", "198.51.100.53"]

    private func status(published: Bool = true, reason: String? = nil, owned: Bool = true, port: Int? = 15353) -> HelperVPNDNSOverrideStatus {
        HelperVPNDNSOverrideStatus(
            serviceID: service, servers: servers, published: published, reason: reason, owned: owned, port: published ? port : nil
        )
    }

    func testTheStatusRoundTrips() throws {
        var reply = HelperResponse.ok()
        reply.vpnDNSOverride = status(published: false, reason: "target_silent", owned: false)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: try JSONEncoder().encode(reply))
        XCTAssertEqual(decoded, reply)
    }

    func testAnOlderHelpersReplyHasNoOverrideFields() throws {
        let older = Data(#"{"protocolVersion":5,"success":true,"features":["dns-relay-status","vpn-dns-override"]}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: older)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.vpnDNSOverride)
        XCTAssertEqual(decoded.features, [.dnsRelayStatus], "the rewrite helper's feature is not this one")
    }

    func testARewriteHelpersStatusIsDroppedNotABrokenFrame() throws {
        let rewrite = Data(#"{"protocolVersion":5,"success":true,"vpnDNSOverride":{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53"]}}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: rewrite)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.vpnDNSOverride)
    }

    func testTheCommandsFeatureAndKeyKeepTheirWireNames() {
        XCTAssertEqual(HelperCommand.vpnDNSOverrideArm.rawValue, "vpn-dns-override-arm")
        XCTAssertEqual(HelperCommand.vpnDNSOverrideDisarm.rawValue, "vpn-dns-override-disarm")
        XCTAssertEqual(HelperCommand.vpnDNSOverrideStatus.rawValue, "vpn-dns-override-status")
        XCTAssertEqual(HelperFeature.vpnDNSOverride.rawValue, "vpn-dns-override-key")
        XCTAssertEqual(HelperConstants.vpnDNSOverrideServiceID, "io.github.srps.Conduit.dns-relay")
        XCTAssertNil(UUID(uuidString: HelperConstants.vpnDNSOverrideServiceID))
        XCTAssertFalse([53, 5353].contains(HelperConstants.vpnDNSOverrideRelayPort))
        XCTAssertEqual(HelperProtocolVersion.current, 5)
    }

    func testDisarmAndStatusAreTeardownOnlyAndArmIsNot() {
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.vpnDNSOverrideDisarm))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.vpnDNSOverrideStatus))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.vpnDNSOverrideArm))
        for command in [HelperCommand.vpnDNSOverrideDisarm, .vpnDNSOverrideStatus] {
            XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501, command: command), command.rawValue)
        }
        XCTAssertEqual(
            HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501, command: .vpnDNSOverrideArm, values: [service] + servers),
            .noConsoleUser
        )
        XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 501, lastConsoleUID: 501, command: .vpnDNSOverrideArm, values: [service] + servers))
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 502, consoleUID: 501, lastConsoleUID: 501, command: .vpnDNSOverrideDisarm), .unauthorized)
    }

    func testAHelperWithoutTheFeatureIsUnsupportedWithoutAPrompt() throws {
        var older = HelperResponse.ok()
        older.features = [.dnsRelayStatus]
        for request in [VPNDNSOverrideRequest.arm(service: service, servers: servers), .disarm, .status] {
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
        XCTAssertEqual(try clientProbe(helper.path).client.vpnDNSOverride(.disarm), .unsupported)
    }

    func testAnArmCarriesTheServiceAndServers() throws {
        let helper = try FakeHelper(replies: [.ok(), .ok()])
        defer { helper.stop() }
        let client = clientProbe(helper.path).client

        XCTAssertEqual(try client.vpnDNSOverride(.arm(service: service, servers: servers)), .armed)
        XCTAssertEqual(try client.vpnDNSOverride(.disarm), .disarmed)
        XCTAssertEqual(helper.commandsSeen, [.vpnDNSOverrideArm, .vpnDNSOverrideDisarm])
        XCTAssertEqual(helper.valuesSeen, [[service] + servers, []])
    }

    func testStatusMapsTheReply() throws {
        var held = HelperResponse.ok()
        held.vpnDNSOverride = status()
        var withheld = HelperResponse.ok()
        withheld.vpnDNSOverride = status(published: false, reason: "vpn_changed", owned: false)
        var later = HelperResponse.ok()
        later.vpnDNSOverride = status(published: false, reason: "a_reason_from_later")
        var badPort = HelperResponse.ok()
        badPort.vpnDNSOverride = status(port: 70_000)
        let helper = try FakeHelper(replies: [held, withheld, later, badPort, .ok()])
        defer { helper.stop() }
        let client = clientProbe(helper.path).client

        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(VPNDNSOverrideState(
            serviceID: service, servers: servers, published: true, owned: true, port: 15353
        )))
        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(VPNDNSOverrideState(
            serviceID: service, servers: servers, published: false, reason: "vpn_changed", owned: false
        )))
        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(VPNDNSOverrideState(
            serviceID: service, servers: servers, published: false, reason: "unknown", owned: true
        )))
        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(VPNDNSOverrideState(
            serviceID: service, servers: servers, published: true, owned: true, port: nil
        )))
        XCTAssertEqual(try client.vpnDNSOverride(.status), .status(nil))
    }

    func testAStatusOutOfShapeIsAnError() throws {
        for servers in [["127.0.0.1"], ["0.0.0.0"], []] {
            var held = HelperResponse.ok()
            held.vpnDNSOverride = HelperVPNDNSOverrideStatus(serviceID: service, servers: servers, published: true, owned: true)
            let helper = try FakeHelper(replies: [held])
            defer { helper.stop() }
            XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.status), "\(servers)")
        }
    }

    func testAFailureFromAHelperWithTheFeatureThrows() throws {
        var current = HelperResponse.ok()
        current.features = HelperFeature.allCases
        let helper = try FakeHelper(replies: [.error("Invalid VPN DNS override"), current])
        defer { helper.stop() }
        XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.arm(service: service, servers: servers))) { error in
            guard case .executionFailed? = error as? PrivilegeClientError else { return XCTFail("got \(error)") }
        }
    }

    func testARefusalAndAnUnreachableHelperThrow() throws {
        let helper = try FakeHelper(replies: [.refused(.noConsoleUser, "no console user yet")])
        defer { helper.stop() }
        XCTAssertThrowsError(try clientProbe(helper.path).client.vpnDNSOverride(.arm(service: service, servers: servers))) { error in
            guard case .refused(.noConsoleUser, _)? = error as? PrivilegeClientError else { return XCTFail("got \(error)") }
        }
        let missing = clientProbe("/tmp/pm-no-helper-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try missing.client.vpnDNSOverride(.status)) { error in
            XCTAssertEqual((error as? PrivilegeClientError)?.isHelperUnreachable, true)
        }
        XCTAssertFalse(missing.fallbackRan.withLockedValue { $0 })
    }

    func testAnArmTheHelperWouldRefuseIsNeverSent() throws {
        let helper = try FakeHelper(replies: [.ok()])
        defer { helper.stop() }
        let client = clientProbe(helper.path).client
        let refused: [(String, [String])] = [
            (service, ["127.0.0.1"]), (service, ["::"]), (service, []), ("a/b", servers),
            (service, Array(repeating: "192.0.2.1", count: 17)),
        ]
        for (service, servers) in refused {
            XCTAssertThrowsError(try client.vpnDNSOverride(.arm(service: service, servers: servers)), "\(service) \(servers)")
        }
        XCTAssertEqual(helper.requestsSeen, 0)
    }

    func testAPingWithoutTheKeyFeatureReadsAsUpdateAvailable() throws {
        let rewrite = try JSONDecoder().decode(
            HelperResponse.self, from: Data(#"{"protocolVersion":5,"success":true,"features":["dns-relay-status","vpn-dns-override"]}"#.utf8)
        )
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: rewrite), .updateAvailable)
        var current = HelperResponse.ok()
        current.features = HelperFeature.allCases
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: current), .installed)
    }

    func testTheAuditingClientAndTheRecorderPassTheRequestThrough() throws {
        let base = RecordingPrivilegeClient()
        XCTAssertEqual(try base.vpnDNSOverride(.status), .unsupported, "the recorder answers as an older helper by default")
        base.vpnDNSOverrideReply = .armed
        let audited = AuditingPrivilegeClient(base: base, eventSink: { _ in })
        XCTAssertEqual(try audited.vpnDNSOverride(.arm(service: service, servers: servers)), .armed)
        XCTAssertEqual(base.vpnDNSOverrideRequests, [.status, .arm(service: service, servers: servers)])
        XCTAssertEqual(try AppleScriptPrivilegeClient(runner: { _ in CommandResult(exitCode: 0, standardOutput: "", standardError: "") }).vpnDNSOverride(.status), .unsupported)
    }

    private func machine() -> FakeMachine {
        let machine = FakeMachine(resolverDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pm-vpn-override-\(UUID().uuidString.prefix(8))"))
        machine.vpnDNSStore.connectFullTunnel(service, servers: servers)
        return machine
    }

    func testFakeMachinePublishesOnlyWhileItsRelayRuns() throws {
        let machine = machine()
        XCTAssertEqual(try machine.vpnDNSOverride(.arm(service: service, servers: servers)), .armed)
        XCTAssertNil(machine.vpnDNSStore.ownKey)
        XCTAssertEqual(try machine.vpnDNSOverride(.status), .status(VPNDNSOverrideState(
            serviceID: service, servers: servers, published: false, reason: "relay_stopped", owned: true
        )))
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertNil(machine.vpnDNSStore.ownKey, "the probe at the arm found no relay; the next tick's probe decides")
        machine.tickVPNDNSOverride()
        XCTAssertEqual(machine.vpnDNSStore.ownKey, VPNDNSOverridePublisher.ownKey(port: HelperConstants.vpnDNSOverrideRelayPort))
        XCTAssertEqual(machine.vpnDNSStore.serverAddresses(service), servers, "the VPN's key is never written")
        XCTAssertEqual(machine.fakeFailoverRelay?.servers, servers)
    }

    func testFakeMachineWithdrawsBeforeItsRelayStops() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        try machine.execute(.stopDNSRelay, values: [])
        XCTAssertNil(machine.vpnDNSStore.ownKey)
        XCTAssertEqual(machine.vpnDNSOverrideOutcomes.last, .withdrawn(service: service, reason: .relayStopped))
        XCTAssertNil(machine.vpnDNSOverrideArm)
    }

    func testFakeMachineKeepsTheFailoverRelayWhileTheKeysCleanupIsPending() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        XCTAssertNotNil(machine.vpnDNSStore.ownKey)
        machine.vpnDNSStore.failsRemove = true
        machine.vpnDNSStore.closeLeavesKey = true
        try machine.execute(.stopDNSRelay, values: [])
        XCTAssertNotNil(machine.vpnDNSStore.ownKey)
        XCTAssertNotNil(machine.vpnDNSRelay.listeningPort, "the key still names the relay, so the relay answers")
        XCTAssertEqual(machine.vpnDNSRelay.mode, .vpn)
        machine.vpnDNSStore.failsRemove = false
        machine.tickVPNDNSOverride()
        XCTAssertNil(machine.vpnDNSStore.ownKey)
        XCTAssertNil(machine.vpnDNSRelay.listeningPort, "stopped once the key is gone")
    }

    func testAnArmDuringADeferredStopPublishesNothingOverTheRelayItStops() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.vpnDNSStore.failsRemove = true
        machine.vpnDNSStore.closeLeavesKey = true
        try machine.execute(.stopDNSRelay, values: [])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.vpnDNSStore.failsRemove = false
        machine.tickVPNDNSOverride()
        XCTAssertNil(machine.vpnDNSRelay.listeningPort, "the stop the cleanup held back has run")
        XCTAssertNil(machine.vpnDNSStore.ownKey, "and no key names the relay it stopped")

        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertNotNil(machine.vpnDNSStore.ownKey, "a Start brings the relay and the key back")
    }

    func testAStartSupersedesADeferredStop() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.vpnDNSStore.failsRemove = true
        machine.vpnDNSStore.closeLeavesKey = true
        try machine.execute(.stopDNSRelay, values: [])
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.vpnDNSStore.failsRemove = false
        machine.tickVPNDNSOverride()
        XCTAssertNotNil(machine.vpnDNSRelay.listeningPort, "the new Start keeps the relay")
        XCTAssertNotNil(machine.vpnDNSStore.ownKey, "and the key is published once the old one is gone")
    }

    func testFakeMachineAnswersStatusForTheCallerThatArmed() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.callerPID = 9_999
        guard case .status(let state?) = try machine.vpnDNSOverride(.status) else { return XCTFail("no status") }
        XCTAssertFalse(state.owned, "a relaunched app is not the owner")
    }

    func testFakeMachineHooksDriveTheHelpersOwnWithdrawals() throws {
        let machine = machine()
        try machine.execute(.startDNSRelay, values: ["5053"])
        let relay = try XCTUnwrap(machine.fakeFailoverRelay)

        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        relay.verdict = .refused
        machine.tickVPNDNSOverride()
        XCTAssertNotNil(machine.vpnDNSStore.ownKey)
        XCTAssertEqual(relay.mode, .vpn)
        machine.tickVPNDNSOverride()
        XCTAssertNil(machine.vpnDNSStore.ownKey)
        relay.verdict = .answered
        machine.tickVPNDNSOverride()
        XCTAssertNotNil(machine.vpnDNSStore.ownKey)
        XCTAssertEqual(relay.mode, .conduit)

        machine.vpnDNSOverrideOwnerExited()
        XCTAssertNil(machine.vpnDNSStore.ownKey)
        XCTAssertEqual(relay.mode, .vpn)

        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        machine.killVPNDNSOverrideHelper()
        XCTAssertNil(machine.vpnDNSStore.ownKey, "configd removes the dead session's key")
        XCTAssertNil(machine.vpnDNSOverrideArm)
        XCTAssertFalse(machine.dnsRelayRunning, "the relays died with the helper")
    }

    func testFakeMachineHoldsTheKeyBackWhenTCPCouldNotBind() throws {
        let machine = machine()
        machine.dnsTCPRelayBindFails = true
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertTrue(machine.dnsRelayRunning, "a TCP bind failure leaves UDP serving")
        XCTAssertFalse(machine.dnsTCPRelayRunning)
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        XCTAssertNil(machine.vpnDNSStore.ownKey)

        machine.dnsTCPRelayBindFails = false
        try machine.execute(.startDNSRelay, values: ["5053"])
        XCTAssertNil(machine.vpnDNSStore.ownKey, "the arm's probe found no TCP half to ask through")
        machine.tickVPNDNSOverride()
        XCTAssertNotNil(machine.vpnDNSStore.ownKey)
        machine.killDNSTCPRelay()
        machine.syncVPNDNSOverride()
        XCTAssertNil(machine.vpnDNSStore.ownKey)
    }

    func testFakeMachineAnswersScutilFromTheOwnKey() throws {
        let machine = machine()
        let order = ScutilResolverOrder(run: { try machine.run($0, $1) })
        XCTAssertEqual(order.firstResolver(), .success(FirstResolver(nameserver: servers[0], port: nil)))
        try machine.execute(.startDNSRelay, values: ["5053"])
        _ = try machine.vpnDNSOverride(.arm(service: service, servers: servers))
        XCTAssertEqual(order.firstResolver(), .success(FirstResolver(nameserver: "127.0.0.1", port: HelperConstants.vpnDNSOverrideRelayPort)))
        machine.resolverOrderIgnoresOwnKey = true
        XCTAssertEqual(order.firstResolver(), .success(FirstResolver(nameserver: servers[0], port: nil)))
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
        XCTAssertEqual(try machine.vpnDNSOverride(.arm(service: service, servers: servers)), .unsupported)
        XCTAssertNil(machine.vpnDNSOverrideArm)
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
