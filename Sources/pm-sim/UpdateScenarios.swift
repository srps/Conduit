// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel

/// The app's update policy (#111) over fakes and a virtual clock: three
/// simulated days of automatic checks, a relaunch on a new version, the
/// updater's reports (well formed, malformed, and another copy's), and a
/// build that cannot update itself. The updater process and Sparkle are
/// covered end to end by scripts/test-updater-e2e.sh.
enum UpdateScenarios {
    /// Advances a virtual clock by each requested sleep, for a fixed number
    /// of sleeps, then parks until cancelled.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        private var _requested: [TimeInterval] = []
        private let budget: Int

        init(start: Date, budget: Int) {
            _now = start
            self.budget = budget
        }

        var now: Date { lock.withLock { _now } }
        var requested: [TimeInterval] { lock.withLock { _requested } }

        func sleep(_ seconds: TimeInterval) async throws {
            let advance: Bool = lock.withLock {
                _requested.append(seconds)
                guard _requested.count <= budget else { return false }
                _now = _now.addingTimeInterval(seconds)
                return true
            }
            if advance { return }
            // Out of budget: wait to be cancelled by stop().
            while true {
                try await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    @MainActor
    static func coordinator() async throws -> ScenarioResult {
        let name = "update-coordinator"
        let began = Date()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-sim-update-\(UUID().uuidString)", isDirectory: true)
        ScenarioCleanup.register {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch CocoaError.fileNoSuchFile {
                // Nothing was written.
            } catch {
                ConsoleLogSink().log(.warning, "pm-sim could not remove \(directory.path): \(error.localizedDescription)", category: .general)
            }
        }
        let host = "/Applications/Conduit.app"
        let store = UpdateStateStore(file: directory.appendingPathComponent("update-state.json"))
        try store.save(UpdateState(lastLaunchedVersion: "0.4.1"))
        let clock = VirtualClock(start: Date(timeIntervalSince1970: 2_000_000_000), budget: 3)
        let launcher = FakeUpdaterLauncher()
        let reports = FakeUpdateReports()
        var events: [RuntimeEvent] = []
        var notes: [String] = []

        let coordinator = UpdateCoordinator(
            hostIdentifier: "io.github.srps.Conduit", hostPath: host, currentVersion: "0.5.0",
            availability: .available, launcher: launcher, store: store, reports: reports,
            now: { clock.now }, sleep: { try await clock.sleep($0) },
            record: { events.append($0) }
        )
        coordinator.start(automaticChecks: true)

        // Three simulated days: the launch delay, then two full intervals.
        for _ in 0..<10_000 where clock.requested.count < 4 { await Task.yield() }
        let scheduled = launcher.starts
        let delays = clock.requested
        notes.append("starts=\(scheduled.map(\.rawValue)) delays=\(delays)")

        reports.deliver(UpdaterContract.reportUserInfo(.installing, detail: "version=9.9.9", hostPath: "/tmp/conduit-dev/Conduit.app"))
        let afterOtherHost = events.count
        reports.deliver([UpdaterContract.Key.hostPath: host, UpdaterContract.Key.report: "update.quit_now"])
        reports.deliver(UpdaterContract.reportUserInfo(.available, detail: "version=0.6.0", hostPath: host))
        coordinator.stop()
        let afterStop = events.count
        reports.deliver(UpdaterContract.reportUserInfo(.upToDate, detail: nil, hostPath: host))

        // A build without the update key: nothing starts, whatever is asked.
        let lockedLauncher = FakeUpdaterLauncher()
        var lockedEvents: [RuntimeEvent] = []
        let locked = UpdateCoordinator(
            hostIdentifier: "io.github.srps.Conduit", hostPath: host, currentVersion: "0.5.0",
            availability: .unavailable(reason: "this build has no update signing key"),
            launcher: lockedLauncher,
            store: UpdateStateStore(file: directory.appendingPathComponent("locked-state.json")),
            reports: FakeUpdateReports(), now: { clock.now }, sleep: { try await clock.sleep($0) },
            record: { lockedEvents.append($0) }
        )
        locked.start(automaticChecks: true)
        await locked.check(.interactive, source: .user)
        locked.stop()

        let count = { (event: String) in events.filter { $0.event == event }.count }
        return ScenarioResult(
            name: name, clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the new version is recorded once: lifecycle.version_changed from=0.4.1 to=0.5.0",
                      events.filter { $0.event == "lifecycle.version_changed" }.map(\.detail) == ["from=0.4.1 to=0.5.0"]),
                .init("three simulated days make three background checks and nothing interactive",
                      scheduled == [.background, .background, .background]),
                .init("the first waits for the launch delay, the rest a day apart",
                      Array(delays.prefix(3)) == [UpdateCheckSchedule.launchDelay, UpdateCheckSchedule.interval, UpdateCheckSchedule.interval]),
                .init("each check is one update.check_requested source=schedule",
                      events.filter { $0.event == "update.check_requested" }.map(\.detail) == Array(repeating: "source=schedule", count: 3)),
                .init("the last check is persisted", store.load().state.lastCheck == clock.now),
                .init("another copy's report is ignored without an event", afterOtherHost == events.count - 2),
                .init("a malformed report is one update.report_rejected", count("update.report_rejected") == 1),
                .init("a valid report becomes its event and the status",
                      count("update.available") == 1 && coordinator.status.lastReport?.report == .available),
                .init("nothing is handled after stop", events.count == afterStop),
                .init("a build without the key never starts the updater",
                      lockedLauncher.starts.isEmpty && lockedEvents.contains { $0.event == "update.check_unavailable" }),
            ],
            notes: notes
        )
    }
}
