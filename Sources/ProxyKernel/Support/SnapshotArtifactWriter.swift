// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch
import Foundation
import NIOConcurrencyHelpers

/// The writer for `snapshot.json`. A caller hands over the raw snapshot value. A serial drain encodes it,
/// checks the destination through the shared guard, and replaces the file.
///
/// Steady state holds one value being written and one pending. A newer submission replaces the pending value,
/// so a burst coalesces into the latest snapshot. The replaced value leaves the lock before it is released,
/// so for a moment it can live beside the active and the new pending value: up to three values, not two.
/// The release costs what the value holds, so `submit` is constant in the number of values, not their size.
/// Generations never wrap: after the last one the writer closes and reports `generation_exhausted`.
package protocol SnapshotArtifactWriting: Sendable {
    /// Hands over the latest snapshot. It never encodes and never touches the file.
    func submit(_ snapshot: ProxyOrchestratorSnapshot)

    /// Waits, without blocking the caller and until the absolute `deadline`, for the attempt that covers the newest
    /// submission made before this call. `.current` means a successful atomic replacement covers that submission. It is
    /// not a power-loss durability claim and not a readback verification.
    func drain(until deadline: ContinuousClock.Instant) async -> SnapshotFlushOutcome

    var statistics: SnapshotArtifactStatistics { get }
}

/// The composer's entry point. Callers hold the protocol; the concrete writer stays internal.
/// `initialGeneration` lets a test reach the generation limit without submitting 2^64 values. Production passes nothing.
package func makeSnapshotArtifactWriter(
    fileURL: URL,
    logger: any LogSink,
    destinationGuard: any RecordFileDestinationGuarding,
    eventLog: RuntimeEventLog,
    onDrainCleanup: (@Sendable () -> Void)? = nil,
    initialGeneration: UInt64 = 0
) -> any SnapshotArtifactWriting {
    SnapshotArtifactWriter(fileURL: fileURL, logger: logger, destinationGuard: destinationGuard,
                           eventLog: eventLog, onDrainCleanup: onDrainCleanup, initialGeneration: initialGeneration)
}

/// The result of waiting for a snapshot. These describe the writer's latest condition when the wait ended, and each one
/// preserves only what that condition proves. They are not a history, and they do not name the attempt that caused a result.
/// - `current`: a successful replacement covers the submission awaited.
/// - `refused`, `writeFailed`: the latest condition does not confirm the submission. The file may still hold an earlier
///   successful snapshot, or bytes this writer did not write. Neither outcome says which.
/// - `noSubmission`: nothing had been submitted before the wait began.
/// - `timedOut`, `busy`, `skippedBudget`, `cancelled`, `exhausted`: the wait ended without a result for the submission.
package enum SnapshotFlushOutcome: String, Sendable, Equatable {
    case current
    case refused
    case writeFailed = "write_failed"
    case noSubmission = "no_submission"
    case timedOut = "timed_out"
    case busy
    case skippedBudget = "skipped_budget"
    case cancelled
    /// The generation counter is spent, so the writer no longer accepts submissions.
    case exhausted = "generation_exhausted"
}

/// Counts and measured sizes. Generations, failures and retained values are counted. The byte fields are measured
/// encoded sizes, not limits: no snapshot-size ceiling is selected here.
package struct SnapshotArtifactStatistics: Sendable, Codable, Equatable {
    /// The newest submission's generation. Each accepted `submit` advances it by one.
    package var submittedGeneration: UInt64 = 0
    /// Pending values replaced before the drain took them. Their generations are never written.
    package var coalesced: UInt64 = 0
    package var written: UInt64 = 0
    package var refused: UInt64 = 0
    package var failed: UInt64 = 0
    /// Temporary files whose removal failed, so each one may remain in the destination's directory.
    package var orphanedTemporaries: UInt64 = 0
    /// Descriptors whose close reported failure. Whether such a descriptor stays open is platform-defined, so it is never
    /// closed again.
    package var uncertainCloses: UInt64 = 0
    /// Set when an orphan or an uncertain close is seen. The writer then creates no further temporary file for its
    /// lifetime, and reports `disabled` for each attempt. This bounds cleanup per writer, not across crashes or relaunches.
    package var cleanupLatched = false
    /// Encoded size of the last successful write, and the largest one seen.
    package var lastEncodedBytes = 0
    package var maxEncodedBytes = 0
    /// The most value slots occupied at once, read under the lock when a submission is accepted. A replaced pending value
    /// is released after the lock and is not counted, so this does not measure every transient lifetime.
    package var retainedValuePeak = 0
    package var lastSuccessfulGeneration: UInt64 = 0
}

extension SnapshotFlushOutcome {
    /// Event first, then the derived log line, for every outcome except `.current`. The event reaches
    /// `events.ndjson` only if a later events wait drains it with no recorded loss.
    package func reportIfUnconfirmed(eventLog: RuntimeEventLog, logger: any LogSink) {
        guard self != .current else { return }
        let event = RuntimeEvent(kind: .health, event: "observability.snapshot_flush_unconfirmed",
                                 detail: "outcome=\(rawValue)")
        eventLog.append(event)
        logger.log(.warning, "\(event.event) \(event.detail ?? "")", category: .general)
    }
}

/// A failed write step. It carries the step and an errno only, never a path, a value or an error description.
struct SnapshotWriteFailure: Error, Sendable, Equatable {
    enum Stage: String, Sendable {
        case encode, directory, create, write, close, replace
        /// The writer is latched after an orphan or an uncertain close, so nothing was attempted.
        case disabled
        case other
    }

    let stage: Stage
    let code: Int32
}

/// The two file effects a test must be able to make fail deterministically. Production uses `.system`.
struct SnapshotFileEffects: Sendable {
    var removeFile: @Sendable (String) -> Int32
    var closeDescriptor: @Sendable (Int32) -> Int32

    static let system = SnapshotFileEffects(
        removeFile: { unlink($0) },
        closeDescriptor: { close($0) }
    )
}

final class SnapshotArtifactWriter: SnapshotArtifactWriting, @unchecked Sendable {
    private struct Job: Sendable {
        let snapshot: ProxyOrchestratorSnapshot
        let generation: UInt64
    }

    private enum Attempt: Sendable, Equatable {
        case written, refused, failed
    }

    private enum Outcome {
        case written(bytes: Int)
        case refused
        case failed(SnapshotWriteFailure)
    }

    /// What one attempt left behind on the file system, reported whatever the attempt's outcome.
    private struct Cleanup: Sendable {
        var orphaned = false
        var uncertainClose = false
    }

    private struct State {
        var pending: Job?
        var activeInFlight = false
        var draining = false
        /// Set when a submission arrives at the last generation. Nothing newer is ever accepted after it.
        var exhausted = false
        var lastAttempt: Attempt?
        var statistics = SnapshotArtifactStatistics()
    }

    private let state = NIOLockedValueBox(State())
    private let drained: DispatchGroup
    private let waiter: RecordDrainWaiter
    private let queue = DispatchQueue(label: "conduit.snapshot-artifact", qos: .utility)
    private let fileURL: URL
    private let logger: any LogSink
    private let destinationGuard: any RecordFileDestinationGuarding
    private let gate: RecordFileDestinationGate
    private weak var eventLog: RuntimeEventLog?
    /// Built once and used only on `queue`, so encoding never runs on a caller's thread.
    private let encoder = CanonicalJSON.encoder(prettyPrinted: true)
    /// Test seam: counts or replaces the encoding. Production leaves it nil.
    private let encodeOverride: (@Sendable (ProxyOrchestratorSnapshot) throws -> Data)?
    /// Test seam: the two file effects that can fail after a temporary file exists. Production uses `.system`.
    private let fileEffects: SnapshotFileEffects

    init(fileURL: URL, logger: any LogSink, destinationGuard: any RecordFileDestinationGuarding,
         eventLog: RuntimeEventLog, onDrainCleanup: (@Sendable () -> Void)?, initialGeneration: UInt64,
         encodeOverride: (@Sendable (ProxyOrchestratorSnapshot) throws -> Data)? = nil,
         fileEffects: SnapshotFileEffects = .system) {
        let group = DispatchGroup()
        drained = group
        waiter = RecordDrainWaiter(group: group, onCleanup: onDrainCleanup)
        self.fileURL = fileURL
        self.logger = logger
        self.destinationGuard = destinationGuard
        self.eventLog = eventLog
        gate = RecordFileDestinationGate(sink: .snapshot, eventLog: eventLog, logger: logger)
        self.encodeOverride = encodeOverride
        self.fileEffects = fileEffects
        state.withLockedValue { $0.statistics.submittedGeneration = initialGeneration }
    }

    var statistics: SnapshotArtifactStatistics { state.withLockedValue { $0.statistics } }

    func submit(_ snapshot: ProxyOrchestratorSnapshot) {
        // The replaced value leaves the lock in `replaced`. Its release is an explicit statement after the
        // lock, not the end of a lexical scope or the last in-lock use, which Swift does not promise as a lifetime.
        var replaced: Job?
        var closedNow = false
        let schedule = state.withLockedValue { s -> Bool in
            // At the last generation the writer closes rather than wrap, so an identity is never reused.
            guard s.statistics.submittedGeneration < UInt64.max else {
                closedNow = !s.exhausted
                s.exhausted = true
                return false
            }
            let next = s.statistics.submittedGeneration + 1
            s.statistics.submittedGeneration = next
            if s.pending != nil { s.statistics.coalesced &+= 1 }
            swap(&replaced, &s.pending)
            s.pending = Job(snapshot: snapshot, generation: next)
            s.statistics.retainedValuePeak = max(s.statistics.retainedValuePeak, 1 + (s.activeInFlight ? 1 : 0))
            guard !s.draining else { return false }
            s.draining = true
            drained.enter()
            return true
        }
        if closedNow {
            emit(event: "observability.snapshot_generations_exhausted",
                 detail: "submittedGeneration=\(UInt64.max)", level: .warning)
        }
        if schedule { queue.async { [self] in drainLoop() } }
        // Released here, outside the lock: keep `replaced` alive to this point, then drop it.
        withExtendedLifetime(replaced) {}
        replaced = nil
    }

    func drain(until deadline: ContinuousClock.Instant) async -> SnapshotFlushOutcome {
        if state.withLockedValue({ $0.exhausted }) { return .exhausted }
        let target = state.withLockedValue { $0.statistics.submittedGeneration }
        guard target > 0 else { return .noSubmission }
        if state.withLockedValue({ $0.statistics.lastSuccessfulGeneration >= target }) { return .current }
        switch await waiter.drain(until: deadline) {
        case .drained:
            // The group is empty, so every submission up to now has been attempted. The result is the writer's latest
            // condition, which covers the target only when a successful generation at or after it exists.
            return state.withLockedValue { s -> SnapshotFlushOutcome in
                if s.statistics.lastSuccessfulGeneration >= target { return .current }
                switch s.lastAttempt {
                case .refused?: return .refused
                case .failed?: return .writeFailed
                case .written?, nil: return .noSubmission
                }
            }
        case .timedOut: return .timedOut
        case .busy: return .busy
        case .cancelled: return .cancelled
        case .skippedBudget: return .skippedBudget
        case .unavailable:
            preconditionFailure("the snapshot waiter never reports unavailable")
        }
    }

    private func drainLoop() {
        while let job = takeNext() {
            let (outcome, cleanup) = attempt(job.snapshot)
            finish(job, outcome, cleanup)
        }
    }

    private func takeNext() -> Job? {
        state.withLockedValue { s -> Job? in
            guard let job = s.pending else {
                s.draining = false
                drained.leave()
                return nil
            }
            s.pending = nil
            s.activeInFlight = true
            return job
        }
    }

    /// Encodes and replaces the file on the drain queue, under the shared gate. Once the gate has latched a refusal,
    /// nothing is encoded. Once cleanup has latched, nothing touches the file system.
    private func attempt(_ snapshot: ProxyOrchestratorSnapshot) -> (Outcome, Cleanup) {
        var cleanup = Cleanup()
        if gate.isRefused { return (.refused, cleanup) }
        if state.withLockedValue({ $0.statistics.cleanupLatched }) {
            return (.failed(SnapshotWriteFailure(stage: .disabled, code: 0)), cleanup)
        }
        let data: Data
        do {
            if let encodeOverride {
                data = try encodeOverride(snapshot)
            } else {
                data = try encoder.encode(snapshot)
            }
        } catch {
            return (.failed(SnapshotWriteFailure(stage: .encode, code: 0)), cleanup)
        }
        do {
            try gate.perform { try replace(data, &cleanup) }
            return (.written(bytes: data.count), cleanup)
        } catch is RecordFileDestinationRefusal {
            // The refusal is the reported cause. Cleanup status recorded before it is kept in `cleanup`.
            return (.refused, cleanup)
        } catch let failure as SnapshotWriteFailure {
            return (.failed(failure), cleanup)
        } catch {
            return (.failed(SnapshotWriteFailure(stage: .other, code: 0)), cleanup)
        }
    }

    /// Runs inside `gate.perform`. The guard judges the path before anything is created, the opened temporary
    /// descriptor, and the path again right before the rename. The temporary file is new and exclusive, so no existing
    /// protected file is truncated. Every failure after creation attempts one removal and records whether it succeeded
    /// in `cleanup`, whether the attempt then succeeds or fails.
    private func replace(_ data: Data, _ cleanup: inout Cleanup) throws {
        try destinationGuard.admit(destination: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SnapshotWriteFailure(stage: .directory, code: 0)
        }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp").path
        // O_EXCL never reuses or follows an existing name, so a planted link is not written through. O_CLOEXEC keeps
        // the writable descriptor out of any child process the runtime spawns while the write is in progress.
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw SnapshotWriteFailure(stage: .create, code: errno)
        }
        var descriptorOpen = true
        do {
            try destinationGuard.admit(openedDescriptor: descriptor, destination: fileURL)
            try Self.writeAll(data, to: descriptor)
            descriptorOpen = false
            if fileEffects.closeDescriptor(descriptor) != 0 {
                // A failed close is ambiguous about the descriptor. It is recorded, and never closed again.
                cleanup.uncertainClose = true
                throw SnapshotWriteFailure(stage: .close, code: errno)
            }
            try destinationGuard.admit(destination: fileURL)
            guard rename(temporary, fileURL.path) == 0 else {
                throw SnapshotWriteFailure(stage: .replace, code: errno)
            }
        } catch {
            // The original failure is the reported one. A close here is best effort, and its failure is recorded as
            // an uncertain close rather than retried.
            if descriptorOpen, fileEffects.closeDescriptor(descriptor) != 0 {
                cleanup.uncertainClose = true
            }
            if fileEffects.removeFile(temporary) != 0 {
                cleanup.orphaned = true
            }
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SnapshotWriteFailure(stage: .write, code: errno)
                }
                offset += written
            }
        }
    }

    private func finish(_ job: Job, _ outcome: Outcome, _ cleanup: Cleanup) {
        let (previous, latchedNow) = state.withLockedValue { s -> (Attempt?, Bool) in
            let previous = s.lastAttempt
            s.activeInFlight = false
            switch outcome {
            case .written(let bytes):
                s.statistics.written &+= 1
                s.statistics.lastEncodedBytes = bytes
                s.statistics.maxEncodedBytes = max(s.statistics.maxEncodedBytes, bytes)
                s.statistics.lastSuccessfulGeneration = job.generation
                s.lastAttempt = .written
            case .refused:
                s.statistics.refused &+= 1
                s.lastAttempt = .refused
            case .failed:
                s.statistics.failed &+= 1
                s.lastAttempt = .failed
            }
            if cleanup.orphaned { s.statistics.orphanedTemporaries &+= 1 }
            if cleanup.uncertainClose { s.statistics.uncertainCloses &+= 1 }
            var latchedNow = false
            if (cleanup.orphaned || cleanup.uncertainClose), !s.statistics.cleanupLatched {
                s.statistics.cleanupLatched = true
                latchedNow = true
            }
            return (previous, latchedNow)
        }
        if latchedNow {
            emit(event: "observability.snapshot_cleanup_unconfirmed",
                 detail: "orphaned=\(cleanup.orphaned) uncertainClose=\(cleanup.uncertainClose)", level: .warning)
        }
        // One event per transition, not per failed attempt: a persistent failure is counted, not repeated.
        switch outcome {
        case .failed(let failure) where previous != .failed:
            emit(event: "observability.snapshot_write_failed",
                 detail: "stage=\(failure.stage.rawValue) code=\(failure.code) leftTemporary=\(cleanup.orphaned)",
                 level: .warning)
        case .written where previous == .failed:
            emit(event: "observability.snapshot_write_recovered",
                 detail: "generation=\(job.generation)", level: .notice)
        default:
            break
        }
    }

    /// Event first, then the derived log line. A refusal already reported itself through the gate.
    private func emit(event name: String, detail: String, level: LogLevel) {
        let event = RuntimeEvent(kind: .health, event: name, detail: detail)
        eventLog?.append(event)
        logger.log(level, "\(event.event) \(detail)", category: .general)
    }
}
