// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// The diagnostic writers that write a destination the gate guards: append-only record files, the whole-file
/// snapshot replacement, and the app's file log. The role decides which protected resources a writer may
/// not touch; a writer may always write its own file.
package enum RecordFileDiagnosticSink: String, Sendable {
    case connectionAudit = "audit"
    case runtimeEvents = "events"
    case snapshot = "snapshot"
    /// The app's file log. Its own file is the `log` resource, which this sink may write; every other protected file applies.
    case appLog = "log"
}

/// The closed set of authoritative files a diagnostic destination must never write. Each code
/// names one file, so a protected set has at most `allCases.count` entries. Codes are what a
/// refusal event carries; paths never leave the process. The path mapping lives in
/// `ProxyControlBridge`, which knows the wire file names; this target only knows the roles.
package enum ProtectedRecordResource: String, Sendable, CaseIterable {
    case config
    case platformState = "platform_state"
    case platformConfig = "platform_config"
    case preferences
    case snapshot
    case legacySavedDNS = "legacy_saved_dns"
    case events
    case ready
    case daemonReady = "daemon_ready"
    case control
    case updateState = "update_state"
    case log
    /// Optional: only a composer that adopts the writer lease passes its URL.
    case writerLease = "writer_lease"
}

package struct ProtectedRecordFile: Sendable, Equatable {
    package let resource: ProtectedRecordResource
    package let url: URL

    package init(resource: ProtectedRecordResource, url: URL) {
        self.resource = resource
        self.url = url
    }
}

/// Why a destination was refused. Codes only; no path or config value.
package struct RecordFileDestinationRefusal: Error, Sendable, Equatable {
    package enum Reason: String, Sendable {
        /// The destination's canonical path names a protected file, lies beneath one, or is an ancestor of
        /// one, judged by whole path components. Also a name that differs from a protected path only by
        /// case or folding, on a case-insensitive volume, where both names may be one file.
        case protectedPath = "protected_path"
        /// The destination, or the descriptor it opened, is the same file as a protected one (hardlink).
        case protectedIdentity = "protected_identity"
        /// A metadata query failed, the volume's case behaviour is unknown for a case-equivalent name,
        /// or the destination is a dangling symlink; the write is refused.
        case inspectionFailed = "inspection_failed"
    }

    package let reason: Reason
    package let resource: ProtectedRecordResource?

    package init(reason: Reason, resource: ProtectedRecordResource?) {
        self.reason = reason
        self.resource = resource
    }
}

/// Decides whether a diagnostic writer may write a destination. Implementations run on the
/// writer's serial drain, never on the main actor or an event loop.
package protocol RecordFileDestinationGuarding: Sendable {
    /// Called before the writer creates a directory or file, so a refused destination stays untouched.
    func admit(destination: URL) throws

    /// Called with the descriptor the writer just opened, before any truncate or write.
    func admit(openedDescriptor descriptor: Int32, destination: URL) throws
}

/// Fixture bypass: admits every destination. Production compositions pass
/// `SystemRecordFileDestinationGuard`; a test names this bypass at its call site.
package struct UncheckedRecordFileDestination: RecordFileDestinationGuarding {
    package init() {}

    package func admit(destination: URL) throws {}

    package func admit(openedDescriptor descriptor: Int32, destination: URL) throws {}
}

/// Latches a refused destination. The first refusal emits one `config.diagnostic_destination_refused`
/// event and one log line derived from it; later records are counted as drops, not written.
///
/// The gate holds the event log weakly. A writer's sink is owned by that log (`setSink`), so a
/// strong reference here would close a cycle, log to sink to writer to gate to log, that nothing
/// breaks. The log's owner must outlive the writer's drains: production has the orchestrator own
/// the shared log and drain the writers before it is released. If the log is gone, the refusal
/// still reaches the console line; no owner remains to receive the event.
package final class RecordFileDestinationGate: @unchecked Sendable {
    package static let eventName = "config.diagnostic_destination_refused"

    private let sink: RecordFileDiagnosticSink
    private weak var eventLog: RuntimeEventLog?
    private let logger: any LogSink
    private let latched = NIOLockedValueBox<RecordFileDestinationRefusal?>(nil)

    package init(sink: RecordFileDiagnosticSink, eventLog: RuntimeEventLog, logger: any LogSink) {
        self.sink = sink
        self.eventLog = eventLog
        self.logger = logger
    }

    package var refusal: RecordFileDestinationRefusal? { latched.withLockedValue { $0 } }

    package var isRefused: Bool { refusal != nil }

    /// Writes one batch. A latched gate throws without touching storage.
    package func write(_ batch: [Data], to file: RotatingRecordFile) throws {
        try perform { try file.append(batch) }
    }

    /// Runs one guarded write a writer performs itself, such as a whole-file replacement. It shares the
    /// latch and the event-first refusal with `write(_:to:)`, so no writer copies that policy. A latched
    /// gate throws without running `work`. Errors other than a refusal pass through unchanged.
    package func perform<T>(_ work: () throws -> T) throws -> T {
        if let refusal { throw refusal }
        do {
            return try work()
        } catch let refusal as RecordFileDestinationRefusal {
            refuse(refusal)
            throw refusal
        }
    }

    /// The latch is set before the event is appended. For the events writer, that event then reaches
    /// its own gate and is counted as a drop, so refusal never recurses into the failed writer.
    private func refuse(_ refusal: RecordFileDestinationRefusal) {
        let first = latched.withLockedValue { value -> Bool in
            guard value == nil else { return false }
            value = refusal
            return true
        }
        guard first else { return }
        let detail = "sink=\(sink.rawValue) reason=\(refusal.reason.rawValue) resource=\(refusal.resource?.rawValue ?? "none")"
        let event = RuntimeEvent(kind: .config, event: Self.eventName, detail: detail)
        eventLog?.append(event)
        logger.log(.warning, "\(event.event) \(detail)", category: .general)
    }
}
