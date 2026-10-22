// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Remembers a split-DNS entry-file write or removal that failed, and
/// retries it while the helper is seen available (#165). Shared by
/// `AppState` and `DaemonRuntimeHost`, next to the `SplitDNSVPNGate` it
/// works with; each host owns one, on its main actor.
///
/// Why it exists: every entry-file operation runs on an event (a VPN flip, a
/// start, a stop), and none of those repeats when the helper comes back.
/// Seen after a build swap, when the helper refused every caller until it
/// was reinstalled: the system proxy was repaired at once, `/etc/resolver`
/// stayed wrong until the next VPN flip. A *removal* that failed with the
/// VPN down is the dangerous direction: it is the bootstrap deadlock the
/// gate exists to prevent (see `SplitDNSVPNGate`).
///
/// A retry never replays the failed operation. It acts on what the gate, the
/// run state and the resolver switch want *now* (`desiredOperation`), so a
/// write that failed while the tunnel was up is not repeated after the
/// tunnel went down.
///
/// Bounded by construction: one pending slot, which a newer failure
/// replaces, and a retry only on an observation that the helper is
/// installed and answering, never blind. With no helper installed,
/// `HelperToolPrivilegeClient` falls back to AppleScript, and a blind retry
/// would raise admin password prompts.
package struct SplitDNSEntryFileRepair: Sendable {
    package enum Operation: String, Sendable, Equatable {
        case apply
        case remove
    }

    /// Which path ran the operation.
    package enum Source: String, Sendable, Equatable {
        case vpnTransition = "vpn_transition"
        case start
        case stop
        case retry
    }

    /// What one entry-file operation did.
    package struct Outcome: Sendable, Equatable {
        package let operation: Operation
        /// The error's description; `nil` when the operation landed.
        package let failure: String?

        package static func succeeded(_ operation: Operation) -> Outcome {
            Outcome(operation: operation, failure: nil)
        }

        package static func failed(_ operation: Operation, _ error: any Error) -> Outcome {
            Outcome(operation: operation, failure: error.localizedDescription)
        }

        package init(operation: Operation, failure: String?) {
            self.operation = operation
            self.failure = failure
        }
    }

    package struct Pending: Sendable, Equatable {
        package let operation: Operation
        package let source: Source
        /// Failed attempts in this episode, the first included.
        package let attempts: Int
    }

    /// How long a host with a pending repair waits before it next asks
    /// whether the helper is available, after the first failure. Each failed
    /// retry doubles it, up to `helperCheckBackoffLimit` times this. Not
    /// authority (STYLE rule 11): the check only gathers an observation, and
    /// the retry it may lead to acts on the gate's current state; the
    /// doubling is a rate limit on a repair. It is the one way a host hears
    /// of a helper installed outside it (`sudo ./install-helper.sh`), and
    /// the daemon's only way at all.
    package static let helperCheckInterval: Duration = .seconds(60)
    /// The most the check interval is multiplied by: 16 minutes between
    /// checks at the default interval, for a failure the helper is not behind
    /// (an unreadable journal, say), which no retry repairs.
    package static let helperCheckBackoffLimit = 16

    /// What failed and has not been repaired yet.
    package private(set) var pending: Pending?

    package init() {}

    /// The operation that puts the entry files where they belong now: present
    /// while the tunnel is up under a running proxy, absent otherwise. Absent
    /// with the tunnel up and the proxy down is what a stop leaves; the
    /// gate's `.nothing` there means "no flip to act on", not "keep them".
    package static func desiredOperation(gate: SplitDNSVPNGate, runtimeStarted: Bool) -> Operation {
        runtimeStarted && gate.entriesWanted ? .apply : .remove
    }

    /// The wait before the next helper check while `pending` is set.
    package func helperCheckDelay(base: Duration) -> Duration {
        let retries = max(0, (pending?.attempts ?? 1) - 1)
        return base * min(1 << min(retries, 30), Self.helperCheckBackoffLimit)
    }

    /// Whether to retry on an observation of the helper: something is
    /// pending and the helper is installed and answering.
    package func shouldRetry(helperAvailable: Bool) -> Bool {
        pending != nil && helperAvailable
    }

    /// Records what an entry-file operation did. A failure is reported and
    /// remembered; a success while something was pending reports the repair
    /// and forgets it.
    package mutating func record(
        _ outcome: Outcome,
        source: Source,
        report: (RuntimeEvent, LogLevel) -> Void
    ) {
        if let failure = outcome.failure {
            let attempts = (pending?.attempts ?? 0) + 1
            pending = Pending(operation: outcome.operation, source: source, attempts: attempts)
            report(
                RuntimeEvent(
                    kind: .config,
                    event: "platform.split_dns_failed",
                    detail: "operation=\(outcome.operation.rawValue) source=\(source.rawValue) attempt=\(attempts) reason=\(failure)"
                ),
                .warning
            )
            return
        }
        guard let repaired = pending else { return }
        pending = nil
        report(
            RuntimeEvent(
                kind: .config,
                event: "platform.split_dns_repaired",
                detail: "operation=\(outcome.operation.rawValue) by=\(source.rawValue) failed=\(repaired.operation.rawValue) attempts=\(repaired.attempts)"
            ),
            .notice
        )
    }

    /// One retry of what is pending, against the state now. Call it on the
    /// same actor as the gate's `update(_:)`, synchronously, for the reason
    /// `SplitDNSVPNGate.reconcileEntryFiles` gives: a VPN report landing
    /// between the decision and the write would make it act on a stale one,
    /// and an apply landing after a VPN-down removal leaves entry files with
    /// the tunnel gone. And only with no start or stop in flight: a start's
    /// apply runs off the actor, and its run state is not settled until it
    /// returns.
    ///
    /// With the resolver switch off, the retry is the switch-off teardown,
    /// `clearRecorded`, and it is repaired once the journal names no file of
    /// ours: that teardown can fail for the same reason the entry-file
    /// operation did. With it on, the entry files are applied or removed,
    /// and recorded files for domains the config no longer names are removed
    /// too (`clearUnconfiguredRecordedFiles`).
    package mutating func retry(
        trigger: String,
        gate: SplitDNSVPNGate,
        config: ProxyConfig,
        resolversManaged: Bool,
        dnsManager: DNSManager,
        logger: any LogSink,
        runtimeStarted: Bool,
        report: (RuntimeEvent, LogLevel) -> Void
    ) {
        guard let pending else { return }
        let operation = resolversManaged ? Self.desiredOperation(gate: gate, runtimeStarted: runtimeStarted) : .remove
        report(
            RuntimeEvent(
                kind: .config,
                event: "platform.split_dns_retry",
                detail: "operation=\(operation.rawValue) trigger=\(trigger) managed=\(resolversManaged) attempt=\(pending.attempts + 1)"
            ),
            .notice
        )
        let outcome: Outcome
        do {
            if !resolversManaged {
                try dnsManager.clearRecorded(configs: [config], logger: logger)
                guard !dnsManager.hasManagedState() else { throw RecordedFilesRemain() }
            } else {
                switch operation {
                case .apply: try dnsManager.applyEntryFiles(config: config, logger: logger)
                case .remove: try dnsManager.clearEntryFiles(config: config, logger: logger)
                }
                try dnsManager.clearUnconfiguredRecordedFiles(config: config, logger: logger)
            }
            outcome = .succeeded(operation)
        } catch {
            outcome = .failed(operation, error)
        }
        record(outcome, source: .retry, report: report)
    }

    private struct RecordedFilesRemain: Error, LocalizedError {
        var errorDescription: String? { "resolver files this app wrote are still recorded after the switch-off teardown" }
    }
}
