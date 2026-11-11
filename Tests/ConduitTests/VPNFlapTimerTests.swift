// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// `VPNFlapTimer` on named situations. The windows are the defaults: a loss
/// shows after 1 s and becomes a disconnect 5 s after that.
/// `VPNFlapTimerModelCheckTests` covers every ordering.
final class VPNFlapTimerTests: XCTestCase {
    private let window = VPNFlapWindow(minVisible: 1, grace: 5)
    private var timer = VPNFlapTimer()

    private enum Keys {
        /// IPv4 addressed, as a connected VPN tunnel.
        case addressed
        /// The interface is still in the store with no IPv4 address.
        case addressless
    }

    /// A store holding Apple's `utun0` and the given tunnels. A tunnel left
    /// out is not in the store at all.
    private func reading(_ tunnels: [String: Keys] = [:]) -> TunnelReading {
        .snapshot(TunnelSnapshot(tunnels: [.init(interface: "utun0")] + tunnels.map { interface, keys in
            .init(interface: interface, ipv4Addresses: keys == .addressed ? ["192.0.2.10"] : [])
        }))
    }

    private func at(_ now: TimeInterval, _ tunnels: [String: Keys] = [:]) -> VPNDetection {
        timer.reconcile(reading(tunnels), now: now, window: window)
    }

    // MARK: - A fresh session

    func testAFreshSessionReadsAnAddressedTunnelAsConnected() {
        let detection = at(0, ["utun6": .addressed])

        XCTAssertEqual(detection.state, .connected)
        XCTAssertEqual(detection.phase, .up)
        XCTAssertEqual(detection.carrying, ["utun6"])
        XCTAssertEqual(detection.live, ["utun6"])
        XCTAssertNil(detection.deadline)
    }

    func testAFreshSessionWithNoAddressedTunnelIsDisconnectedForNoKnownReason() {
        XCTAssertEqual(at(0).state, .disconnected(reason: .unknown))
        XCTAssertEqual(at(0, ["utun6": .addressless]).state, .disconnected(reason: .unknown),
                       "a tunnel this session never saw addressed is not a flap")
    }

    // MARK: - Flaps

    func testABlipShorterThanMinVisibleStaysConnected() {
        _ = at(0, ["utun6": .addressed])

        let lost = at(10, ["utun6": .addressless])
        XCTAssertEqual(lost.state, .connected)
        XCTAssertEqual(lost.phase, .debouncing)
        XCTAssertEqual(lost.carrying, ["utun6"])
        XCTAssertEqual(lost.deadline, 11)

        let recovered = at(10.5, ["utun6": .addressed])
        XCTAssertEqual(recovered.phase, .up)
        XCTAssertNil(recovered.deadline, "nothing is left to time")
    }

    func testALossPastMinVisibleReassertsAndARecoveryInsideGraceReconnects() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])

        let visible = at(11, ["utun6": .addressless])
        XCTAssertEqual(visible.state, .reasserting)
        XCTAssertEqual(visible.carrying, [])
        XCTAssertEqual(visible.live, ["utun6"], "a flapping tunnel is not gone")
        XCTAssertEqual(visible.deadline, 16)

        XCTAssertEqual(at(13, ["utun6": .addressed]).state, .connected)
    }

    func testALossPastGraceIsANetworkLossAndTheTunnelStaysLive() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        _ = at(11, ["utun6": .addressless])

        let down = at(16, ["utun6": .addressless])
        XCTAssertEqual(down.state, .disconnected(reason: .networkLost))
        XCTAssertEqual(down.live, ["utun6"])
        XCTAssertNil(down.deadline)
    }

    func testEachFlapGetsItsOwnWindows() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        _ = at(12, ["utun6": .addressed])

        XCTAssertEqual(at(20, ["utun6": .addressless]).deadline, 21)
        XCTAssertEqual(at(21, ["utun6": .addressless]).deadline, 26)
    }

    func testMinVisibleOfZeroShowsTheLossAtOnce() {
        let immediate = VPNFlapWindow(minVisible: 0, grace: 5)
        _ = timer.reconcile(reading(["utun6": .addressed]), now: 0, window: immediate)

        let lost = timer.reconcile(reading(["utun6": .addressless]), now: 10, window: immediate)

        XCTAssertEqual(lost.state, .reasserting)
        XCTAssertEqual(lost.deadline, 15)
    }

    // MARK: - A window that changes during a flap

    func testAVerdictThatSettledIsNotReopenedByALongerWindow() {
        _ = at(0, ["utun6": .addressed])
        _ = at(0, ["utun6": .addressless])
        XCTAssertEqual(at(7, ["utun6": .addressless]).state, .disconnected(reason: .networkLost))

        let longerDebounce = timer.reconcile(
            reading(["utun6": .addressless]), now: 8, window: VPNFlapWindow(minVisible: 30, grace: 5)
        )
        XCTAssertEqual(longerDebounce.state, .disconnected(reason: .networkLost),
                       "a debounce that ended at 1 does not start again")
        XCTAssertNil(longerDebounce.deadline)

        let longerGrace = timer.reconcile(
            reading(["utun6": .addressless]), now: 8, window: VPNFlapWindow(minVisible: 1, grace: 3600)
        )
        XCTAssertEqual(longerGrace.state, .disconnected(reason: .networkLost),
                       "a grace that ended at 6 does not start again")
        XCTAssertNil(longerGrace.deadline)
    }

    func testADebounceKeepsTheLengthItStartedWith() {
        _ = at(0, ["utun6": .addressed])
        XCTAssertEqual(at(10, ["utun6": .addressless]).deadline, 11)

        let longer = timer.reconcile(
            reading(["utun6": .addressless]), now: 10.5, window: VPNFlapWindow(minVisible: 30, grace: 5)
        )
        XCTAssertEqual(longer.deadline, 11)
        let shorter = timer.reconcile(
            reading(["utun6": .addressless]), now: 10.6, window: VPNFlapWindow(minVisible: 0, grace: 5)
        )
        XCTAssertEqual(shorter.phase, .debouncing)
        XCTAssertEqual(shorter.deadline, 11)
    }

    func testAGraceKeepsTheLengthItStartedWith() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        XCTAssertEqual(at(11, ["utun6": .addressless]).deadline, 16)

        let longer = timer.reconcile(
            reading(["utun6": .addressless]), now: 12, window: VPNFlapWindow(minVisible: 1, grace: 3600)
        )
        XCTAssertEqual(longer.state, .reasserting)
        XCTAssertEqual(longer.deadline, 16)
        let shorter = timer.reconcile(
            reading(["utun6": .addressless]), now: 13, window: VPNFlapWindow(minVisible: 1, grace: 0)
        )
        XCTAssertEqual(shorter.state, .reasserting, "nor does a shorter one end it early")
        XCTAssertEqual(shorter.deadline, 16)
    }

    func testANewWindowAppliesToThePhaseThatHasNotStarted() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])

        let grace = timer.reconcile(
            reading(["utun6": .addressless]), now: 11, window: VPNFlapWindow(minVisible: 1, grace: 60)
        )
        XCTAssertEqual(grace.deadline, 71, "the grace started at 11, under the new window")

        _ = at(20, ["utun6": .addressed])
        let nextFlap = timer.reconcile(
            reading(["utun6": .addressless]), now: 30, window: VPNFlapWindow(minVisible: 4, grace: 60)
        )
        XCTAssertEqual(nextFlap.deadline, 34, "and so does the next flap's debounce")
    }

    // MARK: - Late and missing wake-ups

    func testALateWakeUpIsJudgedByTheClockNotByHowManyReadingsThereWere() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])

        XCTAssertEqual(at(13, ["utun6": .addressless]).deadline, 16,
                       "grace still runs from the end of the debounce, 11")
        XCTAssertEqual(at(30, ["utun6": .addressless]).state, .disconnected(reason: .networkLost))
    }

    func testAReadingLongAfterTheLossSkipsStraightToDisconnected() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])

        XCTAssertEqual(at(60, ["utun6": .addressless]).state, .disconnected(reason: .networkLost))
    }

    // MARK: - Removal

    func testARemovedTunnelIsAUserDisconnectWithNoWindows() {
        _ = at(0, ["utun6": .addressed])

        let gone = at(10)

        XCTAssertEqual(gone.state, .disconnected(reason: .userInitiated))
        XCTAssertEqual(gone.live, [])
        XCTAssertNil(gone.deadline)
    }

    func testAFlappingTunnelThatIsThenRemovedIsAUserDisconnect() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        XCTAssertEqual(at(10.5).state, .disconnected(reason: .userInitiated), "removed mid-debounce")

        timer = VPNFlapTimer()
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        _ = at(16, ["utun6": .addressless])
        XCTAssertEqual(at(20).state, .disconnected(reason: .userInitiated), "removed after grace ran out")
    }

    func testTheDisconnectReasonDoesNotChangeWhenNothingDoes() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10)

        XCTAssertEqual(at(11).state, .disconnected(reason: .userInitiated))
        XCTAssertEqual(at(12, ["utun6": .addressless]).state, .disconnected(reason: .userInitiated),
                       "the interface coming back with no address is not a new flap")
    }

    func testATunnelOnlyAServiceKeyNamesIsGoneNotFlapping() {
        _ = at(0, ["utun6": .addressed])

        let serviceOnly = TunnelReading.snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun6", hasInterfaceKey: false, serviceID: "com.cisco.anyconnect"),
        ]))

        XCTAssertEqual(timer.reconcile(serviceOnly, now: 10, window: window).state,
                       .disconnected(reason: .userInitiated))
    }

    // MARK: - Several tunnels

    func testAnyAddressedTunnelKeepsTheStateConnected() {
        _ = at(0, ["utun6": .addressed, "utun7": .addressed])

        let one = at(10, ["utun6": .addressless, "utun7": .addressed])
        XCTAssertEqual(one.phase, .up)
        XCTAssertEqual(one.carrying, ["utun6", "utun7"], "utun6 is still inside its debounce")
        XCTAssertEqual(one.deadline, 11, "when utun6 stops carrying")

        let later = at(11, ["utun6": .addressless, "utun7": .addressed])
        XCTAssertEqual(later.carrying, ["utun7"])
        XCTAssertEqual(later.live, ["utun6", "utun7"])
        XCTAssertNil(later.deadline)
    }

    func testGraceRunsFromWhenTheLastTunnelWentNotFromAnOlderLoss() {
        _ = at(0, ["utun6": .addressed, "utun7": .addressed])
        _ = at(10, ["utun6": .addressless, "utun7": .addressed])

        let lastGone = at(30, ["utun6": .addressless])

        XCTAssertEqual(lastGone.state, .reasserting, "utun6 may yet recover")
        XCTAssertEqual(lastGone.deadline, 35)
    }

    // MARK: - Idempotence, blindness, sessions, predicates

    func testTheSameReadingAtTheSameTimeChangesNothing() {
        _ = at(0, ["utun6": .addressed])
        let first = at(10, ["utun6": .addressless])
        let memory = timer

        XCTAssertEqual(at(10, ["utun6": .addressless]), first)
        XCTAssertEqual(timer, memory)
    }

    func testAFailedReadingIsUnknownAndCostsNoMemory() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])
        let memory = timer

        let failure = TunnelReading.Failure(.storeRead, code: 1001)
        let blind = timer.reconcile(.failed(failure), now: 10.5, window: window)

        XCTAssertEqual(blind.phase, .blind(failure))
        XCTAssertEqual(blind.state, .unknown)
        XCTAssertNil(blind.deadline)
        XCTAssertEqual(timer, memory)
        XCTAssertEqual(at(11, ["utun6": .addressless]).state, .reasserting, "the flap carried on by the clock")
    }

    func testANewSessionRemembersNothingOfTheLast() {
        _ = at(0, ["utun6": .addressed])
        _ = at(10, ["utun6": .addressless])

        timer = VPNFlapTimer()

        XCTAssertEqual(at(10.5, ["utun6": .addressless]).state, .disconnected(reason: .unknown),
                       "no debounce is inherited: the store has no addressed tunnel")
        XCTAssertEqual(at(11).state, .disconnected(reason: .unknown))
    }

    func testThePredicateDecidesWhichTunnelsCount() {
        let cisco = VPNUpPredicate { $0.serviceID == "com.cisco.anyconnect" && !$0.ipv4Addresses.isEmpty }
        let other = TunnelSnapshot.Tunnel(interface: "utun4", ipv4Addresses: ["192.0.2.4"], serviceID: "other")
        let vpn = TunnelSnapshot.Tunnel(
            interface: "utun6", ipv4Addresses: ["192.0.2.6"], serviceID: "com.cisco.anyconnect"
        )

        let both = timer.reconcile(.snapshot(TunnelSnapshot(tunnels: [other, vpn])), now: 0, window: window, up: cisco)
        XCTAssertEqual(both.carrying, ["utun6"])

        let onlyOther = timer.reconcile(.snapshot(TunnelSnapshot(tunnels: [other])), now: 10, window: window, up: cisco)
        XCTAssertEqual(onlyOther.state, .disconnected(reason: .userInitiated),
                       "an addressed tunnel the predicate does not count is not the VPN")
    }
}
