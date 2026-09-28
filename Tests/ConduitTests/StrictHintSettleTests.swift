// SPDX-License-Identifier: Apache-2.0
// The strict-mode hint (#87) is not probed while routing is changing under
// the proxy: a VPN transition settling, a flap hold, direct mode (#97).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class StrictHintSettleTests: XCTestCase {

    private let window: TimeInterval = 20

    private struct Harness {
        let clock: NIOLockedValueBox<Date>
        let transitions: RoutingTransitionSignal
        let detector: DirectConnectDetector
        let resolver: ProbeResolver
        let events: NIOLockedValueBox<[RuntimeEvent]>

        func advance(_ seconds: TimeInterval) {
            clock.withLockedValue { $0 += seconds }
        }

        var suppressed: [RuntimeEvent] {
            events.withLockedValue { $0 }.filter { $0.event == "routing.strict_direct_reachable_suppressed" }
        }

        func probe(_ host: String = "app.invalid", cause: DirectModeCause = .none) -> DirectConnectDetector.StrictHintProbe {
            detector.probeForStrictModeHint(host: host, port: 443, gatewayMode: false, directModeCause: cause) {}
        }
    }

    private func harness() -> Harness {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let now: @Sendable () -> Date = { clock.withLockedValue { $0 } }
        let transitions = RoutingTransitionSignal(now: now)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let resolver = ProbeResolver(.noAddresses)
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            now: now,
            routingTransitions: transitions,
            strictHintSettleWindow: window,
            resolver: { host, port, loop in resolver.resolve(host: host, port: port, on: loop) },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        return Harness(clock: clock, transitions: transitions, detector: detector, resolver: resolver, events: events)
    }

    func testFailureInsideTheSettleWindowIsNotProbedAndIsReported() {
        let h = harness()
        h.transitions.mark()
        h.advance(window - 1)
        XCTAssertEqual(h.probe(), .suppressed(.vpnTransition))
        XCTAssertEqual(h.detector.probeCount, 0, "probed while a VPN transition was settling")
        XCTAssertEqual(h.resolver.lookups, 0)
        XCTAssertEqual(h.suppressed.map(\.detail), ["reason=vpn_transition host=app.invalid port=443 suppressed=1"])
        XCTAssertEqual(h.suppressed.first?.kind, .routing)
        XCTAssertEqual(h.detector.strictHintTableCount, 0, "a suppressed hint started the host's cooldown")
    }

    func testFailureAfterTheSettleWindowStillProbes() {
        let h = harness()
        h.transitions.mark()
        h.advance(window)
        XCTAssertEqual(h.probe(), .started)
        XCTAssertEqual(h.detector.probeCount, 1)
        XCTAssertTrue(h.suppressed.isEmpty)
    }

    /// A host suppressed during the window is probed on its first failure
    /// after it: suppression must not put it on cooldown.
    func testHostSuppressedInTheWindowIsProbedAfterIt() {
        let h = harness()
        h.transitions.mark()
        XCTAssertEqual(h.probe(), .suppressed(.vpnTransition))
        h.advance(window)
        XCTAssertEqual(h.probe(), .started)
    }

    /// A transition being handled (the reprobe after a VPN connect can take
    /// seconds) counts as settling, whenever the previous one finished; the
    /// window runs from when it ends.
    func testTransitionInFlightSuppressesAndTheWindowRunsFromItsEnd() {
        let h = harness()
        XCTAssertEqual(h.probe("before.invalid"), .started, "no transition yet: nothing to suppress")
        h.transitions.begin()
        h.advance(window * 3)
        XCTAssertEqual(h.probe(), .suppressed(.vpnTransition))
        h.transitions.end()
        h.advance(window - 1)
        XCTAssertEqual(h.probe(), .suppressed(.vpnTransition))
        h.advance(1)
        XCTAssertEqual(h.probe(), .started)
    }

    func testFlapHoldAndDirectModeAreSuppressedWithTheirOwnReason() {
        let h = harness()
        XCTAssertEqual(h.probe(cause: .transientNetworkChange), .suppressed(.flap))
        for cause: DirectModeCause in [.upstreamsUnreachable, .vpnDisconnected, .noUpstreamsConfigured] {
            XCTAssertEqual(h.probe(cause: cause), .suppressed(.directMode), "\(cause)")
        }
        XCTAssertEqual(h.detector.probeCount, 0)
        XCTAssertEqual(h.suppressed.map(\.detail), [
            "reason=flap host=app.invalid port=443 suppressed=1",
            "reason=direct_mode host=app.invalid port=443 suppressed=1",
        ], "one event per reason, not one per failure")
        // Out of the flap, outside any window: probed.
        XCTAssertEqual(h.probe(), .started)
    }

    /// A burst of failures during one transition makes one event; a long
    /// suppression repeats it at most once per report interval with the
    /// count since the last one, and a new transition reports again.
    func testSuppressionEventsAreCoalesced() {
        let h = harness()
        h.transitions.begin()
        for index in 0..<50 {
            XCTAssertEqual(h.probe("h\(index).invalid"), .suppressed(.vpnTransition))
        }
        XCTAssertEqual(h.suppressed.count, 1, "a burst flooded the event log")

        h.advance(DirectConnectDetector.strictHintSuppressedReportInterval)
        XCTAssertEqual(h.probe("late.invalid"), .suppressed(.vpnTransition))
        XCTAssertEqual(h.suppressed.last?.detail, "reason=vpn_transition host=late.invalid port=443 suppressed=50",
                       "49 coalesced failures plus this one")

        h.transitions.end()
        XCTAssertEqual(h.probe("next.invalid"), .suppressed(.vpnTransition))
        XCTAssertEqual(h.suppressed.count, 3, "a new transition is reported")
        XCTAssertEqual(h.suppressed.last?.detail, "reason=vpn_transition host=next.invalid port=443 suppressed=1")
    }

    /// Without a signal (tools and tests that run no orchestrator) nothing
    /// settles, as before #97.
    func testNoSignalNeverSuppressesForATransition() {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            resolver: { _, _, loop in loop.makeSucceededFuture([]) }
        )
        XCTAssertEqual(detector.probeForStrictModeHint(host: "app.invalid", port: 443, gatewayMode: false) {}, .started)
    }
}
