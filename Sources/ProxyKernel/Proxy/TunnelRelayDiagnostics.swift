// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

/// One bounded reporter per listener/coordinator, shared by its relays. No
/// per-connection timers; the existing gate caps state at 64 keys. Repeats
/// carry a suppressed count on the next report (eviction may lose that count).
package final class TunnelFailureReporter: Sendable {
    private let gate: RuntimeEventRepeatGate
    private let logger: any LogSink
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?

    package init(logger: any LogSink, eventSink: (@Sendable (RuntimeEvent) -> Void)?,
                 now: @escaping @Sendable () -> Date = Date.init) {
        self.logger = logger
        self.eventSink = eventSink
        self.gate = RuntimeEventRepeatGate(now: now)
    }

    package func report(target: String, key: String, fields: String, error: Error) {
        let target = SensitiveValueSanitizer.observableTarget(target)
        guard let suppressed = gate.admit(host: target, reason: key) else { return }
        let event = RuntimeEvent(kind: .connection, event: "tunnel.relay_failed",
                                 detail: "target=\(target) \(fields) reason=\(error.displayDescription) suppressed=\(suppressed) window_seconds=60")
        eventSink?(event)
        logger.log(.warning, "Tunnel relay: \(event.detail ?? "")", category: .proxy)
    }
}

/// Both halves can live on different event loops. Counts are bytes observed
/// from each peer, not proof of delivery; neither payloads nor TLS are inspected.
package final class TunnelRelayDiagnostics: @unchecked Sendable {
    package enum Side: String { case client, remote }
    private let lock = NSLock()
    private var clientBytes: UInt64 = 0
    private var remoteBytes: UInt64 = 0
    private var lastRead: UInt64
    private var reported = false
    private let started: UInt64
    private let now: @Sendable () -> UInt64
    private let target: String
    private let transport: String
    private let route: String
    private let upstream: String
    private let startedCause: DirectModeCause
    private let causeProvider: @Sendable () -> DirectModeCause
    private let reporter: TunnelFailureReporter

    package init(target: String, transport: String, route: String, upstream: String?,
                 causeProvider: @escaping @Sendable () -> DirectModeCause,
                 reporter: TunnelFailureReporter,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.target = target
        self.transport = transport
        self.route = route
        self.upstream = upstream.map(SensitiveValueSanitizer.observableTarget) ?? "none"
        self.causeProvider = causeProvider
        self.reporter = reporter
        self.now = now
        self.started = now()
        self.lastRead = started
        self.startedCause = causeProvider()
    }

    package func read(_ bytes: Int, from side: Side) {
        precondition(bytes >= 0)
        lock.lock()
        defer { lock.unlock() }
        if side == .client { clientBytes = Self.add(clientBytes, UInt64(bytes)) }
        else { remoteBytes = Self.add(remoteBytes, UInt64(bytes)) }
        if bytes > 0 { lastRead = now() }
    }

    package func failed(_ error: Error, on side: Side) {
        let at = now()
        lock.lock()
        guard !reported else { lock.unlock(); return }
        reported = true
        let client = clientBytes, remote = remoteBytes, last = lastRead
        lock.unlock()
        let cause = causeProvider()
        let code = (error as? IOError).map { String($0.errnoCode) } ?? "none"
        reporter.report(
            target: target, key: "\(transport):\(route):\(side.rawValue):\(code)",
            fields: "transport=\(transport) route=\(route) upstream=\(upstream) side=\(side.rawValue) errno=\(code) age_ms=\(Self.milliseconds(at, since: started)) idle_ms=\(Self.milliseconds(at, since: last)) client_bytes=\(client) remote_bytes=\(remote) started_cause=\(startedCause.rawValue) current_cause=\(cause.rawValue)",
            error: error
        )
    }

    private static func add(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        return overflow ? .max : sum
    }

    private static func milliseconds(_ at: UInt64, since prior: UInt64) -> UInt64 {
        (at >= prior ? at - prior : 0) / 1_000_000
    }
}
