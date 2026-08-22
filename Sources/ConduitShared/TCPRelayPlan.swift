// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What the helper should do with a `start-tcp-relay` request, given what it
/// is already running.
///
/// The helper used to stop-then-start unconditionally. Every one of the 31
/// `TCP relay started` lines in the field log carried the same parameters,
/// so each was a socket torn down and rebound for nothing — and because the
/// stop also ran `ifconfig lo0 -alias <ip>`, the intercept IP left the
/// loopback interface 31 times while the app's own transparent-proxy
/// listener was bound to it. The one path where the parameters genuinely
/// change is the ephemeral-port dance in `startTransparentProxy`: relay to a
/// provisional port so the alias exists, bind, then re-point at the real
/// port. That re-point was pulling the alias out from under the listener it
/// had just enabled.
///
/// Lives here, not in the helper, because the helper is an executable target
/// and this is the decision worth a test.
public struct TCPRelayParameters: Equatable, Sendable {
    public var listenPort: Int
    public var targetPort: Int
    public var host: String

    public init(listenPort: Int, targetPort: Int, host: String) {
        self.listenPort = listenPort
        self.targetPort = targetPort
        self.host = host
    }
}

public enum TCPRelayPlan: Equatable, Sendable {
    /// Same parameters as the running relay: answer ok, touch nothing.
    case unchanged
    /// Same host, different ports: restart the listener, keep the alias.
    case repoint
    /// Nothing running, or a different host: stop what runs — the alias
    /// too, but only if the host changes — then alias and start.
    case start

    public static func plan(current: TCPRelayParameters?, requested: TCPRelayParameters) -> TCPRelayPlan {
        guard let current else { return .start }
        if current == requested { return .unchanged }
        return current.host == requested.host ? .repoint : .start
    }
}
