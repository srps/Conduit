// SPDX-License-Identifier: Apache-2.0
import AppKit
import ConduitShared
import Foundation
import ProxyKernel

// The host side of self-updating (#111). Sparkle itself runs in the nested
// "Conduit Updater" process (see `UpdaterContract`); here is what the app
// owns: starting that process, the daily background check, turning the
// updater's reports into events, and noticing at launch that the version
// changed. Installing is Sparkle's: it quits the app with a normal quit event,
// so the termination cleanup restores proxy and DNS settings first.

// MARK: - Starting the updater

package enum UpdaterLaunchOutcome: Equatable, Sendable {
    case launched
    /// An updater was already running; it got the request instead.
    case handedOff
}

package struct UpdaterLaunchError: Error, Equatable, LocalizedError {
    package var reason: String
    package init(_ reason: String) { self.reason = reason }
    package var errorDescription: String? { reason }
}

/// Starts the nested updater, or hands a request to the one already running.
/// A seam because it launches a real process: a `--dev` instance or a test
/// host would otherwise start the installed app's updater. The fake is
/// `FakeUpdaterLauncher`.
package protocol UpdaterLaunching: Sendable {
    func start(_ mode: UpdaterContract.LaunchMode) async throws -> UpdaterLaunchOutcome
}

/// The real one, for the app bundle at `hostURL`.
package struct SystemUpdaterLauncher: UpdaterLaunching {
    /// How long a hand-off waits for a starting updater: 50 × 100 ms.
    private static let handOffReadinessPolls = 50

    private let hostURL: URL
    private let hostIdentifier: String

    package init(hostURL: URL, hostIdentifier: String) {
        self.hostURL = hostURL
        self.hostIdentifier = hostIdentifier
    }

    package func start(_ mode: UpdaterContract.LaunchMode) async throws -> UpdaterLaunchOutcome {
        let updaterURL = UpdaterContract.updaterURL(inHost: hostURL)
        guard FileManager.default.fileExists(atPath: updaterURL.path) else {
            throw UpdaterLaunchError("no updater at \(updaterURL.path)")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: UpdaterContract.bundleIdentifier)
            .first { $0.bundleURL.map { UpdaterContract.samePath($0.path, updaterURL.path) } == true }
        if let running {
            // The updater listens from applicationWillFinishLaunching on;
            // before isFinishedLaunching a request could find no listener.
            for _ in 0..<Self.handOffReadinessPolls where !running.isFinishedLaunching && !running.isTerminated {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !running.isTerminated else {
                throw UpdaterLaunchError("the running updater exited before it could take the request; try again")
            }
            guard running.isFinishedLaunching else {
                throw UpdaterLaunchError("the running updater did not finish starting within 5 s; try again")
            }
            DistributedNotificationCenter.default().postNotificationName(
                UpdaterContract.checkNotification(hostIdentifier: hostIdentifier), object: nil,
                userInfo: [UpdaterContract.Key.hostPath: hostURL.path, UpdaterContract.Key.mode: mode.rawValue],
                deliverImmediately: true
            )
            return .handedOff
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [mode.rawValue]
        configuration.activates = mode == .interactive
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: updaterURL, configuration: configuration)
        } catch {
            throw UpdaterLaunchError("could not start the updater: \(error.localizedDescription)")
        }
        return .launched
    }
}

/// Whether this build can update itself, read from the host's Info.plist and
/// bundle. A build without a release key (a fresh checkout, a fork) cannot.
package enum UpdaterAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    package static func of(hostBundle: Bundle) -> UpdaterAvailability {
        guard hostBundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            return .unavailable(reason: "this build has no update signing key")
        }
        guard hostBundle.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            return .unavailable(reason: "this build has no update feed")
        }
        let updater = UpdaterContract.updaterURL(inHost: hostBundle.bundleURL)
        guard FileManager.default.fileExists(atPath: updater.path) else {
            return .unavailable(reason: "this build has no updater")
        }
        return .available
    }
}

// MARK: - Reports from the updater

/// Delivers the updater's reports, already validated against the contract.
/// Production listens to distributed notifications; the fake lets a test or
/// scenario deliver any userInfo, spoofed ones included.
@MainActor
package protocol UpdateReportSource: AnyObject {
    func subscribe(
        hostIdentifier: String,
        hostPath: String,
        _ handler: @escaping @MainActor (Result<UpdaterContract.ParsedReport, UpdaterContract.Rejection>) -> Void
    )
    func cancel()
}

@MainActor
package final class DistributedUpdateReports: UpdateReportSource {
    private var observer: (any NSObjectProtocol)?

    package init() {}

    package func subscribe(
        hostIdentifier: String,
        hostPath: String,
        _ handler: @escaping @MainActor (Result<UpdaterContract.ParsedReport, UpdaterContract.Rejection>) -> Void
    ) {
        cancel()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: UpdaterContract.reportNotification(hostIdentifier: hostIdentifier),
            object: nil, queue: .main
        ) { note in
            // Parsed here: userInfo is not Sendable, the result is.
            let result = UpdaterContract.parseReport(note.userInfo, hostPath: hostPath)
            MainActor.assumeIsolated { handler(result) }
        }
    }

    package func cancel() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}

// MARK: - Persisted state

/// When a check last started and which version last launched. A file beside
/// the config (`RuntimeEnvironment.updateStateFile`), in canonical JSON.
package struct UpdateState: Codable, Equatable, Sendable {
    package var lastCheck: Date?
    package var lastLaunchedVersion: String?

    package init(lastCheck: Date? = nil, lastLaunchedVersion: String? = nil) {
        self.lastCheck = lastCheck
        self.lastLaunchedVersion = lastLaunchedVersion
    }
}

package struct UpdateStateStore: Sendable {
    package let file: URL

    package init(file: URL) {
        self.file = file
    }

    /// The saved state; a missing file is a fresh install. An unreadable one
    /// comes back as the reason, with an empty state to carry on from.
    package func load() -> (state: UpdateState, problem: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return (UpdateState(), nil)
        } catch {
            return (UpdateState(), "cannot read \(file.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            return (try CanonicalJSON.decoder().decode(UpdateState.self, from: data), nil)
        } catch {
            return (UpdateState(), "cannot decode \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    package func save(_ state: UpdateState) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CanonicalJSON.encoder().encode(state).write(to: file, options: .atomic)
    }
}

// MARK: - Schedule

/// When the next background check is due: daily, and never sooner than a
/// while after launch, so a login does not contend with VPN and proxy setup.
package enum UpdateCheckSchedule {
    package static let interval: TimeInterval = 24 * 60 * 60
    package static let launchDelay: TimeInterval = 10 * 60

    /// Nil when automatic checks are off.
    package static func nextCheck(enabled: Bool, lastCheck: Date?, launchedAt: Date) -> Date? {
        guard enabled else { return nil }
        let earliest = launchedAt.addingTimeInterval(launchDelay)
        guard let lastCheck else { return earliest }
        return max(lastCheck.addingTimeInterval(interval), earliest)
    }
}

// MARK: - Coordinator

/// The app's update policy, shared by any host that bundles the updater.
@MainActor
package final class UpdateCoordinator {
    package struct Status: Equatable, Sendable {
        package var availability: UpdaterAvailability
        package var lastCheck: Date?
        /// The latest report, for Settings: `update.available`, `version=…`.
        package var lastReport: UpdaterContract.ParsedReport?
    }

    package enum Source: String, Sendable {
        case user
        case schedule
    }

    private let hostIdentifier: String
    private let hostPath: String
    private let currentVersion: String
    private let launcher: any UpdaterLaunching
    private let store: UpdateStateStore
    private let reports: any UpdateReportSource
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let record: @MainActor (RuntimeEvent) -> Void
    private let launchedAt: Date
    private var state = UpdateState()
    private var automaticChecks = false
    private var scheduled: Task<Void, Never>?

    package private(set) var status: Status {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    package var onStatus: (@MainActor (Status) -> Void)?

    package init(
        hostIdentifier: String,
        hostPath: String,
        currentVersion: String,
        availability: UpdaterAvailability,
        launcher: any UpdaterLaunching,
        store: UpdateStateStore,
        reports: any UpdateReportSource,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        record: @escaping @MainActor (RuntimeEvent) -> Void
    ) {
        self.hostIdentifier = hostIdentifier
        self.hostPath = hostPath
        self.currentVersion = currentVersion
        self.launcher = launcher
        self.store = store
        self.reports = reports
        self.now = now
        self.sleep = sleep
        self.record = record
        self.launchedAt = now()
        self.status = Status(availability: availability, lastCheck: nil, lastReport: nil)
    }

    /// At launch: notes a version change, listens for reports and, when
    /// automatic checks are on, schedules the next one.
    package func start(automaticChecks: Bool) {
        let (loaded, problem) = store.load()
        if let problem {
            record(RuntimeEvent(kind: .lifecycle, event: "update.state_unreadable", detail: "reason=\(problem)"))
        }
        state = loaded
        status.lastCheck = loaded.lastCheck
        if let previous = loaded.lastLaunchedVersion, previous != currentVersion {
            record(RuntimeEvent(kind: .lifecycle, event: "lifecycle.version_changed", detail: "from=\(previous) to=\(currentVersion)"))
        }
        if loaded.lastLaunchedVersion != currentVersion {
            state.lastLaunchedVersion = currentVersion
            persist()
        }
        reports.subscribe(hostIdentifier: hostIdentifier, hostPath: hostPath) { [weak self] result in
            self?.receive(result)
        }
        setAutomaticChecks(automaticChecks)
    }

    package func stop() {
        scheduled?.cancel()
        scheduled = nil
        reports.cancel()
    }

    package func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        scheduled?.cancel()
        scheduled = nil
        guard enabled, status.availability == .available else { return }
        scheduleNext()
    }

    /// "Check for Updates…".
    package func checkNow() {
        Task { await check(.interactive, source: .user) }
    }

    /// One pending background check at a time; each one schedules the next.
    private func scheduleNext() {
        guard let due = UpdateCheckSchedule.nextCheck(enabled: automaticChecks, lastCheck: state.lastCheck, launchedAt: launchedAt) else { return }
        let delay = max(0, due.timeIntervalSince(now()))
        let sleep = self.sleep
        scheduled = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return  // cancelled: turned off, rescheduled or stopping
            }
            guard let self, !Task.isCancelled else { return }
            await self.check(.background, source: .schedule)
            guard !Task.isCancelled else { return }
            self.scheduleNext()
        }
    }

    package func check(_ mode: UpdaterContract.LaunchMode, source: Source) async {
        if case .unavailable(let reason) = status.availability {
            record(RuntimeEvent(kind: .lifecycle, event: "update.check_unavailable", detail: "source=\(source.rawValue) reason=\(reason)"))
            return
        }
        record(RuntimeEvent(kind: .lifecycle, event: "update.check_requested", detail: "source=\(source.rawValue)"))
        // Counted when asked, whatever the outcome: a failing feed is retried
        // at the next interval, not in a loop.
        state.lastCheck = now()
        status.lastCheck = state.lastCheck
        persist()
        // A check by hand counts as today's: the pending automatic one moves
        // a full interval on rather than following it within minutes.
        if source == .user, automaticChecks {
            scheduled?.cancel()
            scheduleNext()
        }
        do {
            let outcome = try await launcher.start(mode)
            if outcome == .handedOff {
                record(RuntimeEvent(kind: .lifecycle, event: "update.check_handed_off", detail: "source=\(source.rawValue)"))
            }
        } catch {
            let reason = "reason=\(error.localizedDescription)"
            record(RuntimeEvent(kind: .lifecycle, event: "update.launch_failed", detail: "source=\(source.rawValue) \(reason)"))
            // Settings shows the latest outcome beside "Last checked", so a
            // failure to start must replace an older result there.
            status.lastReport = UpdaterContract.ParsedReport(report: .failed, detail: reason)
        }
    }

    private func receive(_ result: Result<UpdaterContract.ParsedReport, UpdaterContract.Rejection>) {
        switch result {
        case .success(let parsed):
            status.lastReport = parsed
            record(RuntimeEvent(kind: .lifecycle, event: parsed.report.rawValue, detail: parsed.detail))
        case .failure(.otherHost):
            return  // another copy's updater; not ours to log
        case .failure(let rejection):
            record(RuntimeEvent(kind: .lifecycle, event: "update.report_rejected", detail: "reason=\(rejection)"))
        }
    }

    private func persist() {
        do {
            try store.save(state)
        } catch {
            record(RuntimeEvent(kind: .lifecycle, event: "update.state_unwritable", detail: "reason=\(error.localizedDescription)"))
        }
    }
}
