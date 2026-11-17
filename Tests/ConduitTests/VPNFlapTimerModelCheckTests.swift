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
        /// An addressed IPv4 key and no IPv6 key at all.
        case ipv4Only
        /// An IPv4 key with no `Addresses`, as seen mid-handshake.
        case emptyIPv4
        /// No interface key; a service key still names the tunnel.
        case serviceOnly
    }

    static let tunnelA = "utun6"
    static let tunnelB = "utun7"
    static let tunnels = [tunnelA, tunnelB]

    var a = Keys.absent
    var b = Keys.absent

    /// The tunnels whose IPv4 key lists an address, in name order.
    var counting: [String] { Self.tunnels.filter { self[$0] == .addressed || self[$0] == .ipv4Only } }

    var isUp: Bool { !counting.isEmpty }

    static let all: [StoreModel] = Keys.allCases.flatMap { a in Keys.allCases.map { StoreModel(a: a, b: $0) } }

    subscript(interface: String) -> Keys { interface == Self.tunnelA ? a : b }

    /// The store keys this model stands for, shaped as the real store shapes them.
    var keys: [String: [String: Any]] {
        var keys: [String: [String: Any]] = [
            "State:/Network/Interface/utun0/IPv6": ["Addresses": ["fe80::1"]],
        ]
        for (interface, state) in [(Self.tunnelA, a), (Self.tunnelB, b)] {
            switch state {
            case .absent:
                continue
            case .serviceOnly:
                keys["State:/Network/Service/service-\(interface)/IPv4"] = ["InterfaceName": interface]
                continue
            case .addressed:
                keys["State:/Network/Interface/\(interface)/IPv4"] = ["Addresses": ["192.0.2.10"]]
            case .ipv4Only:
                keys["State:/Network/Interface/\(interface)/IPv4"] = ["Addresses": ["192.0.2.10"]]
                continue
            case .emptyIPv4:
                keys["State:/Network/Interface/\(interface)/IPv4"] = ["Addresses": [String]()]
            case .ipv6Only:
                break
            }
            keys["State:/Network/Interface/\(interface)/IPv6"] = ["Addresses": ["fe80::2"]]
        }
        return keys
    }

    private static let readings: [StoreModel: TunnelReading] = Dictionary(
        uniqueKeysWithValues: all.map { ($0, .snapshot(TunnelSnapshot.parse(store: $0.keys))) }
    )

    var reading: TunnelReading { Self.readings[self]! }
}

private enum Windows {
    static let standard = VPNFlapWindow(minVisible: 1, grace: 5)
    /// No debounce: a loss shows in the reading that sees it.
    static let immediate = VPNFlapWindow(minVisible: 0, grace: 5)
    /// Both windows longer than the standard ones.
    static let wide = VPNFlapWindow(minVisible: 3, grace: 15)
    /// No deadline is further off than the longest debounce and grace.
    static let longest: TimeInterval = 3 + 15
}

private enum Op: CaseIterable {
    case upA, dropA, removeA, emptyA
    /// The interface keys go and a service key still names the tunnel.
    case strandA
    case upB, dropB, removeB, emptyB
    /// The tunnel is left with an IPv6 key alone, whatever it had: from
    /// absent, a tunnel that appears without ever having an address.
    case ipv6B
    /// The tunnel is left with an addressed IPv4 key alone. A drop then
    /// takes its only key, so it leaves the store with no flap window.
    case ipv4OnlyB
    /// One notification for both tunnels: A is removed as B comes up.
    case handover
    /// One notification for both tunnels: each loses its IPv4 key.
    case dropBoth
    /// Shorter than the standard min-visible; past it and inside grace; past
    /// both. Against the wide window: inside min-visible twice, then past it
    /// and inside grace.
    case waitShort, waitMid, waitLong
    /// Stop and start with nothing between: a new observation session.
    case restart
    /// Stops a running session, or starts a new one. Between the two the
    /// store and the clock move with nobody reading.
    case stopOrStart
    /// Toggles whether store notifications are being lost.
    case mute
    /// Toggles whether the store can be read.
    case failReads
    /// Toggles whether deadline wake-ups are late. While they are, a wait
    /// moves the clock and runs no deadline. The overdue wake-up runs when
    /// the toggle goes back, unless a reading came first and stood in for it.
    case stallDeadlines
    /// The owner changes the flap windows in Settings.
    case windowStandard, windowImmediate, windowWide

    var wait: TimeInterval? {
        switch self {
        case .waitShort: 0.4
        case .waitMid: 2
        case .waitLong: 10
        default: nil
        }
    }

    var window: VPNFlapWindow? {
        switch self {
        case .windowStandard: Windows.standard
        case .windowImmediate: Windows.immediate
        case .windowWide: Windows.wide
        default: nil
        }
    }

    func applied(to store: StoreModel) -> StoreModel {
        // The IPv4 key goes; the IPv6 key stays if there was one.
        func dropped(_ keys: StoreModel.Keys) -> StoreModel.Keys {
            switch keys {
            case .absent, .serviceOnly: keys
            case .ipv4Only: .absent
            case .ipv6Only, .addressed, .emptyIPv4: .ipv6Only
            }
        }
        var store = store
        switch self {
        case .upA: store.a = .addressed
        case .dropA: store.a = dropped(store.a)
        case .removeA: store.a = .absent
        case .emptyA: store.a = .emptyIPv4
        case .strandA: store.a = .serviceOnly
        case .upB: store.b = .addressed
        case .dropB: store.b = dropped(store.b)
        case .removeB: store.b = .absent
        case .emptyB: store.b = .emptyIPv4
        case .ipv6B: store.b = .ipv6Only
        case .ipv4OnlyB: store.b = .ipv4Only
        case .handover:
            store.a = .absent
            store.b = .addressed
        case .dropBoth:
            store.a = dropped(store.a)
            store.b = dropped(store.b)
        default: break
        }
        return store
    }
}

private struct Delivery: Equatable {
    let at: TimeInterval
    let state: VPNObservedState
}

/// One reading a session took and could read.
private struct Observation {
    let at: TimeInterval
    let store: StoreModel
    let window: VPNFlapWindow
}

/// What a session must report, worked out from every reading it took and
/// nothing else. A failed reading is not in the history; the good reading
/// after a blind gap enters it twice, at the last good reading's time and at
/// its own, both with the windows of the last good reading (decision 0047). It follows the statechart in
/// `docs/design-vpn-detection-level-triggered.md` and keeps no memory between
/// calls, so it shares no state and no arithmetic with `VPNFlapTimer`.
private enum Oracle {
    private static func counts(_ keys: StoreModel.Keys) -> Bool { keys == .addressed || keys == .ipv4Only }

    /// In the store under an interface key, with no address.
    private static func waits(_ keys: StoreModel.Keys) -> Bool { keys == .ipv6Only || keys == .emptyIPv4 }

    /// When the debounce ends for a tunnel that is lost at reading `index`:
    /// it counted, then every reading since has found it waiting. Fixed by
    /// the window of the reading that first found it so.
    private static func debounceEnd(_ tunnel: String, at index: Int, in history: [Observation]) -> TimeInterval? {
        guard waits(history[index].store[tunnel]) else { return nil }
        var first = index
        while first > 0, waits(history[first - 1].store[tunnel]) { first -= 1 }
        guard first > 0, counts(history[first - 1].store[tunnel]) else { return nil }
        return history[first].at + max(0, history[first].window.minVisible)
    }

    private static func debounceEnds(at index: Int, in history: [Observation]) -> [String: TimeInterval] {
        var ends: [String: TimeInterval] = [:]
        for tunnel in StoreModel.tunnels { ends[tunnel] = debounceEnd(tunnel, at: index, in: history) }
        return ends
    }

    /// A tunnel counts at reading `index`, or a lost one is inside its debounce.
    private static func isConnected(at index: Int, in history: [Observation]) -> Bool {
        history[index].store.isUp || debounceEnds(at: index, in: history).values.contains { $0 > history[index].at }
    }

    /// The latest instant up to reading `index` at which the state was
    /// connected: a tunnel counted from one reading until the next, and a
    /// debounce carried it to its end or to the next reading, whichever came
    /// first.
    private static func connectedUntil(at index: Int, in history: [Observation]) -> TimeInterval? {
        var latest: TimeInterval?
        for earlier in 0..<index {
            let next = history[earlier + 1].at
            let until: TimeInterval?
            if history[earlier].store.isUp {
                until = next
            } else {
                until = debounceEnds(at: earlier, in: history).values.max().map { min($0, next) }
            }
            if let until { latest = max(latest ?? until, until) }
        }
        return latest
    }

    static func detection(after history: [Observation]) -> VPNDetection {
        let last = history.count - 1
        let now = history[last].at
        let counting = StoreModel.tunnels.filter { counts(history[last].store[$0]) }
        let lost = debounceEnds(at: last, in: history)
        let debouncing = lost.filter { $0.value > now }
        let live = (counting + lost.keys).sorted()

        if !counting.isEmpty || !debouncing.isEmpty {
            return VPNDetection(
                phase: counting.isEmpty ? .debouncing : .up,
                carrying: (counting + debouncing.keys).sorted(), live: live, deadline: debouncing.values.min()
            )
        }
        guard history.contains(where: \.store.isUp) else {
            return VPNDetection(phase: .down(.unknown), carrying: [], live: [], deadline: nil)
        }
        guard !lost.isEmpty else {
            return VPNDetection(phase: .down(.userInitiated), carrying: [], live: [], deadline: nil)
        }
        // Grace starts at the first reading of this unbroken run with the
        // state not connected, and keeps that reading's window.
        var graceStart = last
        while graceStart > 0, !isConnected(at: graceStart - 1, in: history) { graceStart -= 1 }
        let graceEnd = connectedUntil(at: last, in: history)! + history[graceStart].window.grace
        if now < graceEnd {
            return VPNDetection(phase: .reasserting, carrying: [], live: live, deadline: graceEnd)
        }
        return VPNDetection(phase: .down(.networkLost), carrying: [], live: live, deadline: nil)
    }
}

/// One observation session over `VPNFlapTimer`: reconcile on a notification,
/// and again at each deadline the timer hands back. Every reconcile is held
/// against the oracle and against the reading before it.
private struct LevelSession {
    static let readFailure = TunnelReading.Failure(.storeRead, code: 1001)

    private(set) var timer = VPNFlapTimer()
    private(set) var detection: VPNDetection
    /// State changes with the time they were concluded, oldest first.
    private var deliveries: [Delivery]
    /// Every reading that succeeded, oldest first.
    private(set) var history: [Observation] = []
    /// The detection of the last reading that succeeded.
    private var lastRead: VPNDetection?
    /// The timer right after the last reading that succeeded, and the
    /// window that reading was handed.
    private var memoryAtLastGood: VPNFlapTimer?
    private var windowAtLastGood = Windows.standard
    /// A reading failed since the last good one.
    private var blind = false
    /// The last reconcile ended a blind gap under a window other than the
    /// one in force at its last good reading.
    private(set) var recoveredUnderANewWindow = false
    /// The first reconcile that disagreed with the oracle, or stepped back
    /// with the store unchanged.
    private(set) var fault: String?

    init(_ store: StoreModel, now: TimeInterval, window: VPNFlapWindow = Windows.standard, readable: Bool = true) {
        detection = VPNDetection(phase: .down(.unknown), carrying: [], live: [], deadline: nil)
        deliveries = []
        reconcile(store, now: now, window: window, readable: readable)
        deliveries = [Delivery(at: now, state: detection.state)]
    }

    mutating func reconcile(
        _ store: StoreModel, now: TimeInterval, window: VPNFlapWindow = Windows.standard, readable: Bool = true
    ) {
        let previous = detection.state
        let memory = timer
        detection = timer.reconcile(readable ? store.reading : .failed(Self.readFailure), now: now, window: window)
        if detection.state != previous { deliveries.append(Delivery(at: now, state: detection.state)) }
        recoveredUnderANewWindow = false

        guard readable else {
            let unknown = VPNDetection(phase: .blind(Self.readFailure), carrying: [], live: [], deadline: nil)
            if detection != unknown { note("a failed reading gave \(detection)") }
            // Only the failure is recorded, and a second records nothing more.
            if timer.lastGoodReading != memory.lastGoodReading
                || timer.failedSinceLastGoodReading != (memory.lastGoodReading != nil) {
                note("a failed reading changed more than that it failed")
            }
            var again = timer
            _ = again.reconcile(.failed(Self.readFailure), now: now, window: window)
            if again != timer { note("a second failed reading changed the memory") }
            blind = history.last != nil
            return
        }
        let storeUnchanged = history.last?.store == store
        if blind, let last = history.last, let memoryAtLastGood {
            let windowAtL = windowAtLastGood
            // The 0047 equivalence: the recovery verdict is the timer's for
            // this snapshot read at the last good reading and again now,
            // both with the windows in force then.
            var replay = memoryAtLastGood
            _ = replay.reconcile(store.reading, now: last.at, window: windowAtL)
            let want = replay.reconcile(store.reading, now: now, window: windowAtL)
            if detection != want { note("at \(now) the recovery gave \(detection), the replay from \(last.at) \(want)") }
            recoveredUnderANewWindow = window != windowAtL
            history.append(Observation(at: last.at, store: store, window: windowAtL))
            history.append(Observation(at: now, store: store, window: windowAtL))
        } else {
            history.append(Observation(at: now, store: store, window: window))
        }
        blind = false
        memoryAtLastGood = timer
        windowAtLastGood = window
        let expected = Oracle.detection(after: history)
        if detection != expected { note("at \(now) the timer gave \(detection), the oracle \(expected)") }
        if storeUnchanged, let lastRead, let step = Self.backwardStep(from: lastRead, to: detection) {
            note("at \(now) with the store unchanged, \(step)")
        }
        lastRead = detection
    }

    /// With the store as it was, a phase only moves forward, a disconnect
    /// keeps its reason, and a grace window keeps its end.
    private static func backwardStep(from old: VPNDetection, to new: VPNDetection) -> String? {
        func rank(_ phase: VPNDetection.Phase) -> Int {
            switch phase {
            case .up: 0
            case .debouncing: 1
            case .reasserting: 2
            case .down, .blind: 3
            }
        }
        if rank(new.phase) < rank(old.phase) { return "\(old.phase) went back to \(new.phase)" }
        if case .down = old.phase, new.phase != old.phase { return "\(old.phase) became \(new.phase)" }
        if old.phase == .reasserting, new.phase == .reasserting, new.deadline != old.deadline {
            return "grace moved from \(String(describing: old.deadline)) to \(String(describing: new.deadline))"
        }
        // The deadline is the next debounce to end, so it moves on as each
        // one ends and never comes nearer.
        if old.phase == .debouncing, new.phase == .debouncing, new.deadline! < old.deadline! {
            return "a debounce moved from \(old.deadline!) back to \(new.deadline!)"
        }
        return nil
    }

    private mutating func note(_ message: String) {
        if fault == nil { fault = message }
    }

    /// Runs every deadline up to `target`. Returns how many came due. A
    /// deadline already behind `now` runs at `now`: its wake-up was late.
    @discardableResult
    mutating func advance(
        _ store: StoreModel, from now: TimeInterval = -.infinity, to target: TimeInterval,
        window: VPNFlapWindow = Windows.standard, readable: Bool = true
    ) -> Int {
        var wakes = 0
        // The cap ends a run whose deadlines never stop coming; the caller
        // fails it for taking more wake-ups than there are windows.
        while let deadline = detection.deadline, deadline <= target, wakes < 8 {
            reconcile(store, now: max(deadline, now), window: window, readable: readable)
            wakes += 1
        }
        return wakes
    }

    mutating func takeDeliveries() -> [Delivery] {
        defer { deliveries = [] }
        return deliveries
    }
}

/// Everything an ordering can change.
private struct World {
    var store: StoreModel
    /// Nil while stopped.
    var session: LevelSession?
    var now: TimeInterval = 0
    var window = Windows.standard
    var muted = false
    var readable = true
    /// Deadline wake-ups run on time.
    var punctual = true
    /// The session's last reading is not of the store as it stands: a
    /// notification was lost, or the read failed.
    var stale = false

    init(_ store: StoreModel) {
        self.store = store
        session = LevelSession(store, now: 0)
    }

    private mutating func start() {
        session = LevelSession(store, now: now, window: window, readable: readable)
        stale = !readable
    }

    /// Runs the session's deadlines up to `target`, each reading the store
    /// whether or not notifications are being lost.
    private mutating func wake(until target: TimeInterval) {
        if let woken = session?.advance(store, from: now, to: target, window: window, readable: readable), woken > 0 {
            stale = !readable
        }
    }

    /// False when the op changes nothing, so the ordering is the same as the
    /// shorter one without it.
    mutating func apply(_ op: Op) -> Bool {
        if let wait = op.wait {
            if punctual { wake(until: now + wait) }
            now += wait
            return true
        }
        if let changed = op.window {
            guard changed != window else { return false }
            // The next reconcile is handed the new window; nothing reads
            // the store because the setting moved.
            window = changed
            return true
        }
        switch op {
        case .restart:
            start()
        case .stopOrStart:
            if session == nil {
                start()
            } else {
                session = nil
                stale = false
            }
        case .mute:
            muted.toggle()
        case .failReads:
            readable.toggle()
        case .stallDeadlines:
            punctual.toggle()
            if punctual { wake(until: now) }
        default:
            let changed = op.applied(to: store)
            guard changed != store else { return false }
            store = changed
            guard session != nil else { break }
            if muted {
                stale = true
            } else {
                session!.reconcile(store, now: now, window: window, readable: readable)
                stale = !readable
            }
        }
        return true
    }
}

/// SplitMix64: the same orderings on every run and every machine.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}

final class VPNFlapTimerModelCheckTests: XCTestCase {
    /// Ops per ordering. Every shorter ordering is checked on the way, as a
    /// prefix.
    private static let exhaustiveDepth = 4
    private static let randomDepth = 24
    private static let randomOrderings = 10_000
    private static let randomSeed: UInt64 = 0x5eed_0307

    // MARK: - The model and the parser agree

    func testEveryModelStoreParsesToTheTunnelsItStandsFor() {
        for store in StoreModel.all {
            guard case .snapshot(let snapshot) = store.reading else { return XCTFail("the model always reads") }
            XCTAssertEqual(VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot), store.isUp, "\(store)")
            let present = StoreModel.tunnels.filter { store[$0] != .absent }
            XCTAssertEqual(snapshot.tunnels.map(\.interface), ["utun0"] + present, "\(store)")
            XCTAssertEqual(
                snapshot.tunnels.filter { !$0.hasInterfaceKey }.map(\.interface),
                StoreModel.tunnels.filter { store[$0] == .serviceOnly }, "\(store)"
            )
        }
    }

    // MARK: - Exhaustive properties of the timer

    private struct Tally {
        var orderings = 0
        var states = 0
        var wrong = 0
        var examples: [String] = []
        /// How many checked states settled on each verdict, for a session
        /// that watched the store get there.
        var settled: [String: Int] = [:]
        /// How many checked states were of each kind the alphabet was
        /// widened to reach.
        var reached: [String: Int] = [:]

        mutating func fail(_ message: String, _ path: [Op]) {
            wrong += 1
            if examples.count < 5 { examples.append("\(message) after \(path.map { "\($0)" })") }
        }

        var summary: String {
            "\(orderings) orderings, \(states) states checked, \(wrong) wrong, settled "
                + settled.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                + ", reached " + reached.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
    }

    /// Every ordering of the ops up to `exhaustiveDepth`, from an empty
    /// store and from a connected one. An op that changes nothing is not
    /// taken: that ordering is the shorter one without it, which is checked
    /// as a prefix. After every op:
    ///
    /// - **The oracle.** Each reconcile on the way, and each one below,
    ///   returns the phase, disconnect reason, carrying and live tunnels and
    ///   deadline that `Oracle` works out from the session's readings.
    /// - **Convergence.** Once every deadline has run, the state is
    ///   `.connected` exactly when a tunnel counts, and `.disconnected`
    ///   otherwise. A tunnel that counts is reported at once, and a store
    ///   that was read is never `.unknown`.
    /// - **No way back.** With the store unchanged a phase only moves
    ///   forward, whatever window each reconcile is handed.
    /// - **Idempotence.** The same reading at the same time, twice, gives the
    ///   same detection and leaves the same memory.
    /// - **Restart.** A session started on the store as it stands reads
    ///   `.connected`, or `.disconnected(.unknown)`, with no deadline. The
    ///   session that watched the store get there settles on `.connected`
    ///   for the same stores. For the others it settles on `.disconnected`
    ///   with the reason its history gives: `.networkLost` while a tunnel it
    ///   saw up is still in the store, `.userInitiated` when it saw the VPN
    ///   up and none is, `.unknown` when it never did. So a restart keeps
    ///   connected against disconnected and may change the reason.
    /// - **Notification loss.** Whatever was missed, one later reading (a
    ///   notification, a deadline, an audit) restores convergence. The check
    ///   takes that reading itself: nothing here proves one will come.
    /// - **Late deadlines.** A wake-up that runs after its deadline, under
    ///   whatever window is set by then, reports what the oracle expects.
    /// - **Blindness.** A failed reading reports `.unknown` with no deadline
    ///   and records only that it failed. The good reading after a blind gap
    ///   gives the timer's verdict for that snapshot read at the last good
    ///   reading and again now, both with the windows in force then
    ///   (decision 0047), and the oracle agrees, also when the windows
    ///   changed during the gap.
    func testEveryOrderingConverges() {
        var tally = Tally()
        let started = Date()
        for initial in [StoreModel(), StoreModel(a: .addressed)] {
            var path: [Op] = []
            explore(World(initial), path: &path, tally: &tally)
        }
        print("VPNFlapTimer model check: \(Op.allCases.count) ops, depth \(Self.exhaustiveDepth), \(tally.summary), "
            + String(format: "%.1f s", Date().timeIntervalSince(started)))
        XCTAssertEqual(tally.examples, [])
        XCTAssertEqual(tally.orderings, 274_666, "the alphabet or the depth changed")
        assertEveryVerdictWasReached(tally)
    }

    /// Orderings six times as long as the exhaustive ones, drawn from a fixed
    /// seed, with the same checks after every op.
    func testLongSeededOrderingsConverge() {
        var tally = Tally()
        var generator = SeededGenerator(state: Self.randomSeed)
        let started = Date()
        for run in 0..<Self.randomOrderings {
            var world = World(run.isMultiple(of: 2) ? StoreModel() : StoreModel(a: .addressed))
            var path: [Op] = []
            while path.count < Self.randomDepth {
                let op = Op.allCases.randomElement(using: &generator)!
                guard world.apply(op) else { continue }
                path.append(op)
                check(world, path: path, tally: &tally)
            }
            tally.orderings += 1
        }
        print("VPNFlapTimer seeded check: depth \(Self.randomDepth), \(tally.summary), "
            + String(format: "%.1f s", Date().timeIntervalSince(started)))
        XCTAssertEqual(tally.examples, [])
        assertEveryVerdictWasReached(tally)
    }

    private func assertEveryVerdictWasReached(_ tally: Tally, file: StaticString = #filePath, line: UInt = #line) {
        for verdict in ["connected", "disconnected unknown", "disconnected userInitiated", "disconnected networkLost"] {
            XCTAssertGreaterThan(tally.settled[verdict, default: 0], 0, "no session settled on \(verdict)", file: file, line: line)
        }
        for kind in [Self.overdueUnderANewWindow, Self.ipv4OnlyTunnel, Self.recoveryUnderANewWindow] {
            XCTAssertGreaterThan(tally.reached[kind, default: 0], 0, "no state had \(kind)", file: file, line: line)
        }
    }

    private static let overdueUnderANewWindow = "an overdue deadline under a new window"
    private static let ipv4OnlyTunnel = "an IPv4-only tunnel"
    private static let recoveryUnderANewWindow = "a blind gap ended under a window changed during it"

    private func explore(_ world: World, path: inout [Op], tally: inout Tally) {
        check(world, path: path, tally: &tally)
        guard path.count < Self.exhaustiveDepth else {
            tally.orderings += 1
            return
        }
        for op in Op.allCases {
            var next = world
            guard next.apply(op) else { continue }
            path.append(op)
            explore(next, path: &path, tally: &tally)
            path.removeLast()
        }
    }

    private func check(_ world: World, path: [Op], tally: inout Tally) {
        tally.states += 1
        let store = world.store, now = world.now, window = world.window
        let settledLabel = store.isUp ? "connected" : "disconnected"

        let fresh = LevelSession(store, now: now, window: window)
        let counting = store.counting
        let freshWant = store.isUp
            ? VPNDetection(phase: .up, carrying: counting, live: counting, deadline: nil)
            : VPNDetection(phase: .down(.unknown), carrying: [], live: [], deadline: nil)
        if fresh.detection != freshWant { tally.fail("a fresh session reads \(fresh.detection)", path) }

        guard let session = world.session else { return }
        if let fault = session.fault { tally.fail(fault, path) }
        if store.b == .ipv4Only { tally.reached[Self.ipv4OnlyTunnel, default: 0] += 1 }
        if let deadline = session.detection.deadline, deadline <= now, session.history.last?.window != window {
            tally.reached[Self.overdueUnderANewWindow, default: 0] += 1
        }

        if !world.stale {
            let detection = session.detection
            if store.isUp, detection.phase != .up { tally.fail("a counting tunnel reads \(detection.phase)", path) }
            if detection.state == .unknown { tally.fail("a store that was read reads unknown", path) }
            var settling = session
            // One per debounce still running, and one for grace.
            if settling.advance(store, from: now, to: .infinity, window: window) > detection.live.count + 1 {
                tally.fail("more deadlines than windows to settle", path)
            }
            if let fault = settling.fault { tally.fail("settling: \(fault)", path) }
            if settling.detection.state.eventLabel != settledLabel {
                tally.fail("settled on \(settling.detection.state), want \(settledLabel)", path)
            }
            switch settling.detection.phase {
            case .down(let reason): tally.settled["disconnected \(reason)", default: 0] += 1
            default: tally.settled[settling.detection.state.eventLabel, default: 0] += 1
            }
        }

        // One more reading, whatever prompted it, is enough after any loss
        // and after any failed read.
        var audited = session
        audited.reconcile(store, now: now, window: window)
        var timer = audited.timer
        let again = timer.reconcile(store.reading, now: now, window: window)
        if again != audited.detection || timer != audited.timer { tally.fail("a repeated reading changed something", path) }
        if let deadline = audited.detection.deadline, deadline <= now || deadline > now + Windows.longest {
            tally.fail("a deadline at \(deadline) from \(now)", path)
        }
        audited.advance(store, from: now, to: .infinity, window: window)
        if let fault = audited.fault { tally.fail("after one more reading: \(fault)", path) }
        if audited.detection.state.eventLabel != settledLabel {
            tally.fail("after one more reading settled on \(audited.detection.state), want \(settledLabel)", path)
        }

        // A blind gap here, ended under each window and at each wait.
        var blinded = session
        blinded.reconcile(store, now: now, window: window, readable: false)
        if let fault = blinded.fault { tally.fail(fault, path) }
        for (gap, after) in [(0.4, Windows.wide), (2, Windows.immediate), (10, Windows.standard)] {
            var recovered = blinded
            recovered.reconcile(store, now: now + gap, window: after)
            recovered.advance(store, from: now + gap, to: .infinity, window: after)
            if let fault = recovered.fault { tally.fail("after a blind gap: \(fault)", path) }
            if recovered.recoveredUnderANewWindow { tally.reached[Self.recoveryUnderANewWindow, default: 0] += 1 }
            if recovered.detection.state.eventLabel != settledLabel {
                tally.fail("after a blind gap settled on \(recovered.detection.state), want \(settledLabel)", path)
            }
        }
    }
}
