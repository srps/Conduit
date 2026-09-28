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
    private let limiter: RuntimeEventRepeatGate

    package init(
        interval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable (String) -> KerberosMechStatus
    ) {
        self.probe = probe
        self.limiter = RuntimeEventRepeatGate(repeatInterval: interval, now: now)
    }

    /// `failure` with the mech's status attached, or `failure` unchanged when
    /// it is not a service-ticket failure or the host was probed within the
    /// interval.
    package func annotate(_ failure: KerberosAuthError) -> KerberosAuthError {
        guard case .serviceTicketUnavailable(let host, let major, let minor, nil) = failure,
              limiter.shouldEmit(host: host, reason: "krb5_mech_probe")
        else {
            return failure
        }
        return .serviceTicketUnavailable(host: host, major: major, minor: minor, mech: probe(host))
    }
}
