// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import ProxyKernel

/// What the raw Kerberos mech answered when asked for the same service name
/// SPNEGO could not get a ticket for.
package enum KerberosMechStatus: Equatable, Sendable {
    /// The mech's own major and minor status. A minor that is a Kerberos
    /// error names the real cause SPNEGO hid behind `BAD_MECH, minor 0`.
    case status(major: OM_uint32, minor: OM_uint32)
    /// Latest diagnostic within the probe interval; useful to logging but
    /// insufficient to start a new recovery for the current failure.
    case cachedStatus(major: OM_uint32, minor: OM_uint32)
    /// The diagnostic call could not be made (the name did not import).
    case probeFailed
}

/// Explains a service-ticket failure SPNEGO reported without a cause (#99).
///
/// SPNEGO answers `GSS_S_BAD_MECH, minor 0` for any failure of the Kerberos
/// mech (#73), so the failure's own codes say nothing about why. For a
/// `.serviceTicketUnavailable` this asks the Kerberos mech directly, once,
/// for the same SPN and attaches its status as `mech`, which
/// `KerberosAuthError.diagnosticDetail` reports as `krb5_major=`,
/// `krb5_minor=` and `krb5_error=`.
///
/// - The extra call is a TGS request, so it runs at most once per host per
///   `interval` (a `RuntimeEventRepeatGate`, 64 hosts): only while a host is
///   failing, and not on every handshake.
/// - It is diagnostic only. The returned error has the same case, host and
///   codes, so classification, the gate cooldown and the NTLM fallback are
///   unchanged whatever the probe answers.
/// - The caller runs it inside `GSSInitiatorGate`: the probe enters the same
///   Heimdal KDC-locate path the gate serialises.
package final class KerberosMechDiagnoser: @unchecked Sendable {
    package static let shared = KerberosMechDiagnoser(probe: SystemGSSTokenProvider.probeKerberosMech(host:))

    private let probe: @Sendable (String) -> KerberosMechStatus
    private struct Entry {
        let probedAt: Date
        let status: KerberosMechStatus
    }
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let capacity: Int

    package init(
        interval: TimeInterval = 60,
        capacity: Int = RuntimeEventRepeatGate.maximumEntries,
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable (String) -> KerberosMechStatus
    ) {
        self.probe = probe
        precondition(interval.isFinite && interval >= 0 && capacity > 0)
        self.interval = interval
        self.capacity = capacity
        self.now = now
    }

    /// Attach the latest probe within the interval. Independent log gates
    /// can then report its cause without triggering another TGS request.
    package func annotate(_ failure: KerberosAuthError) -> KerberosAuthError {
        guard case .serviceTicketUnavailable(let host, let major, let minor, nil) = failure
        else {
            return failure
        }
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if let entry = entries[host], current.timeIntervalSince(entry.probedAt) < interval {
            let status: KerberosMechStatus
            if case .status(let major, let minor) = entry.status {
                status = .cachedStatus(major: major, minor: minor)
            } else {
                status = entry.status
            }
            return .serviceTicketUnavailable(host: host, major: major, minor: minor, mech: status)
        }
        let status = probe(host)
        if entries[host] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.probedAt < $1.value.probedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[host] = Entry(probedAt: now(), status: status)
        return .serviceTicketUnavailable(host: host, major: major, minor: minor, mech: status)
    }
}
