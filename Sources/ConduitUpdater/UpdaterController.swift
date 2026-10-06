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

    private let initialMode: UpdaterContract.LaunchMode
    private let autoInstall: Bool
    private var hostBundle: Bundle?
    private var updater: SPUUpdater?
    private var userDriver: (any SPUUserDriver)?
    private var foundUpdate = false

    init(mode: UpdaterContract.LaunchMode, autoInstall: Bool) {
        self.initialMode = mode
        self.autoInstall = autoInstall
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            NSApp.terminate(nil)
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
        check(initialMode)
    }

    /// One updater per host: a second launch passes its request on and exits.
    private func handOffToRunningUpdater(hostIdentifier: String) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: UpdaterContract.bundleIdentifier)
            .filter { $0.processIdentifier != me && $0.bundleURL.map { UpdaterContract.samePath($0.path, Bundle.main.bundlePath) } == true }
        guard !others.isEmpty, let host = hostBundle else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            UpdaterContract.checkNotification(hostIdentifier: hostIdentifier), object: nil,
            userInfo: [UpdaterContract.Key.hostPath: host.bundlePath, UpdaterContract.Key.mode: initialMode.rawValue],
            deliverImmediately: true
        )
        logger.info("Updater already running; passed the \(self.initialMode.rawValue, privacy: .public) request on")
        return true
    }

    private func check(_ mode: UpdaterContract.LaunchMode) {
        guard let updater else { return }
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
        // carries on without this one.
        MainActor.assumeIsolated { NSApp.terminate(nil) }
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
