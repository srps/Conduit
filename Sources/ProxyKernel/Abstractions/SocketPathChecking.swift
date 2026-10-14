// SPDX-License-Identifier: Apache-2.0
import NIOCore

/// One connected socket's two ends, as the socket itself reports them.
package struct SocketPathQuery: Sendable {
    package let local: SocketAddress
    package let remote: SocketAddress

    package init(local: SocketAddress, remote: SocketAddress) {
        self.local = local
        self.remote = remote
    }
}

/// Whether a connected socket's path still exists (#156).
package enum SocketPathVerdict: Equatable, Sendable {
    /// The kernel would still send to the peer from the socket's interface.
    case current
    /// The socket cannot carry traffic any more; the label says why
    /// (`address_gone`, `interface_changed`, `no_route`).
    case stranded(String)
    /// The check itself failed; the socket is left alone.
    case unknown(String)
}

/// Answers, without sending a packet, whether each socket's local address is
/// still assigned and still on the interface the kernel would now pick for
/// its peer. A VPN going down takes its address; a VPN coming up moves the
/// route to its peers onto the tunnel. A socket left behind by either can
/// never carry traffic again, so it is closed instead of timing out.
///
/// It is evidence, not proof: a recreated tunnel with the same address, or
/// a changed NAT behind an unchanged interface, looks current. Those
/// sockets fall back to TCP keepalive and response timeouts.
///
/// Implementations may share work across one call: a sweep asks about every
/// tracked socket at once.
package protocol SocketPathChecking: Sendable {
    /// One verdict per query, in order.
    func verdicts(for queries: [SocketPathQuery]) -> [SocketPathVerdict]
}

/// A checker from a closure over one socket at a time, for tests and the
/// simulator, which stand in for the machine's interfaces and routes.
package struct ClosureSocketPaths: SocketPathChecking {
    private let verdict: @Sendable (SocketPathQuery) -> SocketPathVerdict

    package init(_ verdict: @escaping @Sendable (SocketPathQuery) -> SocketPathVerdict) {
        self.verdict = verdict
    }

    package func verdicts(for queries: [SocketPathQuery]) -> [SocketPathVerdict] {
        queries.map(verdict)
    }
}
