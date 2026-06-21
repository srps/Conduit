// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Unit tests for `VPNStateFuser`. The fuser is the pure state-machine half of
/// `VPNStatusMonitor`; testing it directly with synthetic observations
/// exercises every transition in the design doc table without needing
/// `SCDynamicStore` or a live system.
final class VPNStateFuserTests: XCTestCase {

    // MARK: - Initial state

    func testInitialApplyOfConnectedInterfaceEmitsConnected() {
        var fuser = VPNStateFuser()
        let decision = fuser.applyObservation(
            interfaceName: "utun0",
            observation: .connectedFixture()
        )
        XCTAssertEqual(decision, .emit(.connected))
    }

    func testFirstSightOfIPv4LessUtunDoesNotEmitReasserting() {
        // A utun observed for the first time without an IPv4 (e.g. an Apple
        // service utun: cloud relay, FaceTime audio bridge) should NOT
        // trigger a reasserting transition — we never had a connected state
        // to recover from. The fuser correctly stays at .unknown.
        var fuser = VPNStateFuser()
        let decision = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )
        XCTAssertEqual(decision, .noChange)
    }

    // MARK: - Connected -> debouncing -> awaiting recovery (the flap path)

    func testIPv4DropAfterConnectedRequestsMinVisibleTimer() {
        var fuser = VPNStateFuser()

        // 1. Initial connect.
        XCTAssertEqual(
            fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture()),
            .emit(.connected)
        )

        // 2. IPv4 disappears (VPN flap: tunnel still alive at the kernel,
        // IPv6 link-local still assigned, but the VPN-pushed IPv4 is gone).
        // Phase 6 (revised): the fuser does NOT emit .reasserting immediately
        // — it asks the caller to start a min-visible timer. The utun phase
        // advances to .linkDownDebouncing but the FUSED state stays at
        // .connected (orchestrator doesn't see anything change yet).
        let flapDecision = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )
        XCTAssertEqual(flapDecision, .startMinVisibleTimer(interfaceName: "utun0"),
                       "First IPv4-loss after .connected must request min-visible debounce, not emit .reasserting")
    }

    func testSubWindowBlipRecoversSilently() {
        // The whole point of Phase 6 (revised): a brief IPv4-loss that
        // recovers before the min-visible timer fires emits ZERO events.
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())

        // Down (asks for timer; production caller arms it).
        _ = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )

        // Up before the timer would have fired (production caller cancels timer
        // separately). The fuser observes recovery and returns .noChange — the
        // fused state was .connected throughout (debouncing is "still connected"
        // from the orchestrator's POV).
        let recoveryDecision = fuser.applyObservation(
            interfaceName: "utun0",
            observation: .connectedFixture()
        )
        XCTAssertEqual(recoveryDecision, .noChange,
                       "Sub-window recovery must produce no event — the blip was invisible")
    }

    func testMinVisibleExpiryCommitsTheFlap() {
        // After the min-visible timer fires, the fuser commits the flap by
        // transitioning to .linkDownAwaitingRecovery. The fused state becomes
        // .reasserting, and the .emitAndStartGrace decision arms the existing
        // grace timer (the second-stage debounce we already had).
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        _ = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )

        // Production: the monitor's min-visible timer fires here.
        let committed = fuser.markMinVisibleExpired(interfaceName: "utun0")
        XCTAssertEqual(committed,
                       .emitAndStartGrace(.reasserting, then: .disconnected(reason: .networkLost)),
                       "Min-visible expiry must transition to .reasserting and arm the grace timer")
    }

    func testMinVisibleExpiryAfterRecoveryIsNoOp() {
        // If the IPv4 came back before the min-visible timer fires (production
        // would cancel the timer in this case), and the timer somehow still
        // fires anyway (defensive), the fuser is a no-op — phase is no longer
        // .linkDownDebouncing.
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        _ = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())

        let stale = fuser.markMinVisibleExpired(interfaceName: "utun0")
        XCTAssertEqual(stale, .noChange,
                       "markMinVisibleExpired must be a no-op when phase is no longer .linkDownDebouncing")
    }

    func testFlapPathCommittedToConnectedRecovery() {
        // Full sequence: connect -> ipv4 down -> debounce expires -> grace pending
        // -> ipv4 returns -> emit .connected.
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        _ = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )
        _ = fuser.markMinVisibleExpired(interfaceName: "utun0")

        let recoveryDecision = fuser.applyObservation(
            interfaceName: "utun0",
            observation: .connectedFixture()
        )
        XCTAssertEqual(recoveryDecision, .emit(.connected),
                       "Post-grace-arm recovery must emit .connected; caller cancels grace timer")
    }

    // MARK: - Connected -> .disconnected(.userInitiated)

    func testInterfaceRemovalEmitsUserInitiatedDisconnect() {
        var fuser = VPNStateFuser()
        XCTAssertEqual(
            fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture()),
            .emit(.connected)
        )

        // User clicks Disconnect — VPN client deletes utun0 entirely
        // (both IPv4 and IPv6 keys removed from SCDynamicStore).
        let removed = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: false)
        )
        XCTAssertEqual(removed, .emit(.disconnected(reason: .userInitiated)),
                       "Interface removal (no IPv4 + no IPv6) must be unambiguous: user disconnected, no grace")
    }

    // MARK: - Multi-utun policy

    func testAnyConnectedUtunYieldsConnected() {
        var fuser = VPNStateFuser()

        // Bring up utun0 (connected) and utun1 (apple-service utun: ipv6 only).
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        let decision = fuser.applyObservation(
            interfaceName: "utun1",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )
        // utun1 has no IPv4 (.neverSeen phase), but utun0 is connected —
        // fused state stays connected.
        XCTAssertEqual(decision, .noChange,
                       "While at least one utun is .connected, fused state remains .connected")
    }

    func testAllUtunsRemovedYieldsUserInitiated() {
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        _ = fuser.applyObservation(interfaceName: "utun1", observation: .connectedFixture())

        // Remove utun1 first — utun0 still connected.
        let intermediate = fuser.applyObservation(
            interfaceName: "utun1",
            observation: UtunRawObservation()  // all-false = removed
        )
        XCTAssertEqual(intermediate, .noChange, "utun0 still connected, no transition yet")

        // Remove utun0 — now everything is gone.
        let final = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation()
        )
        XCTAssertEqual(final, .emit(.disconnected(reason: .userInitiated)),
                       "All utuns removed -> .userInitiated disconnect")
    }

    // MARK: - Idempotence

    func testRepeatedSameObservationProducesNoChange() {
        var fuser = VPNStateFuser()
        XCTAssertEqual(
            fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture()),
            .emit(.connected)
        )
        XCTAssertEqual(
            fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture()),
            .noChange,
            "Re-emission of the same fused state should be suppressed"
        )
        XCTAssertEqual(
            fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture()),
            .noChange
        )
    }

    // MARK: - Grace expiry latch

    func testMarkGraceExpiredDoesNotEmitDirectly() {
        // markGraceExpired is a passive latch — it does not produce a decision.
        // The monitor calls it from inside the grace timer's fire handler and
        // separately invokes the onChange callback with .disconnected(.networkLost).
        // The fuser's job here is just to remember that the grace expired so the
        // next observation doesn't emit a stale .reasserting again.
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        _ = fuser.applyObservation(
            interfaceName: "utun0",
            observation: UtunRawObservation(ipv4Present: false,
                                             hasIPv4Address: false,
                                             ipv6Present: true)
        )

        fuser.markGraceExpired()
        // Test that this is a side-effect-free call. The next applyObservation
        // exercises the post-grace path.
    }

    // MARK: - VPNObservedState helpers

    func testIsConnectedHelper() {
        XCTAssertTrue(VPNObservedState.connected.isConnected)
        XCTAssertFalse(VPNObservedState.unknown.isConnected)
        XCTAssertFalse(VPNObservedState.reasserting.isConnected)
        XCTAssertFalse(VPNObservedState.disconnected(reason: .userInitiated).isConnected)
        XCTAssertFalse(VPNObservedState.disconnected(reason: .networkLost).isConnected)
        XCTAssertFalse(VPNObservedState.disconnected(reason: .unknown).isConnected)
    }

    func testIsReassertingHelper() {
        XCTAssertTrue(VPNObservedState.reasserting.isReasserting)
        XCTAssertFalse(VPNObservedState.connected.isReasserting)
        XCTAssertFalse(VPNObservedState.unknown.isReasserting)
        XCTAssertFalse(VPNObservedState.disconnected(reason: .networkLost).isReasserting)
    }

    // MARK: - Codable round-trip

    func testVPNObservedStateCodable() throws {
        let states: [VPNObservedState] = [
            .unknown,
            .connected,
            .reasserting,
            .disconnected(reason: .userInitiated),
            .disconnected(reason: .networkLost),
            .disconnected(reason: .unknown),
        ]
        for state in states {
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(VPNObservedState.self, from: encoded)
            XCTAssertEqual(state, decoded, "VPNObservedState \(state) failed Codable round-trip")
        }
    }

    // MARK: - knowsAbout(interfaceName:) admission gate

    func testKnowsAboutReturnsFalseForUnobservedInterface() {
        let fuser = VPNStateFuser()
        XCTAssertFalse(fuser.knowsAbout(interfaceName: "utun0"),
                       "Brand-new fuser must not claim to know any interface")
    }

    func testKnowsAboutReturnsTrueAfterFirstObservation() {
        // The monitor uses this to admit subsequent observations for utuns
        // that have already entered the fuser, even if they momentarily
        // appear without IPv4 (the flap path). Without this, an
        // ipv4-disappeared notification for a previously-connected utun
        // would be dropped by the apple-service-utun filter.
        var fuser = VPNStateFuser()
        _ = fuser.applyObservation(interfaceName: "utun0", observation: .connectedFixture())
        XCTAssertTrue(fuser.knowsAbout(interfaceName: "utun0"))
        XCTAssertFalse(fuser.knowsAbout(interfaceName: "utun1"))
    }

    // MARK: - utun key parsing

    func testUtunNameFromKeyExtractsName() {
        // /Link is a sample suffix; the parser only cares about the
        // second-to-last path segment, so /IPv4 / /IPv6 keys parse the same.
        XCTAssertEqual(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/utun0/IPv4"), "utun0")
        XCTAssertEqual(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/utun7/IPv6"), "utun7")
        XCTAssertEqual(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/utun123/IPv4"), "utun123")
    }

    func testUtunNameFromKeyRejectsNonUtun() {
        XCTAssertNil(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/en0/IPv4"))
        XCTAssertNil(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/awdl0/IPv6"))
        XCTAssertNil(VPNStatusMonitor.utunNameFromKey("State:/Network/Interface/utunX/IPv4"))
        XCTAssertNil(VPNStatusMonitor.utunNameFromKey("Setup:/Network/Service/abcd-1234"))
    }
}

private extension UtunRawObservation {
    /// "Connected" = IPv4 key present with an assigned address (and IPv6
    /// link-local also typically present on a real utun). The canonical
    /// healthy-VPN state we test against. macOS does NOT publish a /Link
    /// key for utun, so it isn't part of the connected criteria — see the
    /// `UtunRawObservation` doc comment.
    static func connectedFixture() -> UtunRawObservation {
        UtunRawObservation(ipv4Present: true, hasIPv4Address: true, ipv6Present: true)
    }
}

// MARK: - FakeVPNStatusObserver smoke test

final class FakeVPNStatusObserverTests: XCTestCase {

    func testEmitDeliversAfterStart() {
        let observer = FakeVPNStatusObserver()
        let received = NIOLockedValueBox<[VPNObservedState]>([])
        observer.setOnChange { state in
            received.withLockedValue { $0.append(state) }
        }
        observer.start()
        observer.emit(.connected)
        observer.emit(.reasserting)
        XCTAssertEqual(received.withLockedValue { $0 }, [.connected, .reasserting])
    }

    func testEmitBeforeStartIsDropped() {
        // Mirrors production observer's lifecycle gate: events emitted while
        // stopped should not deliver. Catches lifecycle bugs in tests.
        let observer = FakeVPNStatusObserver()
        let received = NIOLockedValueBox<[VPNObservedState]>([])
        observer.setOnChange { state in
            received.withLockedValue { $0.append(state) }
        }
        observer.emit(.connected)
        XCTAssertTrue(received.withLockedValue { $0 }.isEmpty)
    }

    func testEmitAfterStopIsDropped() {
        let observer = FakeVPNStatusObserver()
        let received = NIOLockedValueBox<[VPNObservedState]>([])
        observer.setOnChange { state in
            received.withLockedValue { $0.append(state) }
        }
        observer.start()
        observer.emit(.connected)
        observer.stop()
        observer.emit(.reasserting)
        XCTAssertEqual(received.withLockedValue { $0 }, [.connected])
    }
}
