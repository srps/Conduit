// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// A small dynamic store: two tunnels that can come and go, beside an Apple
/// service tunnel that only ever has a link-local IPv6 address.
private struct StoreModel: Hashable {
    enum Keys: CaseIterable {
        case absent
        case ipv6Only
        case addressed
        /// An IPv4 key with no `Addresses`, as seen mid-handshake.
        case emptyIPv4
    }

    static let tunnelA = "utun6"
    static let tunnelB = "utun7"

    var a = Keys.absent
    var b = Keys.absent

    var isUp: Bool { a == .addressed || b == .addressed }

    static let all: [StoreModel] = Keys.allCases.flatMap { a in Keys.allCases.map { StoreModel(a: a, b: $0) } }

    subscript(interface: String) -> Keys { interface == Self.tunnelA ? a : b }

    /// The store keys this model stands for, shaped as the real store shapes them.
    var keys: [String: [String: Any]] {
        var keys: [String: [String: Any]] = [
            "State:/Network/Interface/utun0/IPv6": ["Addresses": ["fe80::1"]],
        ]
        for (interface, state) in [(Self.tunnelA, a), (Self.tunnelB, b)] where state != .absent {
            keys["State:/Network/Interface/\(interface)/IPv6"] = ["Addresses": ["fe80::2"]]
            if state == .addressed { keys["State:/Network/Interface/\(interface)/IPv4"] = ["Addresses": ["192.0.2.10"]] }
            if state == .emptyIPv4 { keys["State:/Network/Interface/\(interface)/IPv4"] = ["Addresses": [String]()] }
        }
        return keys
    }

    private static let readings: [StoreModel: TunnelReading] = Dictionary(
        uniqueKeysWithValues: all.map { ($0, .snapshot(TunnelSnapshot.parse(store: $0.keys))) }
    )

    var reading: TunnelReading { Self.readings[self]! }

    /// What `VPNStatusMonitor.handleStoreChanges` reads for one interface.
    func observation(_ interface: String) -> UtunRawObservation {
        let state = self[interface]
        return UtunRawObservation(
            ipv4Present: state == .addressed || state == .emptyIPv4,
            hasIPv4Address: state == .addressed,
            ipv6Present: state != .absent
        )
    }
}

private enum Op: CaseIterable {
    case upA, dropA, removeA, emptyA, upB, dropB, removeB
    /// Shorter than min-visible; past min-visible and inside grace; past both.
    case waitShort, waitMid, waitLong
    /// Stop and start: a new observation session.
    case restart
    /// Toggles whether store notifications are being lost.
    case mute

    static let storeAndClock: [Op] = [
        .upA, .dropA, .removeA, .emptyA, .upB, .dropB, .removeB, .waitShort, .waitMid, .waitLong,
    ]

    var touched: String? {
        switch self {
        case .upA, .dropA, .removeA, .emptyA: StoreModel.tunnelA
        case .upB, .dropB, .removeB: StoreModel.tunnelB
        default: nil
        }
    }

    var wait: TimeInterval? {
        switch self {
        case .waitShort: 0.4
        case .waitMid: 2
        case .waitLong: 10
        default: nil
        }
    }

    func applied(to store: StoreModel) -> StoreModel {
        func next(_ keys: StoreModel.Keys) -> StoreModel.Keys {
            switch self {
            case .upA, .upB: .addressed
            // The IPv4 key goes; the IPv6 key stays if there was one.
            case .dropA, .dropB: keys == .absent ? .absent : .ipv6Only
            case .removeA, .removeB: .absent
            case .emptyA: .emptyIPv4
            default: keys
            }
        }
        var store = store
        if touched == StoreModel.tunnelA { store.a = next(store.a) }
        if touched == StoreModel.tunnelB { store.b = next(store.b) }
        return store
    }
}

private let window = VPNFlapWindow(minVisible: 1, grace: 5)

private struct Delivery: Equatable {
    let at: TimeInterval
    let state: VPNObservedState
}

/// One observation session over `VPNFlapTimer`: reconcile on a notification,
/// and again at each deadline the timer hands back.
private struct LevelSession {
    private(set) var timer = VPNFlapTimer()
    private(set) var detection: VPNDetection
    /// State changes with the time they were concluded, oldest first.
    private var deliveries: [Delivery]

    init(_ store: StoreModel, now: TimeInterval) {
        detection = timer.reconcile(store.reading, now: now, window: window)
        deliveries = [Delivery(at: now, state: detection.state)]
    }

    mutating func reconcile(_ store: StoreModel, now: TimeInterval) {
        let previous = detection.state
        detection = timer.reconcile(store.reading, now: now, window: window)
        if detection.state != previous { deliveries.append(Delivery(at: now, state: detection.state)) }
    }

    /// Runs every deadline up to `target`. Returns how many came due.
    @discardableResult
    mutating func advance(_ store: StoreModel, to target: TimeInterval) -> Int {
        var wakes = 0
        // The cap ends a run whose deadlines never stop coming; the caller
        // fails it for taking more wake-ups than there are windows.
        while let deadline = detection.deadline, deadline <= target, wakes < 8 {
            reconcile(store, now: deadline)
            wakes += 1
        }
        return wakes
    }

    mutating func takeDeliveries() -> [Delivery] {
        defer { deliveries = [] }
        return deliveries
    }
}

/// `VPNStatusMonitor`'s decision handling over a virtual clock, driving the
/// real `VPNStateFuser`: `primeInitialState`, `handleStoreChanges` and
/// `applyFuserDecision`, with the two kinds of `DispatchWorkItem` replaced by
/// deadlines. It exists to compare today's verdicts with the timer's.
private struct EdgeMonitorModel {
    private var fuser = VPNStateFuser()
    private var graceDeadline: TimeInterval?
    private var minVisibleDeadlines: [String: TimeInterval] = [:]
    private var consumer = VPNObservedState.unknown
    private var deliveries: [Delivery] = []
    private(set) var connectedName: String?
    private(set) var live: [String] = []

    init(_ store: StoreModel, now: TimeInterval) {
        for interface in ["utun0", StoreModel.tunnelA, StoreModel.tunnelB] { handle(interface, store, now: now) }
        if !store.isUp { apply(fuser.markNoTunnelsPresent(), now: now) }
        // A session that primes to nothing still has a first state to compare.
        if deliveries.isEmpty { deliveries = [Delivery(at: now, state: consumer)] }
    }

    mutating func handle(_ interface: String, _ store: StoreModel, now: TimeInterval) {
        let observation = interface == "utun0"
            ? UtunRawObservation(ipv4Present: false, hasIPv4Address: false, ipv6Present: true)
            : store.observation(interface)
        guard observation.ipv4Present || fuser.knowsAbout(interfaceName: interface) else { return }
        if observation.isFullyConnected { minVisibleDeadlines[interface] = nil }
        apply(fuser.applyObservation(interfaceName: interface, observation: observation), now: now)
    }

    mutating func advance(to target: TimeInterval) {
        while true {
            let nextMinVisible = minVisibleDeadlines.min { ($0.value, $0.key) < ($1.value, $1.key) }
            if let (interface, deadline) = nextMinVisible, deadline <= target, deadline <= graceDeadline ?? .infinity {
                minVisibleDeadlines[interface] = nil
                apply(fuser.markMinVisibleExpired(interfaceName: interface), now: deadline)
            } else if let deadline = graceDeadline, deadline <= target {
                graceDeadline = nil
                fuser.markGraceExpired()
                refreshNames()
                deliver(.disconnected(reason: .networkLost), at: deadline)
            } else {
                return
            }
        }
    }

    mutating func takeDeliveries() -> [Delivery] {
        defer { deliveries = [] }
        return deliveries
    }

    private mutating func apply(_ decision: VPNStateFuser.Decision, now: TimeInterval) {
        refreshNames()
        switch decision {
        case .noChange:
            // The monitor delivers an unchanged `.connected` again when a
            // name moved. That is a name update, not a state change.
            break
        case .emit(let state):
            graceDeadline = nil
            deliver(state, at: now)
        case .emitAndStartGrace(let state, _):
            graceDeadline = now + window.grace
            deliver(state, at: now)
        case .startMinVisibleTimer(let interface):
            minVisibleDeadlines[interface] = now + window.minVisible
        }
    }

    private mutating func refreshNames() {
        connectedName = fuser.connectedInterfaceNames.first
        live = fuser.liveInterfaceNames
    }

    private mutating func deliver(_ state: VPNObservedState, at now: TimeInterval) {
        guard state != consumer else { return }
        consumer = state
        deliveries.append(Delivery(at: now, state: state))
    }
}

final class VPNFlapTimerModelCheckTests: XCTestCase {
    /// Ops per ordering. Every shorter ordering is checked on the way, as a
    /// prefix.
    private static let exhaustiveDepth = 5
    private static let differentialDepth = 6

    // MARK: - The model and the parser agree

    func testEveryModelStoreParsesToTheTunnelsItStandsFor() {
        for store in StoreModel.all {
            guard case .snapshot(let snapshot) = store.reading else { return XCTFail("the model always reads") }
            XCTAssertEqual(VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot), store.isUp, "\(store)")
            let expected = ["utun0"] + [StoreModel.tunnelA, StoreModel.tunnelB].filter { store[$0] != .absent }
            XCTAssertEqual(snapshot.tunnels.map(\.interface), expected, "\(store)")
        }
    }

    // MARK: - Exhaustive properties of the timer

    private struct Tally {
        var orderings = 0
        var states = 0
        var wrong = 0
        var examples: [String] = []

        mutating func fail(_ message: String, _ path: [Op]) {
            wrong += 1
            if examples.count < 5 { examples.append("\(message) after \(path.map { "\($0)" })") }
        }
    }

    /// Every ordering of store changes, waits, restarts and lost
    /// notifications up to `exhaustiveDepth`, from an empty store and from a
    /// connected one. After every op:
    ///
    /// - **Convergence.** Once every deadline has run, the state is
    ///   `.connected` exactly when a tunnel counts, and `.disconnected`
    ///   otherwise. A tunnel that counts is reported at once, and the state
    ///   is never `.unknown`.
    /// - **Idempotence.** The same reading at the same time, twice, gives the
    ///   same detection and leaves the same memory.
    /// - **Restart equivalence.** A timer started fresh on the store as it
    ///   stands settles on the same state as the one that watched it get
    ///   there.
    /// - **Notification loss.** Whatever was missed, one later reading (a
    ///   notification, a deadline, an audit) restores convergence.
    /// - **Blindness.** A failed reading reports `.unknown` and leaves the
    ///   memory untouched.
    func testEveryOrderingConverges() {
        var tally = Tally()
        let started = Date()
        for initial in [StoreModel(), StoreModel(a: .addressed)] {
            var path: [Op] = []
            explore(
                store: initial, session: LevelSession(initial, now: 0), now: 0, muted: false, stale: false,
                path: &path, tally: &tally
            )
        }
        print("VPNFlapTimer model check: depth \(Self.exhaustiveDepth), \(tally.orderings) orderings, "
            + "\(tally.states) states checked, \(tally.wrong) wrong, "
            + String(format: "%.1f s", Date().timeIntervalSince(started)))
        XCTAssertEqual(tally.examples, [])
        XCTAssertEqual(tally.orderings, 2 * Int(pow(Double(Op.allCases.count), Double(Self.exhaustiveDepth))))
    }

    /// `stale` is true while the session has not read the store since it last
    /// changed, which only a lost notification causes.
    private func explore(
        store: StoreModel, session: LevelSession, now: TimeInterval, muted: Bool, stale: Bool,
        path: inout [Op], tally: inout Tally
    ) {
        check(store: store, session: session, now: now, stale: stale, path: path, tally: &tally)
        guard path.count < Self.exhaustiveDepth else {
            tally.orderings += 1
            return
        }
        for op in Op.allCases {
            var store = store, session = session, now = now, muted = muted, stale = stale
            switch op {
            case .restart:
                session = LevelSession(store, now: now)
                stale = false
            case .mute:
                muted.toggle()
            case .waitShort, .waitMid, .waitLong:
                if session.advance(store, to: now + op.wait!) > 0 { stale = false }
                now += op.wait!
            default:
                let changed = op.applied(to: store)
                if changed != store {
                    store = changed
                    if muted { stale = true } else { session.reconcile(store, now: now) }
                }
            }
            path.append(op)
            explore(store: store, session: session, now: now, muted: muted, stale: stale, path: &path, tally: &tally)
            path.removeLast()
        }
    }

    private func check(
        store: StoreModel, session: LevelSession, now: TimeInterval, stale: Bool, path: [Op], tally: inout Tally
    ) {
        tally.states += 1
        let settledLabel = store.isUp ? "connected" : "disconnected"

        if !stale {
            let detection = session.detection
            if store.isUp, detection.phase != .up { tally.fail("a counting tunnel reads \(detection.phase)", path) }
            if detection.state == .unknown { tally.fail("a readable store reads unknown", path) }
            var settling = session
            // One per debounce still running, and one for grace.
            if settling.advance(store, to: .infinity) > detection.live.count + 1 {
                tally.fail("more deadlines than windows to settle", path)
            }
            if settling.detection.state.eventLabel != settledLabel {
                tally.fail("settled on \(settling.detection.state), want \(settledLabel)", path)
            }
        }

        // One more reading, whatever prompted it, is enough after any loss.
        var audited = session
        audited.reconcile(store, now: now)
        var timer = audited.timer
        let again = timer.reconcile(store.reading, now: now, window: window)
        if again != audited.detection || timer != audited.timer { tally.fail("a repeated reading changed something", path) }
        if let deadline = audited.detection.deadline, deadline <= now || deadline > now + window.minVisible + window.grace {
            tally.fail("a deadline at \(deadline) from \(now)", path)
        }
        audited.advance(store, to: .infinity)
        if audited.detection.state.eventLabel != settledLabel {
            tally.fail("after a lost notification settled on \(audited.detection.state), want \(settledLabel)", path)
        }

        let fresh = LevelSession(store, now: now)
        if fresh.detection.state.eventLabel != settledLabel || fresh.detection.deadline != nil {
            tally.fail("a fresh session reads \(fresh.detection)", path)
        }

        var blind = session.timer
        let unread = blind.reconcile(.failed(.storeRead), now: now, window: window)
        if unread.state != .unknown || unread.deadline != nil || blind != session.timer {
            tally.fail("a failed reading gave \(unread) or touched the memory", path)
        }
    }

    // MARK: - Differential against the shipped fuser

    /// Every ordering of store changes and waits up to `differentialDepth`
    /// with no restart and every notification delivered, run through today's
    /// monitor logic and through the timer. The state changes, their times,
    /// the connected interface and the live set must be the same.
    ///
    /// One class of ordering is left out: an IPv4 key with no addresses on a
    /// tunnel that has had none since the session began. The fuser admits it
    /// as an interface it knows nothing about and reports `.unknown`, or
    /// `.disconnected(.networkLost)` beside a removed tunnel; the timer does
    /// not count it. `testAnAddresslessIPv4KeyIsWhereTheTimerAndTheFuserDiffer`
    /// pins that difference.
    func testTheTimerMatchesTheFuserOnEveryRestartFreeOrdering() {
        var compared = 0, excluded = 0
        var mismatches: [String] = []
        let started = Date()

        func explore(
            store: StoreModel, edge: EdgeMonitorModel, level: LevelSession, now: TimeInterval,
            everAddressed: Set<String>, path: inout [Op]
        ) {
            var edge = edge, level = level
            let fuserSaw = edge.takeDeliveries(), timerSaw = level.takeDeliveries()
            let names = "\(edge.connectedName ?? "-") \(edge.live)"
            let timerNames = "\(level.detection.carrying.first ?? "-") \(level.detection.live)"
            if fuserSaw != timerSaw || names != timerNames {
                if mismatches.count < 5 {
                    mismatches.append("\(path.map { "\($0)" }): fuser \(fuserSaw) \(names), timer \(timerSaw) \(timerNames)")
                }
                return
            }
            guard path.count < Self.differentialDepth else {
                compared += 1
                return
            }
            for op in Op.storeAndClock {
                var store = store, edge = edge, level = level, now = now, everAddressed = everAddressed
                if let wait = op.wait {
                    now += wait
                    edge.advance(to: now)
                    level.advance(store, to: now)
                } else if let interface = op.touched {
                    let changed = op.applied(to: store)
                    if changed != store {
                        store = changed
                        if store[interface] == .addressed { everAddressed.insert(interface) }
                        if store[interface] == .emptyIPv4, !everAddressed.contains(interface) {
                            excluded += 1
                            continue
                        }
                        edge.handle(interface, store, now: now)
                        level.reconcile(store, now: now)
                    }
                }
                path.append(op)
                explore(store: store, edge: edge, level: level, now: now, everAddressed: everAddressed, path: &path)
                path.removeLast()
            }
        }

        for initial in [StoreModel(), StoreModel(a: .addressed), StoreModel(a: .addressed, b: .addressed)] {
            var path: [Op] = []
            let everAddressed = Set([StoreModel.tunnelA, StoreModel.tunnelB].filter { initial[$0] == .addressed })
            explore(
                store: initial, edge: EdgeMonitorModel(initial, now: 0), level: LevelSession(initial, now: 0), now: 0,
                everAddressed: everAddressed, path: &path
            )
        }
        print("VPNFlapTimer differential: depth \(Self.differentialDepth), \(compared) orderings equal, "
            + "\(excluded) prefixes excluded, \(mismatches.count) mismatches shown, "
            + String(format: "%.1f s", Date().timeIntervalSince(started)))
        XCTAssertEqual(mismatches, [])
        XCTAssertGreaterThan(compared, 100_000, "the comparison ran")
    }

    func testAnAddresslessIPv4KeyIsWhereTheTimerAndTheFuserDiffer() {
        // Off VPN, then a tunnel shows an IPv4 key with no addresses.
        var store = StoreModel()
        var edge = EdgeMonitorModel(store, now: 0)
        var level = LevelSession(store, now: 0)
        XCTAssertEqual(edge.takeDeliveries().map(\.state), [.disconnected(reason: .unknown)])
        XCTAssertEqual(level.takeDeliveries().map(\.state), [.disconnected(reason: .unknown)])

        store = Op.emptyA.applied(to: store)
        edge.handle(StoreModel.tunnelA, store, now: 1)
        level.reconcile(store, now: 1)

        XCTAssertEqual(edge.takeDeliveries().map(\.state), [.unknown],
                       "the fuser gives up a settled verdict for an interface it has never seen connected")
        XCTAssertEqual(level.takeDeliveries(), [], "the timer still reads the store as off VPN")
        XCTAssertEqual(level.detection.state, .disconnected(reason: .unknown))
    }
}
