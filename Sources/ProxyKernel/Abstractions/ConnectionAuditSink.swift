// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Per-connection audit log surface. A
/// dedicated sink for `ConnectionAuditRecord` values that lets the kernel
/// emit one structured record per completed connection without taking on
/// the obligations of `LogSink` (verbosity filters, level routing, NDJSON
/// formatting for prose log lines).
///
/// Implementations:
///
///   * `FileConnectionAuditSink` — bounded NDJSON file writer with size
///     rotation. The production path; used by the SwiftUI app and (when
///     enabled by config) by the headless CLIs.
///   * `DiscardingConnectionAuditSink` — no-op. Default for headless
///     daemons (`pm-proxy`) and tests that don't care about audit output.
///   * `RecordingConnectionAuditSink` — in-memory capture for tests that
///     want to assert on the records the kernel emitted.
///
/// `record(_:)` MUST be safe to call from any thread / event loop. The
/// kernel emits records from the NIO event loops (HTTP/CONNECT close
/// callbacks) and from `MainActor` (e.g. when the orchestrator
/// short-circuits a connection it never opened a channel for).
package protocol ConnectionAuditSink: Sendable {
    /// Queue the supplied audit record for emission. Returns immediately;
    /// the implementation decides whether to write synchronously, batch,
    /// or flush asynchronously. For the file-backed sink, an explicit
    /// `flush()` (called at daemon shutdown / config reload) guarantees
    /// durability.
    func record(_ record: ConnectionAuditRecord)
}
