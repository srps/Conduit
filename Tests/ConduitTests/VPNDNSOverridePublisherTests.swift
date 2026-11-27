// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import HelperSupport
@testable import PlatformMac

final class VPNDNSOverridePublisherTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private let servers = ["192.0.2.53", "198.51.100.53"]
    private let owner: pid_t = 4_242
    private var key: [String: VPNDNSValue] { VPNDNSOverridePublisher.ownKey(port: HelperConstants.vpnDNSOverrideRelayPort) }

    private final class Rig {
        let store = FakeVPNDNSStore()
        let relay = FakeDNSFailoverRelay()
        var outcomes: [VPNDNSOverrideOutcome] = []
        lazy var publisher = VPNDNSOverridePublisher(store: store, relay: relay) { [unowned self] in outcomes.append($0) }
    }

    private func rig(connected: Bool = true, relay: Bool = true) -> Rig {
        let rig = Rig()
        if connected { rig.store.connectFullTunnel(service, servers: servers) }
        if relay { _ = rig.relay.start(targetPort: 5053) }
        return rig
    }

    private func armed(_ rig: Rig) -> Rig {
        XCTAssertTrue(rig.publisher.arm(service: service, servers: servers, owner: owner))
        return rig
    }

    func testTheKeyIsADomainlessSupplementalResolverAtTheRelay() {
        XCTAssertEqual(key, [
            "ServerAddresses": .strings(["127.0.0.1"]),
            "ServerPort": .number(HelperConstants.vpnDNSOverrideRelayPort),
            "SupplementalMatchDomains": .strings([""]),
            "SupplementalMatchOrders": .numbers([0]),
        ])
    }

    func testAnArmPublishesWhileEverythingHolds() {
        let rig = armed(rig())
        XCTAssertEqual(rig.store.ownKey, key)
        XCTAssertTrue(rig.publisher.published)
        XCTAssertEqual(rig.relay.mode, .conduit)
        XCTAssertEqual(rig.relay.servers, servers)
        XCTAssertEqual(rig.outcomes, [
            .armed(service: service, servers: 2, owner: owner),
            .published(service: service, port: HelperConstants.vpnDNSOverrideRelayPort),
        ])
        XCTAssertEqual(rig.store.vpnKeyWrites, [])
        XCTAssertEqual(rig.publisher.status(caller: owner), HelperVPNDNSOverrideStatus(
            serviceID: service, servers: servers, published: true, owned: true, port: HelperConstants.vpnDNSOverrideRelayPort
        ))
        XCTAssertEqual(rig.publisher.status(caller: 1)?.owned, false)
    }

    func testAnArmOutOfShapeChangesNothing() {
        let rig = rig()
        for (service, servers) in [
            (service, ["127.0.0.1"]), (service, ["0.0.0.0"]), (service, [String]()), ("a/b", servers),
            (HelperConstants.vpnDNSOverrideServiceID, servers), (service, Array(repeating: "192.0.2.1", count: 17)),
        ] {
            XCTAssertFalse(rig.publisher.arm(service: service, servers: servers, owner: owner), "\(service) \(servers)")
        }
        XCTAssertNil(rig.publisher.arm)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.relay.probes, 0)
    }

    func testEachConditionHoldsTheKeyBackWithItsReason() {
        let cases: [(String, VPNDNSOverrideReason, (Rig) -> Void)] = [
            ("no VPN key", .vpnChanged, { $0.store.clientRemove(self.service) }),
            ("other servers", .vpnChanged, { $0.store.clientRewrite(self.service, servers: ["203.0.113.53"]) }),
            ("a split tunnel", .vpnChanged, {
                $0.store.setTunnel(self.service, .init(dns: [
                    "ServerAddresses": .strings(self.servers), "SupplementalMatchDomains": .strings(["corp.example"]),
                ]))
            }),
            ("not overriding primary", .vpnChanged, {
                $0.store.setTunnel(self.service, .init(dns: ["ServerAddresses": .strings(self.servers)], overridePrimary: false))
            }),
            ("IPv4 withdrawn", .vpnChanged, {
                $0.store.setTunnel(self.service, .init(dns: ["ServerAddresses": .strings(self.servers)], ipv4: false))
            }),
            ("not primary", .vpnChanged, { $0.store.primary = "en0" }),
            ("relay without TCP", .relayStopped, { $0.relay.killTCP() }),
        ]
        for (name, reason, change) in cases {
            let rig = armed(rig())
            change(rig)
            rig.publisher.sync()
            XCTAssertNil(rig.store.ownKey, name)
            XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: reason), name)
            XCTAssertEqual(rig.publisher.status(caller: owner)?.reason, reason.rawValue, name)
            XCTAssertNotNil(rig.publisher.arm, "\(name): the arm is kept")
        }
    }

    func testAKeyAlreadyMatchingAfterAnEmptyEntryIsKept() {
        let rig = rig()
        rig.store.setTunnel(service, .init(dns: [
            "ServerAddresses": .strings(servers), "SupplementalMatchDomains": .strings([]),
        ]))
        _ = armed(rig)
        XCTAssertEqual(rig.store.ownKey, key, "an empty SupplementalMatchDomains is no split tunnel")
    }

    func testLoopbackInTheVPNsKeyIsNeverAFailoverTarget() {
        let rig = rig()
        rig.store.connectFullTunnel(service, servers: servers + ["127.0.0.1", "::", servers[0]])
        XCTAssertTrue(rig.publisher.arm(service: service, servers: servers, owner: owner))
        XCTAssertEqual(rig.relay.servers, servers)
        XCTAssertEqual(rig.store.ownKey, key, "the usable servers match the arm")

        rig.store.clientRewrite(service, servers: ["127.0.0.1", "0.0.0.0"])
        rig.publisher.sync()
        XCTAssertEqual(rig.relay.servers, [])
        XCTAssertNil(rig.store.ownKey, "with no failover target the key goes")
    }

    func testTheKeyComesBackOnceTheVPNRepublishes() {
        let rig = armed(rig())
        rig.store.setTunnel(service, .init(dns: ["ServerAddresses": .strings(servers)], ipv4: false))
        rig.publisher.sync()
        XCTAssertNil(rig.store.ownKey)
        rig.store.connectFullTunnel(service, servers: servers)
        rig.publisher.sync()
        XCTAssertEqual(rig.store.ownKey, key)
    }

    func testAConfigdRestartIsAnsweredByOneRepublish() {
        let rig = armed(rig())
        rig.store.configdRestart()
        XCTAssertNil(rig.store.ownKey)
        rig.publisher.sync()
        XCTAssertEqual(rig.store.ownKey, key)
        XCTAssertEqual(rig.outcomes.filter { if case .published = $0 { true } else { false } }.count, 2)
        rig.publisher.sync()
        XCTAssertEqual(rig.outcomes.filter { if case .published = $0 { true } else { false } }.count, 2, "a present key is not written again")
    }

    func testARemovalTheStoreRefusesClosesTheSession() {
        let rig = armed(rig())
        rig.store.failsRemove = true
        rig.publisher.disarm(.disarmed)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.store.sessionsClosed, 1)
        XCTAssertEqual(Array(rig.outcomes.suffix(2)), [
            .removalRefused(service: service), .withdrawn(service: service, reason: .disarmed),
        ])
    }

    func testAFailedReadDuringStopStillRemovesThePublishedKey() {
        let rig = armed(rig())
        rig.store.failsRead = true
        rig.publisher.disarm(.relayStopped)
        XCTAssertNil(rig.store.ownKey, "a failed read is not absence")
        XCTAssertFalse(rig.publisher.cleanupPending)
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .relayStopped))
    }

    func testARefusedRemovalNobodyCanConfirmStaysPendingUntilAReadShowsTheKeyGone() {
        let rig = armed(rig())
        rig.store.failsRead = true
        rig.store.failsRemove = true
        rig.publisher.disarm(.relayStopped)
        XCTAssertEqual(rig.store.sessionsClosed, 1)
        XCTAssertTrue(rig.publisher.cleanupPending)
        XCTAssertTrue(rig.publisher.wantsTicks, "the pending cleanup keeps the ticks going without an arm")
        XCTAssertEqual(Array(rig.outcomes.suffix(2)), [
            .removalRefused(service: service), .cleanupPending(service: service, reason: .relayStopped),
        ])
        XCTAssertFalse(rig.outcomes.contains(.withdrawn(service: service, reason: .relayStopped)), "not reported withdrawn")

        rig.publisher.tick()
        XCTAssertTrue(rig.publisher.cleanupPending)
        XCTAssertEqual(rig.outcomes.filter { $0 == .removalRefused(service: service) }.count, 1, "reported once")

        rig.store.failsRead = false
        rig.publisher.tick()
        XCTAssertFalse(rig.publisher.cleanupPending)
        XCTAssertFalse(rig.publisher.wantsTicks)
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .relayStopped))
    }

    func testAKeyAClosedSessionStillHoldsIsRemovedOnTheNextTickAndNothingIsPublishedMeanwhile() {
        let rig = armed(rig())
        rig.store.failsRemove = true
        rig.store.closeLeavesKey = true
        rig.publisher.disarm(.disarmed)
        XCTAssertTrue(rig.publisher.cleanupPending)
        XCTAssertNotNil(rig.store.ownKey)
        XCTAssertTrue(rig.publisher.arm(service: service, servers: servers, owner: owner))
        XCTAssertFalse(rig.publisher.published, "no publish over a key awaiting cleanup")
        rig.store.failsRemove = false
        rig.publisher.tick()
        XCTAssertFalse(rig.publisher.cleanupPending)
        XCTAssertTrue(rig.publisher.published, "the arm publishes once the old key is gone")
    }

    func testAPublishTheStoreRefusesIsReportedAndRetriedOnTheNextSync() {
        let rig = rig()
        rig.store.failsPublish = true
        _ = armed(rig)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.outcomes.last, .publishFailed(service: service))
        XCTAssertTrue(rig.outcomes.last!.isFailure)
        XCTAssertEqual(rig.publisher.status(caller: owner)?.reason, "publish_failed")
        rig.store.failsPublish = false
        rig.publisher.sync()
        XCTAssertEqual(rig.store.ownKey, key)
    }

    func testTheOwnersExitWithdrawsAndLeavesTheRelayOnTheVPN() {
        let rig = armed(rig())
        rig.publisher.ownerExited(owner + 1)
        XCTAssertNotNil(rig.store.ownKey, "another pid's exit changes nothing")
        rig.publisher.ownerExited(owner)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertNil(rig.publisher.arm)
        XCTAssertEqual(rig.relay.mode, .vpn)
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .ownerExited))
        XCTAssertEqual(rig.relay.servers, servers, "the relay keeps the VPN's servers to fail over to")
    }

    func testTwoRefusedTicksWithdrawAndAnAnswerBringsItBack() {
        let rig = armed(rig())
        rig.relay.verdict = .refused
        rig.publisher.tick()
        XCTAssertEqual(rig.store.ownKey, key, "one refusal keeps the key")
        XCTAssertEqual(rig.relay.mode, .vpn, "but the relay fails over at once")
        rig.publisher.tick()
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .targetRefused))
        rig.relay.verdict = .answered
        rig.publisher.tick()
        XCTAssertEqual(rig.store.ownKey, key)
        XCTAssertEqual(rig.relay.mode, .conduit)
    }

    func testThreeSilentTicksWithdrawAndAMixedStreakDoesNot() {
        let rig = armed(rig())
        rig.relay.verdict = .silent
        rig.publisher.tick()
        rig.publisher.tick()
        rig.relay.verdict = .refused
        rig.publisher.tick()
        XCTAssertEqual(rig.store.ownKey, key, "a refusal resets the silent streak")
        rig.relay.verdict = .silent
        for _ in 0..<3 { rig.publisher.tick() }
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .targetSilent))
    }

    func testAFailedProbeSocketSaysNothingAboutConduit() {
        let rig = armed(rig())
        rig.relay.verdict = .failed("socket")
        for _ in 0..<5 { rig.publisher.tick() }
        XCTAssertEqual(rig.store.ownKey, key)
        XCTAssertEqual(rig.relay.mode, .conduit)
    }

    func testAnArmWhoseProbeFailsWaitsForAnAnsweredTick() {
        let rig = rig()
        rig.relay.verdict = .refused
        _ = armed(rig)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertEqual(rig.publisher.status(caller: owner)?.reason, "target_refused")
        rig.relay.verdict = .answered
        rig.publisher.tick()
        XCTAssertEqual(rig.store.ownKey, key)
    }

    func testARelayStartedByAnotherCallerFailsOverUntilAProbeAnswers() {
        let rig = armed(rig())
        rig.publisher.relayStarted(caller: owner + 1)
        XCTAssertEqual(rig.relay.mode, .vpn)
        rig.publisher.relayStarted(caller: owner)
        XCTAssertEqual(rig.relay.mode, .conduit)
        rig.publisher.relayRestarted()
        XCTAssertEqual(rig.relay.mode, .vpn, "a relay that came back while armed waits for the next probe")
    }

    func testDisarmAndRelayStopWithdraw() {
        let rig = armed(rig())
        rig.relay.stop()
        rig.publisher.disarm(.relayStopped)
        XCTAssertNil(rig.store.ownKey)
        XCTAssertNil(rig.publisher.arm)
        XCTAssertNil(rig.publisher.status(caller: owner))
        XCTAssertEqual(rig.outcomes.last, .withdrawn(service: service, reason: .relayStopped))
        let count = rig.outcomes.count
        rig.publisher.disarm(.disarmed)
        XCTAssertEqual(rig.outcomes.count, count, "nothing published, nothing withdrawn")
    }

    func testAKeyLeftInTheSessionWithoutAnArmIsRemoved() {
        let rig = rig()
        _ = rig.store.publishOwnKey(key)
        rig.publisher.sync()
        XCTAssertNil(rig.store.ownKey)
    }

    func testOutcomeLinesNameNoServerAddress() {
        let rig = armed(rig())
        rig.relay.verdict = .silent
        for _ in 0..<3 { rig.publisher.tick() }
        rig.store.failsRemove = true
        _ = rig.store.publishOwnKey(key)
        rig.publisher.disarm(.disarmed)
        for outcome in rig.outcomes {
            XCTAssertFalse(outcome.logLine.contains("192.0.2"), outcome.logLine)
            XCTAssertTrue(outcome.logLine.hasPrefix("vpn-dns-override "), outcome.logLine)
        }
    }

    func testFailoverServersFilterAndDedupe() {
        XCTAssertEqual(
            VPNDNSOverrideValidation.failoverServers(["192.0.2.53", "127.0.0.1", "::1", "0.0.0.0", "::", "192.0.2.53", "2001:db8::53", "x"]),
            ["192.0.2.53", "2001:db8::53"]
        )
        for address in ["0.0.0.0", "::", "127.0.0.1", "127.255.0.1", "::1", "::ffff:127.0.0.1"] {
            XCTAssertFalse(VPNDNSOverrideValidation.isTunnelServer(address), address)
        }
    }
}
