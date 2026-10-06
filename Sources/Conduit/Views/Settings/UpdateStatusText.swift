// SPDX-License-Identifier: Apache-2.0
import ConduitShared

/// Settings wording for the updater's latest report.
enum UpdateStatusText {
    static func describe(_ report: UpdaterContract.ParsedReport) -> String {
        let detail = report.detail ?? ""
        switch report.report {
        case .available:
            return "Version \(value(of: "version", in: detail) ?? "?") is available"
        case .upToDate:
            return "Up to date"
        case .installing:
            return "Installing version \(value(of: "version", in: detail) ?? "?")"
        case .failed:
            return "Check failed: \(value(of: "reason", in: detail) ?? detail)"
        }
    }

    /// The text after `key=` up to the end, since a reason may contain spaces.
    static func value(of key: String, in detail: String) -> String? {
        guard let range = detail.range(of: key + "=") else { return nil }
        let value = detail[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
