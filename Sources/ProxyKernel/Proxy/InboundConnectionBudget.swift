// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One admission budget for both listeners, including idle and negotiating peers.
/// The close future owns release, so pipeline failures and upgrades cannot leak it.
final class InboundConnectionBudget: Sendable {
    private struct State {
        var count = 0
        var lastWarning = NIODeadline.uptimeNanoseconds(0)
    }
    private let state = NIOLockedValueBox(State())

    var count: Int { state.withLockedValue { $0.count } }

    func admit(
        _ channel: Channel, protocolName: String, config: ProxyConfig,
        logger: any LogSink, eventSink: (@Sendable (RuntimeEvent) -> Void)?
    ) -> Bool {
        let limit = config.inboundConnectionMaxLimit
        precondition(limit > 0)
        let decision = state.withLockedValue { state -> (accepted: Bool, count: Int, warn: Bool) in
            guard state.count < limit else { return (false, state.count, false) }
            state.count += 1
            let now = NIODeadline.now()
            let warn = state.count > config.inboundConnectionWarnThreshold && now - state.lastWarning >= .seconds(10)
            if warn { state.lastWarning = now }
            return (true, state.count, warn)
        }
        if decision.accepted {
            channel.closeFuture.whenComplete { [self] _ in
                state.withLockedValue {
                    precondition($0.count > 0, "Inbound admission released without a reservation")
                    $0.count -= 1
                }
            }
        }
        if !decision.accepted || decision.warn {
            let event = RuntimeEvent(
                kind: .connection,
                event: decision.accepted ? "connection.inbound_limit_warning" : "connection.inbound_limit_rejected",
                detail: "protocol=\(protocolName) count=\(decision.count) limit=\(limit)"
            )
            eventSink?(event)
            logger.log(decision.accepted ? .warning : .error, "\(event.event): \(event.detail ?? "")", category: .proxy)
        }
        return decision.accepted
    }
}
