// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package final class AuditingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let base: any PrivilegeClient
    private let eventSink: @Sendable (RuntimeEvent) -> Void

    package init(
        base: any PrivilegeClient,
        eventSink: @escaping @Sendable (RuntimeEvent) -> Void
    ) {
        self.base = base
        self.eventSink = eventSink
    }

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        emit(operation: operation, outcome: "requested", valueCount: values.count)
        do {
            try base.execute(operation, values: values)
            emit(operation: operation, outcome: "succeeded", valueCount: values.count)
        } catch {
            emit(
                operation: operation,
                outcome: "failed",
                valueCount: values.count,
                error: error.displayDescription
            )
            throw error
        }
    }

    /// Batches are audited step by step but executed as one unit, so the audit
    /// trail is identical to the looping default while the elevation is not.
    /// Without this override the batch path would inherit the protocol default,
    /// which calls `execute(_:values:)` on `self` — auditing correctly, but
    /// losing the single-prompt property the batch exists for.
    package func execute(batch: [PrivilegedBatchStep]) throws {
        guard !batch.isEmpty else { return }
        for step in batch {
            emit(operation: step.operation, outcome: "requested", valueCount: step.values.count)
        }
        do {
            try base.execute(batch: batch)
            for step in batch {
                emit(operation: step.operation, outcome: "succeeded", valueCount: step.values.count)
            }
        } catch {
            // Which step failed is not observable through a batched elevation,
            // so every step is reported failed rather than guessing.
            for step in batch {
                emit(
                    operation: step.operation,
                    outcome: "failed",
                    valueCount: step.values.count,
                    error: error.displayDescription
                )
            }
            throw error
        }
    }

    private func emit(
        operation: PrivilegedOperation,
        outcome: String,
        valueCount: Int,
        error: String? = nil
    ) {
        var detail = "command=\(operation.rawValue) outcome=\(outcome) valueCount=\(valueCount)"
        if let error {
            detail += " error=\(error)"
        }
        eventSink(RuntimeEvent(kind: .auth, event: "auth.privilege_request", detail: detail))
    }
}
