// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import PlatformMac
@testable import ProxyKernel

/// The retry policy for a failed re-apply of an advertised surface (#194),
/// with a scripted host. Delays are zero: the scenarios count attempts and
/// read events, they do not time anything.
@MainActor
final class ConfigReapplyRetryTests: XCTestCase {
    private var events: [String] = []
    private var lane: LifecycleLane!
    private var retry: ConfigReapplyRetry!
    private var verdicts: [ConfigReapplyRetry.Outcome] = []
    private var attempts: [ConfigReapplyRetry.Surface] = []
    /// Runs inside an attempt, before its verdict is returned.
    private var duringAttempt: (() -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        events = []
        verdicts = []
        attempts = []
        duringAttempt = nil
        lane = LifecycleLane(name: "proxy")
        make(delays: [.zero, .zero, .zero])
    }

    override func tearDown() async throws {
        retry.cancelAll()
        try await super.tearDown()
    }

    private func make(delays: [Duration]) {
        retry = ConfigReapplyRetry(schedule: .init(delays: delays)) { [weak self] event, _ in
            self?.events.append("\(event.event) \(event.detail ?? "")")
        }
        retry.attempt = { [weak self] surface, _ in
            guard let self else { return .notWanted(reason: "gone") }
            self.attempts.append(surface)
            self.duringAttempt?()
            return self.verdicts.isEmpty ? .failed(reason: "still") : self.verdicts.removeFirst()
        }
    }

    private func fail(_ surface: ConfigReapplyRetry.Surface = .systemProxy, reason: String = "refused") {
        retry.failed(surface, cause: .configChange, reason: reason, token: lane.observationToken)
    }

    func testAFailureIsReportedAndRecoversOnALaterAttempt() async {
        verdicts = [.failed(reason: "not_applied"), .applied]
        fail()
        await retry.drain()

        XCTAssertEqual(events, [
            "config.reapply_failed surface=system_proxy cause=config_change retry_in_seconds=0 attempts=3 reason=refused",
            "config.reapply_retry surface=system_proxy attempt=1 of=3",
            "config.reapply_failed surface=system_proxy cause=retry attempt=1 of=3 retry_in_seconds=0 reason=not_applied",
            "config.reapply_retry surface=system_proxy attempt=2 of=3",
            "config.reapply_recovered surface=system_proxy attempts=2",
        ])
        XCTAssertTrue(retry.pending.isEmpty)
    }

    func testARetryStopsAfterItsAttempts() async {
        fail(.environment)
        await retry.drain()

        XCTAssertEqual(attempts, [.environment, .environment, .environment])
        XCTAssertEqual(events.suffix(2), [
            "config.reapply_failed surface=environment cause=retry attempt=3 of=3 reason=still",
            "config.reapply_abandoned surface=environment reason=exhausted attempts=3",
        ])
        XCTAssertTrue(retry.pending.isEmpty)
    }

    /// A start or stop since the failure owns the surface.
    func testAStartOrStopSinceTheFailureAbandonsWithoutAnAttempt() async {
        fail()
        guard case .run(let token) = lane.begin(.stop) else { return XCTFail("admitted") }
        lane.end(token)
        await retry.drain()

        XCTAssertEqual(attempts, [])
        XCTAssertEqual(events.last, "config.reapply_abandoned surface=system_proxy reason=superseded attempts=0")
    }

    func testAnAttemptOvertakenByAStartIsNotCountedAsRecovered() async {
        verdicts = [.applied]
        duringAttempt = { [unowned self] in
            guard case .run(let token) = self.lane.begin(.start) else { return XCTFail("admitted") }
            self.lane.end(token)
        }
        fail()
        await retry.drain()

        XCTAssertEqual(events.last, "config.reapply_abandoned surface=system_proxy reason=superseded attempts=1")
    }

    func testASwitchTurnedOffAbandonsWithItsReason() async {
        verdicts = [.notWanted(reason: "switch_off")]
        fail()
        await retry.drain()

        XCTAssertEqual(events.last, "config.reapply_abandoned surface=system_proxy reason=switch_off attempts=1")
    }

    /// A newer failure replaces the request: the verdict of the attempt it
    /// overtook is dropped, and the schedule starts again. One worker per
    /// surface throughout.
    func testANewerFailureDuringAnAttemptDropsTheOlderVerdict() async {
        verdicts = [.applied, .applied]
        duringAttempt = { [unowned self] in
            if self.attempts.count == 1 { self.fail(reason: "again") }
        }
        fail()
        await retry.drain()

        XCTAssertEqual(attempts, [.systemProxy, .systemProxy])
        XCTAssertEqual(events, [
            "config.reapply_failed surface=system_proxy cause=config_change retry_in_seconds=0 attempts=3 reason=refused",
            "config.reapply_retry surface=system_proxy attempt=1 of=3",
            "config.reapply_failed surface=system_proxy cause=config_change retry_in_seconds=0 attempts=3 reason=again",
            "config.reapply_result_superseded surface=system_proxy attempt=1 outcome=applied",
            "config.reapply_retry surface=system_proxy attempt=1 of=3",
            "config.reapply_recovered surface=system_proxy attempts=1",
        ])
    }

    /// A newer failure does not wait out the old request's long delay: its
    /// own schedule starts at once.
    func testANewerFailureWakesAWorkerAsleepOnALongDelay() async {
        make(delays: [.zero, .seconds(3600), .zero])
        verdicts = [.failed(reason: "not_applied"), .applied]
        fail()
        for _ in 0..<10_000 where !events.contains(where: { $0.contains("cause=retry attempt=1") }) {
            await Task.yield()
        }
        XCTAssertEqual(attempts.count, 1, "the first attempt failed; the worker sleeps an hour")

        fail(reason: "again")
        // Counted, not timed: without the wake the worker sleeps an hour.
        for _ in 0..<10_000 where events.last?.hasPrefix("config.reapply_recovered") != true {
            await Task.yield()
        }

        XCTAssertEqual(events.last, "config.reapply_recovered surface=system_proxy attempts=1")
    }

    func testSurfacesRetryIndependently() async {
        verdicts = [.applied, .applied]
        fail(.systemProxy)
        fail(.environment)
        XCTAssertEqual(retry.pending, [.systemProxy, .environment])
        await retry.drain()

        XCTAssertEqual(Set(attempts), [.systemProxy, .environment])
        XCTAssertEqual(events.filter { $0.hasPrefix("config.reapply_recovered") }.count, 2)
    }

    /// At teardown nothing more runs and nothing more is reported.
    func testCancelAllDropsWhatIsOutstandingQuietly() async {
        make(delays: [.seconds(3600)])
        fail()
        retry.cancelAll()
        await retry.drain()

        XCTAssertEqual(attempts, [])
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(retry.pending.isEmpty)
    }

    /// The system-proxy attempt reads the switch the last save asked for
    /// under the manager's lock: a flag action runs on the main actor, not
    /// on the platform queue, and its clear must not be undone by a retry
    /// queued before it.
    func testTheSystemProxyAttemptLeavesASwitchTurnedOffAlone() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reapply-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver", isDirectory: true))
        let manager = SystemProxyManager(
            privilegeClient: machine,
            journal: PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json")),
            commandRunner: { try machine.run($0, $1) },
            portProbe: { _ in false }
        )
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 3128
        let on = PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .manual)
        var off = on
        off.manageSystemProxy = false
        let work = PlatformWork(label: "reapply-test")
        let eventLog = RuntimeEventLog(capacity: 16)

        let fence = PlatformRequestFence(off)
        let (outcome, retryAfter) = await SystemProxyReapplyRetry.run(
            manager: manager, work: work, config: config, mode: .manual, localPACURL: nil,
            token: lane.observationToken, fence: fence, events: eventLog, logger: DiscardingLogSink())
        XCTAssertEqual(outcome, .notWanted(reason: "switch_changed"))
        XCTAssertNil(retryAfter)
        XCTAssertFalse(machine.service("Wi-Fi").routesThroughAProxy)

        var pac = on
        pac.systemProxyMode = .pac
        let (moved, _) = await SystemProxyReapplyRetry.run(
            manager: manager, work: work, config: config, mode: .manual, localPACURL: nil,
            token: lane.observationToken, fence: PlatformRequestFence(pac), events: eventLog, logger: DiscardingLogSink())
        XCTAssertEqual(moved, .notWanted(reason: "switch_changed"), "the mode moved since")
        XCTAssertTrue(machine.privilege.commands.isEmpty, "nothing written")
    }
}
