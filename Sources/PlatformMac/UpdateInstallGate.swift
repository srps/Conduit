// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import ProxyKernel

/// The install decision shared by the updater and the headless simulator.
/// No install continuation is invoked after a failed/cancelled preflight.
@MainActor
package struct UpdateInstallGate {
    private let preflight: any UpdatePreflighting
    private let record: (RuntimeEvent) -> Void

    package init(preflight: any UpdatePreflighting, record: @escaping (RuntimeEvent) -> Void) {
        self.preflight = preflight; self.record = record
    }

    package func run(_ candidate: UpdateCandidate, install: () -> Void) async throws {
        let version = String(candidate.version.prefix(64).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        record(RuntimeEvent(kind: .lifecycle, event: UpdaterContract.Report.preflightStarted.rawValue, detail: "version=\(version)"))
        do {
            try await preflight.check(candidate)
            try Task.checkCancellation()
        } catch {
            let reason = (error as? UpdatePreflightError)?.reason ?? "update_preflight_failed"
            record(RuntimeEvent(kind: .lifecycle, event: UpdaterContract.Report.preflightFailed.rawValue, detail: "version=\(version) reason=\(reason)"))
            throw error
        }
        record(RuntimeEvent(kind: .lifecycle, event: UpdaterContract.Report.preflightPassed.rawValue, detail: "version=\(version)"))
        install()
    }
}
