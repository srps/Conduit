// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One admission budget for both listeners, including idle and negotiating peers.
/// The close future owns release, so pipeline failures and upgrades cannot leak it.
final class InboundConnectionBudget: Sendable {
    /// A fixed-limit budget reports a refusal at most this often.
    static let rejectionReportInterval: TimeAmount = .seconds(10)

    private struct State {
        var count = 0
        var lastWarning = NIODeadline.uptimeNanoseconds(0)
        var lastRejectionReport: NIODeadline?
        var rejectionsHeldBack = 0
    }
    private let state = NIOLockedValueBox(State())
    /// A listener with its own fixed cap, where the config's limit is for the client listeners.
    private let fixedLimit: Int?
    private let now: @Sendable () -> NIODeadline

    /// - Parameters:
    ///   - fixedLimit: the DoH upstream route's cap. Such a budget reports its refusals at most once every
    ///     `rejectionReportInterval`, with the number held back since: its clients are Conduit's own lookups, which retry in
    ///     bursts. The client listeners' budget reports every refusal, as the catalogue says.
    ///   - now: exposed only so a test can move the clock that limit runs on.
    init(fixedLimit: Int? = nil, now: @escaping @Sendable () -> NIODeadline = { .now() }) {
        self.fixedLimit = fixedLimit
        self.now = now
    }

    var count: Int { state.withLockedValue { $0.count } }

    private enum Decision {
        case accepted(count: Int, warn: Bool)
        /// `suppressed` is nil while the refusal falls inside the report interval.
        case rejected(count: Int, suppressed: Int?)
    }

    func admit(
        _ channel: Channel, protocolName: String, config: ProxyConfig,
        logger: any LogSink, eventSink: (@Sendable (RuntimeEvent) -> Void)?
    ) -> Bool {
        let limit = fixedLimit ?? config.inboundConnectionMaxLimit
        // Live UI edits can expose an invalid draft before config validation.
        // A nonpositive limit rejects new peers without disturbing reservations.
        let decision = state.withLockedValue { state -> Decision in
            let now = now()
            guard state.count < limit else {
                guard fixedLimit != nil else { return .rejected(count: state.count, suppressed: 0) }
                if let last = state.lastRejectionReport, now - last < Self.rejectionReportInterval {
                    state.rejectionsHeldBack += 1
                    return .rejected(count: state.count, suppressed: nil)
                }
                defer {
                    state.lastRejectionReport = now
                    state.rejectionsHeldBack = 0
                }
                return .rejected(count: state.count, suppressed: state.rejectionsHeldBack)
            }
            state.count += 1
            let warn = fixedLimit == nil && state.count > config.inboundConnectionWarnThreshold && now - state.lastWarning >= .seconds(10)
            if warn { state.lastWarning = now }
            return .accepted(count: state.count, warn: warn)
        }
        let accepted: Bool
        let report: (name: String, count: Int, held: String, level: LogLevel)?
        switch decision {
        case .accepted(let count, let warn):
            channel.closeFuture.whenComplete { [self] _ in
                state.withLockedValue {
                    precondition($0.count > 0, "Inbound admission released without a reservation")
                    $0.count -= 1
                }
            }
            accepted = true
            report = warn ? ("connection.inbound_limit_warning", count, "", .warning) : nil
        case .rejected(let count, let suppressed):
            accepted = false
            report = suppressed.map {
                ("connection.inbound_limit_rejected", count, fixedLimit == nil ? "" : " suppressed=\($0)", .error)
            }
        }
        if let report {
            let event = RuntimeEvent(
                kind: .connection, event: report.name,
                detail: "protocol=\(protocolName) count=\(report.count) limit=\(limit)\(report.held)"
            )
            eventSink?(event)
            logger.log(report.level, "\(event.event): \(event.detail ?? "")", category: .proxy)
        }
        return accepted
    }
}
