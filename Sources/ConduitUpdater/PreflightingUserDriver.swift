// SPDX-License-Identifier: Apache-2.0
import AppKit
import ConduitShared
import PlatformMac
import Sparkle

/// Intercept the install choice before Sparkle stages an install-on-quit.
/// A public delegate veto cannot inspect a candidate bundle; a separate
/// authenticated download is necessary without relying on private Sparkle API.
@MainActor
final class PreflightingUserDriver: NSObject, SPUUserDriver {
    private let driver: any SPUUserDriver
    private let preflight: any UpdatePreflighting
    private let host: Bundle
    private let report: (UpdaterContract.Report, String?) -> Void
    private var pending: Task<Void, Never>?
    private var downloadTimeout: Task<Void, Never>?
    private var cancelDownload: (() -> Void)?
    private var downloaded: UInt64 = 0

    init(driver: any SPUUserDriver, host: Bundle, preflight: any UpdatePreflighting,
         report: @escaping (UpdaterContract.Report, String?) -> Void) {
        self.driver = driver; self.host = host; self.preflight = preflight; self.report = report
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        driver.showUpdateFound(with: item, state: state) { [weak self] choice in
            guard let self, choice == .install else { reply(choice); return }
            guard pending == nil else { reply(.dismiss); return }
            let version = item.versionString
            pending = Task {
                do {
                    guard let archive = item.fileURL,
                          let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
                          let signature = enclosure["sparkle:edSignature"] as? String,
                          let key = host.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
                        report(.preflightFailed, "reason=update_signature_missing")
                        throw UpdatePreflightError("update_signature_missing")
                    }
                    let gate = UpdateInstallGate(preflight: preflight) { event in
                        guard let report = UpdaterContract.Report(rawValue: event.event) else { preconditionFailure("unknown update event") }
                        self.report(report, event.detail)
                    }
                    try await gate.run(UpdateCandidate(archive: archive, version: version,
                        length: item.contentLength, signature: signature, publicKey: key, host: host.bundleURL)) {
                        pending = nil
                        reply(.install)
                    }
                } catch {
                    pending = nil
                    guard !Task.isCancelled else { return }
                    // Never echo a network error containing signed URLs or
                    // arbitrary child output into distributed notifications.
                    let reason = (error as? UpdatePreflightError)?.reason ?? "update_preflight_failed"
                    let message = "The update could not pass compatibility checks (\(reason)). Conduit is still running. "
                        + "Check installation permissions and helper compatibility, then retry or install manually."
                    await driver.showUpdaterError(NSError(domain: "io.github.srps.Conduit.UpdatePreflight", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: message]))
                    reply(state.stage == .installing ? .skip : .dismiss)
                }
            }
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        driver.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        driver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { driver.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { driver.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        driver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        finishDownload()
        driver.showUpdaterError(error, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        finishDownload()
        downloaded = 0
        cancelDownload = cancellation
        downloadTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(SystemUpdatePreflight.downloadTimeout)) }
            catch { return }  // cancelled at extraction/dismissal
            self?.abortDownload(reason: "update_download_timeout")
        }
        driver.showDownloadInitiated(cancellation: cancellation)
    }
    private func finishDownload() {
        downloadTimeout?.cancel(); downloadTimeout = nil; cancelDownload = nil
    }
    private func abortDownload(reason: String) {
        guard let cancelDownload else { return }
        report(.failed, "reason=\(reason)")
        finishDownload()
        cancelDownload()
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
        if length > SystemUpdatePreflight.archiveLimit { abortDownload(reason: "update_download_limit") }
        else { driver.showDownloadDidReceiveExpectedContentLength(length) }
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (sum, overflow) = downloaded.addingReportingOverflow(length)
        if overflow || sum > SystemUpdatePreflight.archiveLimit { abortDownload(reason: "update_download_limit") }
        else { downloaded = sum; driver.showDownloadDidReceiveData(ofLength: length) }
    }
    func showDownloadDidStartExtractingUpdate() { finishDownload(); driver.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { driver.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { driver.showReady(toInstallAndRelaunch: reply) }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        driver.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        driver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func dismissUpdateInstallation() {
        pending?.cancel()
        finishDownload()
        driver.dismissUpdateInstallation()
    }
}
