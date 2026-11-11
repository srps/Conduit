// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class LiveSplitDNSDetectionTests: XCTestCase {
    private let corp = PushedResolver(
        serviceID: "vpn", searchOrder: 1, interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"]
    )
    private let lab = PushedResolver(serviceID: "lab", interface: "utun6", domains: ["lab.example"], servers: ["192.0.2.60"])
    private let corpRow = DetectedSplitDNSDisplay.Row(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])

    private func gate(_ state: VPNObservedState) -> SplitDNSVPNGate {
        var gate = SplitDNSVPNGate()
        _ = gate.update(state)
        return gate
    }

    /// Started, with `.connected` on `utun6` taken.
    private func connected() -> LiveSplitDNSDetection {
        let detection = LiveSplitDNSDetection(limits: .standard)
        detection.start()
        detection.report(gate: gate(.connected), liveInterfaces: ["utun6"])
        _ = detection.take()
        return detection
    }

    func testAWithdrawalRightAfterAResolverHoldsItThoughTheOwnerTookNeither() {
        let detection = connected()

        detection.receive(PushedResolverReading(resolvers: [corp]))
        detection.receive(PushedResolverReading())

        let set = detection.take()?.set
        XCTAssertEqual(set?.display, DetectedSplitDNSDisplay(state: .held, rows: [corpRow]))
        XCTAssertEqual(set?.rules.map(\.domain), ["corp.example"])
        XCTAssertEqual(set?.reason, .pushed)
    }

    func testABurstLeavesOnlyItsNewestSetPending() {
        let detection = connected()

        for _ in 0..<1_000 {
            detection.receive(PushedResolverReading(resolvers: [corp]))
            detection.receive(PushedResolverReading(resolvers: [lab]))
        }

        XCTAssertEqual(detection.take()?.set?.rules.map(\.domain), ["lab.example"])
        XCTAssertNil(detection.take(), "one take empties it")
    }

    func testAReadingThatChangesNothingLeavesNothingPending() {
        let detection = connected()
        detection.receive(PushedResolverReading(resolvers: [corp]))
        _ = detection.take()

        detection.receive(PushedResolverReading(resolvers: [corp]))

        XCTAssertNil(detection.take())
    }

    func testAFailedReadingClearsTheSetAndTheNextGoodOneRestoresIt() {
        let detection = connected()
        detection.receive(PushedResolverReading(resolvers: [corp]))
        _ = detection.take()

        detection.receive(PushedResolverReading(failure: .storeRead))
        let failed = detection.take()
        XCTAssertEqual(failed?.failure, .storeRead)
        XCTAssertEqual(failed?.set, .init(rules: [], display: .init(state: .inUse, rows: []), reason: .detectionFailed))

        detection.report(gate: gate(.connected), liveInterfaces: ["utun6"])
        XCTAssertNil(detection.take(), "a VPN report does not bring back what the failure cleared")

        detection.receive(PushedResolverReading(resolvers: [corp]))
        let restored = detection.take()
        XCTAssertNil(restored?.failure)
        XCTAssertEqual(restored?.set?.display, DetectedSplitDNSDisplay(state: .inUse, rows: [corpRow]))
        XCTAssertEqual(restored?.set?.reason, .pushed)
    }

    func testAFailureIsPendingOnceUntilItChanges() {
        let detection = connected()

        detection.receive(PushedResolverReading(failure: .storeSubscribe))
        detection.receive(PushedResolverReading(failure: .storeSubscribe))
        XCTAssertEqual(detection.take()?.failure, .storeSubscribe)
        detection.receive(PushedResolverReading(failure: .storeSubscribe))
        XCTAssertNil(detection.take())

        detection.receive(PushedResolverReading())
        detection.receive(PushedResolverReading(failure: .storeSubscribe))
        XCTAssertEqual(detection.take()?.failure, .storeSubscribe, "it came back after a reading without it")
    }

    func testAFailureInsideABurstIsStillReported() {
        let detection = connected()

        detection.receive(PushedResolverReading(failure: .storeRead))
        detection.receive(PushedResolverReading(resolvers: [corp]))

        let pending = detection.take()
        XCTAssertEqual(pending?.failure, .storeRead)
        XCTAssertEqual(pending?.set?.display.state, .inUse)
    }

    func testARejectionIsPendingWhenItEntersTheIgnoredSet() {
        let detection = connected()
        let odd = PushedResolverRejection(serviceID: "odd", interface: "utun6", value: "bad domain", reason: .invalidDomain)

        detection.receive(PushedResolverReading(resolvers: [corp], rejections: [odd]))
        XCTAssertEqual(detection.take()?.ignored, [odd])
        detection.receive(PushedResolverReading(resolvers: [lab], rejections: [odd]))
        XCTAssertEqual(detection.take()?.ignored, [], "the set changed and the rejection did not")
    }

    func testStopLeavesTheEmptySetAndDropsALateReading() {
        let detection = connected()
        detection.receive(PushedResolverReading(resolvers: [corp]))

        detection.stop()
        detection.receive(PushedResolverReading(resolvers: [corp]))

        XCTAssertEqual(detection.take()?.set, .init(rules: [], display: .none, reason: .detectionOff))
        XCTAssertNil(detection.take())
    }

    func testAFailureNotYetTakenAtAStopIsStillPendingBesideTheEmptySet() {
        let detection = connected()
        detection.receive(PushedResolverReading(resolvers: [corp]))
        _ = detection.take()

        detection.receive(PushedResolverReading(failure: .storeRead))
        detection.stop()

        let pending = detection.take()
        XCTAssertEqual(pending?.failure, .storeRead)
        XCTAssertEqual(pending?.set, .init(rules: [], display: .none, reason: .detectionOff))
        XCTAssertNil(detection.take(), "it is reported once")

        detection.start()
        detection.receive(PushedResolverReading(failure: .storeRead))
        XCTAssertEqual(detection.take()?.failure, .storeRead, "the next start reports its own failure")
    }

    func testAVerdictTakenWhileStoppedJudgesTheNextStartsFirstReading() {
        let detection = LiveSplitDNSDetection(limits: .standard)
        detection.report(gate: gate(.disconnected(reason: .userInitiated)), liveInterfaces: [])
        XCTAssertNil(detection.take(), "nothing runs, so nothing changed")

        detection.start()
        detection.receive(PushedResolverReading(resolvers: [corp]))

        XCTAssertEqual(detection.take()?.set, .init(
            rules: [], display: .init(state: .idle, rows: [corpRow]), reason: .pushed
        ))
    }
}
