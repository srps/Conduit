import AppKit
import ConduitShared
import CryptoKit
import os
import Sparkle

private let logger = Logger(subsystem: "io.github.srps.Conduit", category: "updater")

/// Owns the one `SPUUpdater`, aimed at the app this updater is nested in.
@MainActor
final class UpdaterController: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    /// A background check that finds nothing exits on its own; this bounds
    /// one that hangs (Sparkle's own request timeouts are per request).
    private static let backgroundCheckLimit: Duration = .seconds(300)
    /// How long a finished updater lingers after releasing its lock, to
    /// take a request posted just before the release.
    private static let exitGrace: TimeInterval = 0.5

    private let initialMode: UpdaterContract.LaunchMode
    private let autoInstall: Bool
    private var hostBundle: Bundle?
    private var updater: SPUUpdater?
    private var userDriver: (any SPUUserDriver)?
    private var foundUpdate = false
    /// Set once a failure is reported, so the cycle's own error is not a duplicate.
    private var reportedFailure = false
    private var handedOff = false
    /// The ownership lock (see `acquireOwnership`); held until exit.
    private var lockDescriptor: Int32 = -1
    /// Set when the cycle is over and the lock released, until exit.
    private var exiting = false
    /// What to check once Sparkle is up: the launch argument, upgraded to
    /// interactive if the user asks while this process is still starting.
    private var startupMode: UpdaterContract.LaunchMode

    init(mode: UpdaterContract.LaunchMode, autoInstall: Bool) {
        self.initialMode = mode
        self.startupMode = mode
        self.autoInstall = autoInstall
    }

    /// One updater per host, chosen by an exclusive lock on a per-host file.
    /// Every process registers its check observer first and only then tries
    /// the lock, so a process that finds the lock taken knows its holder is
    /// already listening: it passes its request on and exits. No polling, and
    /// no ordering of arrivals can leave two owners or none.
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
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: UpdaterContract.checkNotification(hostIdentifier: hostIdentifier),
            object: nil, queue: .main
        ) { [weak self] note in
            // Parsed here: userInfo is not Sendable, the mode is.
            let hostPath = host.bundlePath
            guard let mode = UpdaterContract.parseCheck(note.userInfo, hostPath: hostPath) else { return }
            MainActor.assumeIsolated { self?.check(mode) }
        }
        switch acquireOwnership() {
        case .owner:
            break
        case .taken:
            DistributedNotificationCenter.default().removeObserver(observer)
            DistributedNotificationCenter.default().postNotificationName(
                UpdaterContract.checkNotification(hostIdentifier: hostIdentifier), object: nil,
                userInfo: [UpdaterContract.Key.hostPath: host.bundlePath, UpdaterContract.Key.mode: initialMode.rawValue],
                deliverImmediately: true
            )
            logger.info("Another updater owns this host; passed the \(self.initialMode.rawValue, privacy: .public) request on")
            handedOff = true
        case .failed(let reason):
            // Without the lock two updaters could race an install; refuse.
            report(.failed, detail: "reason=lock \(reason)")
            handedOff = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handedOff, let host = hostBundle else {
            NSApp.terminate(nil)
            return
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
        check(startupMode)
    }

    private enum Ownership { case owner, taken, failed(String) }

    /// The lock file, per user and per host path.
    private func lockURL() -> URL {
        let path = (hostBundle?.bundleURL ?? Bundle.main.bundleURL).standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(UpdaterContract.bundleIdentifier).\(digest).lock")
    }

    private func acquireOwnership() -> Ownership {
        if lockDescriptor < 0 {
            let fd = open(lockURL().path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return .failed("cannot open \(lockURL().path): \(String(cString: strerror(errno)))") }
            lockDescriptor = fd
        }
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 { return .owner }
        let code = errno
        return code == EWOULDBLOCK ? .taken : .failed("flock: \(String(cString: strerror(code)))")
    }

    /// Released before exiting, so a request racing the exit starts a new
    /// owner instead of reaching a process that is going away.
    private func releaseOwnership() {
        guard lockDescriptor >= 0 else { return }
        if flock(lockDescriptor, LOCK_UN) != 0 {
            logger.error("Could not release the updater lock: \(String(cString: strerror(errno)), privacy: .public); it goes with the process")
        }
    }

    private func check(_ mode: UpdaterContract.LaunchMode) {
        if exiting {
            // A request posted just before the lock was released: take it on
            // if the lock is still free, or leave it to whoever took it.
            guard case .owner = acquireOwnership() else { return }
            exiting = false
        }
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
            exiting = true
            releaseOwnership()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.exiting != false { NSApp.terminate(nil) }
                }
            }
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
