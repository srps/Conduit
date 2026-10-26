// SPDX-License-Identifier: Apache-2.0
import Foundation

package final class RuntimeEventFileWriter: @unchecked Sendable {
    package static let defaultMaxBytes = 1_048_576
    /// `DiagnosticFlush` spends a first events wait and at most one further one. A first wait that drained can leave its
    /// cancelled timer body running, so the further wait takes the second slot instead of being refused. Two retired
    /// bodies, from this phase or an earlier call, still make a third wait `busy`.
    static let drainTimerSlots = 2

    private let writer: BoundedRecordWriter
    private let maxBytes: Int
    private let logger: any LogSink
    private let gate: RecordFileDestinationGate

    /// `eventLog` receives the refusal event. When it is this writer's own log, that event
    /// reaches the latched gate and is counted as a drop (#222).
    package convenience init(fileURL: URL, maxBytes: Int = RuntimeEventFileWriter.defaultMaxBytes,
                             logger: any LogSink, limits: RecordWriterLimits = .init(),
                             destinationGuard: any RecordFileDestinationGuarding, eventLog: RuntimeEventLog) {
        self.init(fileURL: fileURL, maxBytes: maxBytes, logger: logger, limits: limits,
                  destinationGuard: destinationGuard, eventLog: eventLog, drainSleep: nil)
    }

    /// Test seam, internal so only `@testable` tests reach it: `drainSleep` replaces the drain timer's sleep when set.
    init(fileURL: URL, maxBytes: Int = RuntimeEventFileWriter.defaultMaxBytes,
         logger: any LogSink, limits: RecordWriterLimits = .init(),
         destinationGuard: any RecordFileDestinationGuarding, eventLog: RuntimeEventLog,
         drainSleep: (@Sendable (ContinuousClock.Instant) async throws -> Void)?) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
        self.logger = logger
        let gate = RecordFileDestinationGate(sink: .runtimeEvents, eventLog: eventLog, logger: logger)
        self.gate = gate
        let file = RotatingRecordFile(fileURL: fileURL, maxBytes: maxBytes, destinationGuard: destinationGuard)
        writer = BoundedRecordWriter(limits: limits, write: { try gate.write($0, to: file) },
            reportFailure: { message in
                guard !gate.isRefused else { return }
                logger.log(.warning, "Failed to write events.ndjson: \(message)", category: .general)
            }, onDrainCleanup: nil, drainTimerSlots: Self.drainTimerSlots, drainSleep: drainSleep)
    }

    package var statistics: RecordWriterStatistics { writer.statistics }

    package func record(_ event: RuntimeEvent) {
        guard !gate.isRefused else {
            writer.recordDrop()
            return
        }
        do {
            var data = try CanonicalJSON.encoder().encode(event)
            data.append(0x0A)
            guard data.count <= maxBytes else {
                writer.recordDrop()
                logger.log(.warning, "Skipping oversized runtime event for events.ndjson.", category: .general)
                return
            }
            writer.append(data)
        } catch {
            writer.recordDrop()
            logger.log(.warning, "Failed to encode runtime event: \(error.localizedDescription)", category: .general)
        }
    }

    @discardableResult
    package func flush(timeout: TimeInterval = 2) -> Bool { writer.flush(timeout: timeout) }

    /// Awaits the queued events, without blocking the caller, until the absolute `deadline`. The shutdown phase
    /// owner (`DiagnosticFlush`) decides the timeout marker and any retry from these outcomes.
    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        await writer.drain(until: deadline)
    }
}
