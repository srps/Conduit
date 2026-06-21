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
