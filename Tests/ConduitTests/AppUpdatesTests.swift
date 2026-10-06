// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ConduitShared
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Contract

final class UpdaterContractTests: XCTestCase {
    private let host = "/Applications/Conduit.app"

    func testAWellFormedReportForThisHostParses() throws {
        let info = UpdaterContract.reportUserInfo(.available, detail: "version=0.5.0", hostPath: host)
        let parsed = try UpdaterContract.parseReport(info, hostPath: host).get()
        XCTAssertEqual(parsed, .init(report: .available, detail: "version=0.5.0"))
    }

    func testAReportForAnotherCopyIsIgnoredNotRejected() {
        let info = UpdaterContract.reportUserInfo(.upToDate, detail: nil, hostPath: "/tmp/conduit-dev/Conduit.app")
        XCTAssertEqual(UpdaterContract.parseReport(info, hostPath: host).failure, .otherHost)
    }

    func testMalformedReportsAreRejectedWithAReason() {
        XCTAssertEqual(UpdaterContract.parseReport(nil, hostPath: host).failure, .malformed("no host path"))
        XCTAssertEqual(
            UpdaterContract.parseReport([UpdaterContract.Key.hostPath: host], hostPath: host).failure,
            .malformed("no report name")
        )
        let unknown: [AnyHashable: Any] = [UpdaterContract.Key.hostPath: host, UpdaterContract.Key.report: "update.reinstall_helper"]
        XCTAssertEqual(UpdaterContract.parseReport(unknown, hostPath: host).failure, .malformed("unknown report update.reinstall_helper"))
    }

    func testDetailsAreCappedOnBothSides() throws {
        let long = String(repeating: "x", count: 4_000)
        let info = UpdaterContract.reportUserInfo(.failed, detail: long, hostPath: host)
        XCTAssertEqual(info[UpdaterContract.Key.detail]?.count, UpdaterContract.maxDetailLength)
        let spoofed: [AnyHashable: Any] = [UpdaterContract.Key.hostPath: host, UpdaterContract.Key.report: "update.failed", UpdaterContract.Key.detail: long]
        XCTAssertEqual(try UpdaterContract.parseReport(spoofed, hostPath: host).get().detail?.count, UpdaterContract.maxDetailLength)
    }

    func testHostPathsCompareAfterResolvingSymlinks() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("updater-contract-\(UUID().uuidString)")
        let real = directory.appendingPathComponent("Real.app")
        let link = directory.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(UpdaterContract.samePath(link.path, real.path))
        XCTAssertFalse(UpdaterContract.samePath(real.path, directory.path))
    }

    func testCheckRequestsNeedThisHostAndAKnownMode() {
        XCTAssertEqual(UpdaterContract.parseCheck([UpdaterContract.Key.hostPath: host, UpdaterContract.Key.mode: "--background"], hostPath: host), .background)
        XCTAssertNil(UpdaterContract.parseCheck([UpdaterContract.Key.hostPath: "/elsewhere/Conduit.app", UpdaterContract.Key.mode: "--check"], hostPath: host))
        XCTAssertNil(UpdaterContract.parseCheck([UpdaterContract.Key.hostPath: host, UpdaterContract.Key.mode: "--test-auto-install"], hostPath: host))
    }

    func testTheUpdaterFindsItsHostThreeLevelsUp() {
        let hostURL = URL(fileURLWithPath: host)
        XCTAssertEqual(UpdaterContract.hostURL(containing: UpdaterContract.updaterURL(inHost: hostURL)).path, host)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Schedule and state

final class UpdateCheckScheduleTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    func testOffMeansNoCheck() {
        XCTAssertNil(UpdateCheckSchedule.nextCheck(enabled: false, lastCheck: nil, launchedAt: launch))
    }

    func testTheFirstCheckWaitsForTheLaunchDelay() {
        XCTAssertEqual(
            UpdateCheckSchedule.nextCheck(enabled: true, lastCheck: nil, launchedAt: launch),
            launch.addingTimeInterval(UpdateCheckSchedule.launchDelay)
        )
    }

    func testARecentCheckDefersTheNextByTheInterval() {
        let last = launch.addingTimeInterval(-3_600)
        XCTAssertEqual(
            UpdateCheckSchedule.nextCheck(enabled: true, lastCheck: last, launchedAt: launch),
            last.addingTimeInterval(UpdateCheckSchedule.interval)
        )
    }

    func testAnOverdueCheckStillWaitsForTheLaunchDelay() {
        let last = launch.addingTimeInterval(-10 * UpdateCheckSchedule.interval)
        XCTAssertEqual(
            UpdateCheckSchedule.nextCheck(enabled: true, lastCheck: last, launchedAt: launch),
            launch.addingTimeInterval(UpdateCheckSchedule.launchDelay)
        )
    }
}

final class UpdateStateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("update-state-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAMissingFileIsAFreshInstall() {
        let (state, problem) = UpdateStateStore(file: directory.appendingPathComponent("update-state.json")).load()
        XCTAssertEqual(state, UpdateState())
        XCTAssertNil(problem)
    }

    func testAnUnreadableFileIsReportedAndStartsEmpty() throws {
        let file = directory.appendingPathComponent("update-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let (state, problem) = UpdateStateStore(file: file).load()
        XCTAssertEqual(state, UpdateState())
        XCTAssertNotNil(problem)
    }

    func testRoundTripUsesEpochSeconds() throws {
        let store = UpdateStateStore(file: directory.appendingPathComponent("update-state.json"))
        let state = UpdateState(lastCheck: Date(timeIntervalSince1970: 1_800_000_000), lastLaunchedVersion: "0.5.0")
        try store.save(state)
        XCTAssertEqual(store.load().state, state)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any]
        XCTAssertEqual(json?["lastCheck"] as? Double, 1_800_000_000)
    }
}

// MARK: - Coordinator

/// A sleep that parks until released or cancelled, so a test controls when
/// the scheduled check fires instead of waiting on the clock.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var _requested: [TimeInterval] = []

    var requested: [TimeInterval] { lock.withLock { _requested } }

    func sleep(_ seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    _requested.append(seconds)
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { waiters.removeAll() }
                return waiters
            }
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    /// Wakes the oldest sleeper.
    func fire() {
        let next = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        next?.resume()
    }
}

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var launcher: FakeUpdaterLauncher!
    private var reports: FakeUpdateReports!
    private var sleeper: ManualSleeper!
    private var events: [RuntimeEvent] = []
    private let host = "/Applications/Conduit.app"
    private let clock = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("update-coordinator-\(UUID().uuidString)")
        launcher = FakeUpdaterLauncher()
        reports = FakeUpdateReports()
        sleeper = ManualSleeper()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: UpdateStateStore { UpdateStateStore(file: directory.appendingPathComponent("update-state.json")) }

    private func coordinator(version: String = "0.5.0", availability: UpdaterAvailability = .available) -> UpdateCoordinator {
        let clock = self.clock
        let sleeper = self.sleeper!
        return UpdateCoordinator(
            hostIdentifier: "io.github.srps.Conduit",
            hostPath: host,
            currentVersion: version,
            availability: availability,
            launcher: launcher.launcher,
            store: store,
            reports: reports,
            now: { clock },
            sleep: { try await sleeper.sleep($0) },
            record: { [weak self] in self?.events.append($0) }
        )
    }

    private func names() -> [String] { events.map(\.event) }

    /// Yields until `condition` holds, a bounded number of times.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testFirstLaunchRecordsTheVersionWithoutAChangeEvent() {
        coordinator().start(automaticChecks: false)
        XCTAssertFalse(names().contains("lifecycle.version_changed"))
        XCTAssertEqual(store.load().state.lastLaunchedVersion, "0.5.0")
    }

    func testANewVersionIsReportedOnce() throws {
        try store.save(UpdateState(lastLaunchedVersion: "0.4.1"))
        coordinator().start(automaticChecks: false)
        XCTAssertEqual(events.filter { $0.event == "lifecycle.version_changed" }.map(\.detail), ["from=0.4.1 to=0.5.0"])
        events = []
        coordinator().start(automaticChecks: false)
        XCTAssertFalse(names().contains("lifecycle.version_changed"))
    }

    func testAnUnreadableStateFileIsAnEventNotASilentReset() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.file)
        coordinator().start(automaticChecks: false)
        XCTAssertTrue(names().contains("update.state_unreadable"))
    }

    func testCheckNowStartsTheInteractiveUpdaterAndRecordsTheCheck() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        await coordinator.check(.interactive, source: .user)
        XCTAssertEqual(launcher.starts, [.interactive])
        XCTAssertEqual(events.last?.event, "update.check_requested")
        XCTAssertEqual(events.last?.detail, "source=user")
        XCTAssertEqual(store.load().state.lastCheck, clock)
        XCTAssertEqual(coordinator.status.lastCheck, clock)
    }

    func testABuildWithoutAKeyNeverStartsTheUpdater() async {
        let coordinator = coordinator(availability: .unavailable(reason: "this build has no update signing key"))
        coordinator.start(automaticChecks: true)
        await coordinator.check(.interactive, source: .user)
        XCTAssertEqual(launcher.starts, [])
        XCTAssertTrue(sleeper.requested.isEmpty, "no background check is scheduled")
        XCTAssertEqual(names().last, "update.check_unavailable")
    }

    func testACheckByHandMovesThePendingAutomaticOne() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: true)
        await settle { sleeper.requested.count == 1 }
        XCTAssertEqual(sleeper.requested, [UpdateCheckSchedule.launchDelay])
        await coordinator.check(.interactive, source: .user)
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, UpdateCheckSchedule.interval, "the next automatic check is a day after this one")
        sleeper.fire()  // the cancelled launch-delay sleep is gone; this wakes the new one
        await settle { launcher.starts.count == 2 }
        XCTAssertEqual(launcher.starts, [.interactive, .background])
        coordinator.stop()
    }

    func testALaunchFailureReplacesTheShownResult() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        reports.deliver(UpdaterContract.reportUserInfo(.upToDate, detail: nil, hostPath: host))
        launcher.failure = "no updater at /x"
        await coordinator.check(.interactive, source: .user)
        XCTAssertEqual(coordinator.status.lastReport, .init(report: .failed, detail: "reason=no updater at /x"))
    }

    func testLaunchFailuresAndHandOffsAreEvents() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        launcher.failure = "no updater at /x"
        await coordinator.check(.interactive, source: .user)
        XCTAssertEqual(events.last?.event, "update.launch_failed")
        launcher.failure = nil
        launcher.outcome = .handedOff
        await coordinator.check(.interactive, source: .user)
        XCTAssertEqual(events.last?.event, "update.check_handed_off")
    }

    func testReportsBecomeEventsAndStatus() {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        reports.deliver(UpdaterContract.reportUserInfo(.available, detail: "version=0.6.0", hostPath: host))
        XCTAssertEqual(events.last?.event, "update.available")
        XCTAssertEqual(events.last?.detail, "version=0.6.0")
        XCTAssertEqual(coordinator.status.lastReport, .init(report: .available, detail: "version=0.6.0"))
    }

    func testOtherCopiesReportsAreIgnoredAndMalformedOnesRejected() {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        let before = events.count
        reports.deliver(UpdaterContract.reportUserInfo(.installing, detail: "version=9", hostPath: "/tmp/dev/Conduit.app"))
        XCTAssertEqual(events.count, before)
        reports.deliver([UpdaterContract.Key.hostPath: host, UpdaterContract.Key.report: "update.quit"])
        XCTAssertEqual(events.last?.event, "update.report_rejected")
    }

    func testTheScheduleChecksInTheBackgroundThenSchedulesTheNext() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: true)
        await settle { sleeper.requested.count == 1 }
        XCTAssertEqual(sleeper.requested, [UpdateCheckSchedule.launchDelay])
        sleeper.fire()
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(launcher.starts, [.background])
        XCTAssertTrue(events.contains { $0.event == "update.check_requested" && $0.detail == "source=schedule" })
        // The fake clock has not moved, so the next check is a full interval
        // after the one just made.
        XCTAssertEqual(sleeper.requested.last, UpdateCheckSchedule.interval)
        coordinator.stop()
    }

    func testTurningChecksOffCancelsThePendingOne() async {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: true)
        await settle { sleeper.requested.count == 1 }
        coordinator.setAutomaticChecks(false)
        sleeper.fire()  // nothing left to wake
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(launcher.starts, [])
    }

    func testStopUnsubscribesFromReports() {
        let coordinator = coordinator()
        coordinator.start(automaticChecks: false)
        XCTAssertTrue(reports.isSubscribed)
        coordinator.stop()
        XCTAssertFalse(reports.isSubscribed)
    }
}

// MARK: - Settings wording

final class UpdateStatusTextTests: XCTestCase {
    func testReportsReadAsSentences() {
        XCTAssertEqual(UpdateStatusText.describe(.init(report: .available, detail: "version=0.6.0")), "Version 0.6.0 is available")
        XCTAssertEqual(UpdateStatusText.describe(.init(report: .upToDate, detail: nil)), "Up to date")
        XCTAssertEqual(
            UpdateStatusText.describe(.init(report: .failed, detail: "reason=SUSparkleErrorDomain:2001 An error occurred")),
            "Check failed: SUSparkleErrorDomain:2001 An error occurred"
        )
    }
}
