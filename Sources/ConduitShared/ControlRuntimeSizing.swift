// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The free text and element count one frame would carry, summed before any byte is
/// serialized. It refuses as soon as the running total passes the frame limit, so a
/// message that cannot publish costs no more than the limit to reject.
///
/// The sums are lower bounds on the encoded size. Text is counted in its raw UTF-8 bytes,
/// and JSON only adds to a string, so a raw total above the limit can never fit. Elements
/// are counted at two bytes each, the size of an empty object plus its separator. Numbers,
/// closed enums and keys are not counted, so the sum is never above the output. Both
/// checks are sound for rejection. Neither is a tight prediction of the output: the
/// published size is checked exactly after encoding.
///
/// Work bound for text: `text` reads at most `remaining + 1` UTF-8 bytes of a value before
/// it refuses, where `remaining` is the budget left at that point. It never reads a
/// longer value to the end. This is a claim about the loop, not the string: a bridged
/// string whose first UTF-8 access materializes the whole value is outside it. Values
/// decoded from the wire are native strings; a caller-built bridged string is not covered.
package struct ControlFrameBudget: Sendable {
    private let limit: Int
    private var used = 0

    package init(limit: Int) {
        self.limit = limit
    }

    /// Adds one text value's UTF-8 bytes. A missing value adds nothing.
    package mutating func text(_ value: String?) throws {
        guard let value else { return }
        let room = limit - used
        var count = 0
        for _ in value.utf8 {
            count += 1
            guard count <= room else { throw ControlRuntimeWireError.frameTooLarge }
        }
        try add(count)
    }

    /// Adds the minimum encoded size of `count` elements.
    package mutating func elements(_ count: Int) throws {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw ControlRuntimeWireError.frameTooLarge }
        try add(bytes)
    }

    private mutating func add(_ bytes: Int) throws {
        let (sum, overflow) = used.addingReportingOverflow(bytes)
        guard !overflow, sum <= limit else { throw ControlRuntimeWireError.frameTooLarge }
        used = sum
    }
}

// MARK: - Messages

extension ControlRuntimeMessage {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch body {
        case .request:
            // Requests carry identifiers, counts and enumerated values only.
            break
        case .response(let response):
            try response.measure(into: &budget)
        case .frame(let frame):
            try frame.measure(into: &budget)
        }
    }
}

extension ControlRuntimeResponse {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .admission, .requestLookup, .failure:
            break
        case .lookup(let lookup):
            if case .finished(let outcome) = lookup {
                try outcome.measure(into: &budget)
            }
        case .snapshot(let snapshot):
            try snapshot.measure(into: &budget)
        case .page(let reply):
            try reply.measure(into: &budget)
        }
    }
}

extension ControlRuntimeFrame {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .baseline(let baseline):
            try baseline.snapshot.measure(into: &budget)
        case .snapshot(let snapshot):
            try snapshot.measure(into: &budget)
        case .events(let batch):
            try budget.elements(batch.events.count)
            for record in batch.events {
                try record.measure(into: &budget)
            }
        case .operationFinished(let finished):
            try finished.outcome.measure(into: &budget)
        case .replayCaughtUp, .end:
            break
        }
    }
}

// MARK: - Operations

extension ControlOperationOutcome {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .completed(let completion):
            try completion.result.measure(into: &budget)
        case .partiallyCompleted(let modules):
            try budget.elements(modules.entries.count)
        case .configurationSettled(let receipt):
            try budget.elements(receipt.modules.count)
        case .superseded, .failed, .preferencesSettled:
            break
        }
    }
}

extension ControlCommandResult {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .upstreamProbe(let probe):
            try budget.text(probe.name)
            try budget.text(probe.endpoint)
            try budget.elements(probe.displayNotices.count)
        case .settled, .dnsLiveness, .preflight, .platformWrite, .dnsDisable:
            break
        }
    }
}

// MARK: - Pages

extension ControlPageReply {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .activeConnections(let page):
            try page.measure(into: &budget)
        case .upstreamHealth(let page):
            try page.measure(into: &budget)
        case .tunnelBindings(let page):
            try page.measure(into: &budget)
        case .tunnelDNSHosts(let page):
            try page.measure(into: &budget)
        case .unavailable:
            break
        }
    }
}

extension ControlCollectionPage {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.elements(rows.count)
        for row in rows {
            try row.measure(into: &budget)
        }
    }
}

extension ControlConnectionRow {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.text(destination)
        try budget.text(upstream)
        try budget.text(method)
        try budget.text(authMethod)
        try budget.elements(displayNotices.count)
    }
}

extension ControlUpstreamRow {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.text(name)
        try budget.text(endpoint)
        try budget.elements(displayNotices.count)
    }
}

extension ControlTunnelBindingRow {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.text(label)
        try budget.text(localHost)
        try budget.text(remoteHost)
        try budget.elements(displayNotices.count)
    }
}

extension ControlTunnelDNSHostRow {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.text(hostname)
        try budget.elements(displayNotices.count)
    }
}

// MARK: - Events

extension ControlRuntimeEventRecord {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .known(let event):
            try budget.text(event.kind)
            try budget.text(event.event)
            try budget.text(event.detail)
            if let typed = event.typed {
                try typed.measure(into: &budget)
            }
        case .unknown:
            // A display record is never encoded, so it has no wire size to measure.
            throw ControlRuntimeWireError.invalidValue
        }
    }
}

extension ControlTypedRuntimeEvent {
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .lifecycle(let lifecycle):
            try lifecycle.measure(into: &budget)
        case .configWorkflow:
            // Closed enums and bounded integers only: no free text to count, as the lifecycle's closed cases.
            break
        }
    }
}

extension ControlLifecycleEvent {
    /// Counts the free text of a lifecycle value. Only `versionChanged` carries text, and
    /// its two versions are the only strings. The other cases hold closed enums and
    /// integers, which the sum leaves out, as it does every number.
    package func measure(into budget: inout ControlFrameBudget) throws {
        switch self {
        case .versionChanged(let from, let to):
            try budget.text(from)
            try budget.text(to)
        case .superseded, .coalesced, .terminationDrainExpired, .moduleSettled:
            break
        }
    }
}

// MARK: - Snapshot

extension ControlBaseline {
    package func measure(into budget: inout ControlFrameBudget) throws {
        try snapshot.measure(into: &budget)
    }
}

extension ControlRuntimeSnapshot {
    /// The scalar text of a snapshot. Its counts, enums and timestamps are fixed width.
    package func measure(into budget: inout ControlFrameBudget) throws {
        try budget.text(profileName)
        try budget.text(activeUpstream)
        try budget.text(healthSummary)
        try budget.text(proxyError)
        try budget.text(dnsError)
        try budget.text(tunnelsError)
        try budget.text(vpnInterfaceName)
        try budget.text(lastAuthFallbackReason)
        try budget.text(tunnelDNSOverride.unavailableReason)
        try budget.text(bindings.proxy?.host)
        try budget.text(bindings.socks?.host)
        try budget.text(bindings.localPAC?.host)
        try budget.text(bindings.dns?.host)
        try budget.text(bindings.transparentProxy?.host)
        try budget.elements(displayNotices.count)
    }
}
