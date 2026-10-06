import Foundation

/// The contract between Conduit and its nested updater (#111).
///
/// Sparkle runs only in `Conduit Updater.app`, inside Conduit.app, never in
/// Conduit itself: with a self-signed certificate there is no Team ID, so a
/// hardened-runtime process can load Sparkle.framework only with library
/// validation off, and Conduit is the process the helper's caller pin admits.
/// The updater has its own identifier, which that pin refuses.
///
/// The two processes talk through distributed notifications. Their names are
/// derived from the host's bundle identifier and every message carries the
/// host bundle's path, so a test host, or a `--dev` instance beside the
/// installed app, never acts on another copy's messages. Distributed
/// notifications are not authenticated; nothing here may do more than a
/// same-user process could do anyway (start a check, append an event).
package enum UpdaterContract {
    package static let bundleIdentifier = "io.github.srps.Conduit.Updater"
    package static let executableName = "Conduit Updater"
    /// Where the updater lives inside the host app.
    package static let relativeBundlePath = "Contents/Helpers/Conduit Updater.app"
    /// The longest detail a report may carry; longer ones are cut.
    package static let maxDetailLength = 256

    /// How the host starts the updater, as its only argument.
    package enum LaunchMode: String, Sendable, CaseIterable {
        /// Chosen by the user: show progress, results and errors.
        case interactive = "--check"
        /// Scheduled: stay silent unless an update is found.
        case background = "--background"
    }

    /// What the updater may tell the host. Anything else is rejected.
    package enum Report: String, Sendable, CaseIterable {
        /// A newer, compatible, correctly signed release exists (`version=`).
        case available = "update.available"
        /// The feed has nothing newer.
        case upToDate = "update.up_to_date"
        /// The check, download or verification failed (`reason=`).
        case failed = "update.failed"
        /// The user chose to install; Sparkle is about to quit the host (`version=`).
        case installing = "update.installing"
    }

    package enum Key {
        package static let hostPath = "hostPath"
        package static let report = "report"
        package static let detail = "detail"
        package static let mode = "mode"
    }

    package static func checkNotification(hostIdentifier: String) -> Notification.Name {
        Notification.Name(hostIdentifier + ".updater.check")
    }

    package static func reportNotification(hostIdentifier: String) -> Notification.Name {
        Notification.Name(hostIdentifier + ".updater.report")
    }

    /// The updater bundle inside `hostBundle`.
    package static func updaterURL(inHost hostBundle: URL) -> URL {
        hostBundle.appendingPathComponent(relativeBundlePath, isDirectory: true)
    }

    /// The host app that contains `updaterBundle`, three levels up.
    package static func hostURL(containing updaterBundle: URL) -> URL {
        updaterBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Paths compare after resolving symlinks, so `/Applications` and its
    /// firmlinked spelling are the same host.
    package static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }

    package static func reportUserInfo(_ report: Report, detail: String?, hostPath: String) -> [String: String] {
        var info = [Key.hostPath: hostPath, Key.report: report.rawValue]
        if let detail { info[Key.detail] = String(detail.prefix(maxDetailLength)) }
        return info
    }

    package struct ParsedReport: Equatable, Sendable {
        package var report: Report
        package var detail: String?

        package init(report: Report, detail: String?) {
            self.report = report
            self.detail = detail
        }
    }

    package enum Rejection: Error, Equatable, CustomStringConvertible {
        case otherHost
        case malformed(String)

        package var description: String {
            switch self {
            case .otherHost: "addressed to another copy of the app"
            case .malformed(let why): why
            }
        }
    }

    /// Validates a report at the boundary. A report for another host is
    /// `.otherHost`, which the caller ignores silently; a malformed one is
    /// worth an event.
    package static func parseReport(
        _ userInfo: [AnyHashable: Any]?,
        hostPath: String
    ) -> Result<ParsedReport, Rejection> {
        guard let userInfo, let path = userInfo[Key.hostPath] as? String else {
            return .failure(.malformed("no host path"))
        }
        guard samePath(path, hostPath) else { return .failure(.otherHost) }
        guard let raw = userInfo[Key.report] as? String else {
            return .failure(.malformed("no report name"))
        }
        guard let report = Report(rawValue: raw) else {
            return .failure(.malformed("unknown report \(String(raw.prefix(64)))"))
        }
        let detail = (userInfo[Key.detail] as? String).map { String($0.prefix(maxDetailLength)) }
        return .success(ParsedReport(report: report, detail: detail))
    }

    /// Validates a check request the updater received while running.
    package static func parseCheck(_ userInfo: [AnyHashable: Any]?, hostPath: String) -> LaunchMode? {
        guard let userInfo,
              let path = userInfo[Key.hostPath] as? String, samePath(path, hostPath),
              let raw = userInfo[Key.mode] as? String else { return nil }
        return LaunchMode(rawValue: raw)
    }
}
