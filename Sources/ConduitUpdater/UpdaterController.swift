import AppKit
import ConduitShared
import os
import Sparkle

private let logger = Logger(subsystem: "io.github.srps.Conduit", category: "updater")

/// Owns the one `SPUUpdater`, aimed at the app this updater is nested in.
@MainActor
final class UpdaterController: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    /// A background check that finds nothing exits on its own; this bounds
    /// one that hangs (Sparkle's own request timeouts are per request).
    private static let backgroundCheckLimit: Duration = .seconds(300)
    /// How long a hand-off waits for the owning updater: 50 × 100 ms.
    private static let handOffReadinessPolls = 50

    private let initialMode: UpdaterContract.LaunchMode
    private let autoInstall: Bool
    private var hostBundle: Bundle?
    private var updater: SPUUpdater?
    private var userDriver: (any SPUUserDriver)?
    private var foundUpdate = false
    /// Set once a failure is reported, so the cycle's own error is not a duplicate.
    private var reportedFailure = false
    private var handedOff = false
    /// What to check once Sparkle is up: the launch argument, upgraded to
    /// interactive if the user asks while this process is still starting.
    private var startupMode: UpdaterContract.LaunchMode

    init(mode: UpdaterContract.LaunchMode, autoInstall: Bool) {
        self.initialMode = mode
        self.startupMode = mode
        self.autoInstall = autoInstall
    }

    /// The check observer is registered here, before the process counts as
    /// finished launching: the app hands a request to a running updater only
    /// once `isFinishedLaunching` is true, so no request falls in a gap.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let hostURL = UpdaterContract.hostURL(containing: Bundle.main.bundleURL)
        guard let host = Bundle(url: hostURL), let hostIdentifier = host.bundleIdentifier,
              host.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              host.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            // Nothing to report to: report names need the host's identifier.
            logger.fault("No updatable host app at \(hostURL.path, privacy: .public): it needs a bundle identifier, SUFeedURL and SUPublicEDKey")
            exit(EX_CONFIG)
        }
        hostBundle = host

        if handOffToRunningUpdater(hostIdentifier: hostIdentifier) {
            handedOff = true
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: UpdaterContract.checkNotification(hostIdentifier: hostIdentifier),
            object: nil, queue: .main
        ) { [weak self] note in
            // Parsed here: userInfo is not Sendable, the mode is.
            let hostPath = host.bundlePath
            guard let mode = UpdaterContract.parseCheck(note.userInfo, hostPath: hostPath) else { return }
            MainActor.assumeIsolated { self?.check(mode) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A hand-off terminates once its request is posted.
        guard !handedOff, let host = hostBundle else { return }
        var driver: any SPUUserDriver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        #if DEBUG
        if autoInstall { driver = AutoInstallUserDriver() }
        #endif
        userDriver = driver
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            report(.failed, detail: "reason=start \(Self.describe(error))")
            NSApp.terminate(nil)
            return
        }
        check(startupMode)
    }

    /// One updater per host. A newcomer hands its request to an updater that
    /// is already up, or, when two start together, to the one with the lower
    /// pid, so two newcomers can never hand off to each other and both exit.
    private func handOffToRunningUpdater(hostIdentifier: String) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: UpdaterContract.bundleIdentifier)
            .filter { $0.processIdentifier != me && $0.bundleURL.map { UpdaterContract.samePath($0.path, Bundle.main.bundlePath) } == true }
        guard let owner = others.first(where: \.isFinishedLaunching)
                ?? others.filter({ $0.processIdentifier < me }).min(by: { $0.processIdentifier < $1.processIdentifier }),
              let host = hostBundle else { return false }
        let request = [UpdaterContract.Key.hostPath: host.bundlePath, UpdaterContract.Key.mode: initialMode.rawValue]
        let name = UpdaterContract.checkNotification(hostIdentifier: hostIdentifier)
        let mode = initialMode.rawValue
        // The owner listens once it is finishing its launch; post only then,
        // or the request could reach no one. Bounded like the app's hand-off.
        Task { @MainActor in
            for _ in 0..<Self.handOffReadinessPolls where !owner.isFinishedLaunching && !owner.isTerminated {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break  // cancelled: exiting anyway
                }
            }
            if owner.isFinishedLaunching && !owner.isTerminated {
                DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: request, deliverImmediately: true)
                logger.info("Updater already running (pid \(owner.processIdentifier)); passed the \(mode, privacy: .public) request on")
            } else {
                logger.error("The running updater (pid \(owner.processIdentifier)) never finished starting; the \(mode, privacy: .public) request was not passed on")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private func check(_ mode: UpdaterContract.LaunchMode) {
        guard let updater else {
            // Still starting: the first check happens once Sparkle is up.
            if mode == .interactive { startupMode = .interactive }
            return
        }
        switch mode {
        case .interactive:
            NSApp.activate()
            updater.checkForUpdates()
        case .background:
            updater.checkForUpdatesInBackground()
            Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.backgroundCheckLimit)
                } catch {
                    return  // cancelled: the process is exiting anyway
                }
                guard let self, !self.foundUpdate else { return }
                self.report(.failed, detail: "reason=background_check_timeout")
                NSApp.terminate(nil)
            }
        }
    }

    private func report(_ report: UpdaterContract.Report, detail: String?) {
        if report == .failed { reportedFailure = true }
        guard let host = hostBundle, let identifier = host.bundleIdentifier else { return }
        logger.notice("\(report.rawValue, privacy: .public) \(detail ?? "", privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            UpdaterContract.reportNotification(hostIdentifier: identifier), object: nil,
            userInfo: UpdaterContract.reportUserInfo(report, detail: detail, hostPath: host.bundlePath),
            deliverImmediately: true
        )
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain):\(error.code) \(error.localizedDescription)"
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            foundUpdate = true
            report(.available, detail: "version=\(version)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { report(.upToDate, detail: nil) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // "No update" arrives here too, already reported as up to date.
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)) else { return }
        let detail = "reason=\(Self.describe(error))"
        MainActor.assumeIsolated { report(.failed, detail: detail) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { report(.installing, detail: "version=\(version)") }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // The installer, if one was started, is Sparkle's own process and
        // carries on without this one. A cycle error nothing has reported
        // yet is reported here rather than lost with the process.
        let detail: String? = error.flatMap { error in
            let nsError = error as NSError
            guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)) else { return nil }
            return "reason=cycle \(Self.describe(error))"
        }
        MainActor.assumeIsolated {
            if let detail, !reportedFailure { report(.failed, detail: detail) }
            NSApp.terminate(nil)
        }
    }
}

#if DEBUG
/// Says yes to everything, for the end-to-end script. Debug builds only.
@MainActor
final class AutoInstallUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        logger.error("Updater error: \(String(describing: error), privacy: .public)")
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}
#endif
