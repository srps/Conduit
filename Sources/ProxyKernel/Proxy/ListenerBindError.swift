// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

/// Why a listener could not take its address.
///
/// Raw NIO bind failures reach the UI verbatim: `Error.displayDescription`
/// forwards `IOError.description`, so a port conflict surfaces as
/// `IOError { errnoCode: 48, reason: bind(descriptor:ptr:bytes:) }`. That
/// names neither the listener, nor the address, nor a way out — a user who
/// hits it has to go find the conflicting process themselves. Bind paths
/// classify through here so the failure explains itself instead.
package enum ListenerBindError: Error, LocalizedError, Equatable {
    /// Another socket already holds `host:port`.
    ///
    /// On Darwin this is terminal rather than a race we can win: `SO_REUSEADDR`
    /// does *not* permit a second bind over a socket that is already
    /// `LISTEN`ing (verified — the second bind returns `EADDRINUSE`), and we
    /// deliberately never set `SO_REUSEPORT`, which would. `SO_REUSEPORT` lets
    /// any process able to bind the port join the accept set and take a share
    /// of inbound connections; for a proxy that forwards `Proxy-Authorization`
    /// headers, handing a co-resident process a slice of client traffic is not
    /// a trade worth making for a smaller accept gap.
    /// `holder` is a description of the conflicting process when one could be
    /// identified — the difference between "go find it" and "here it is".
    /// It is `nil` when no probe was supplied, the holder belongs to another
    /// user, or the platform declined the lookup.
    case addressInUse(listener: String, host: String, port: Int, holder: String?)

    /// The address is not assignable on this host — usually a loopback alias
    /// that has not been installed yet (the transparent proxy's `127.44.3.0`).
    case addressUnavailable(listener: String, host: String, port: Int)

    /// Anything else, preserving the operating system's own reason.
    case bindFailed(listener: String, host: String, port: Int, reason: String)

    /// Maps a raw bind error onto the classification. Non-`IOError` failures
    /// keep their description under `.bindFailed` rather than being guessed at.
    package static func classify(
        _ error: Error,
        listener: String,
        host: String,
        port: Int,
        holderProbe: (any ListenerPortHolderProbing)? = nil
    ) -> ListenerBindError {
        guard let ioError = error as? IOError else {
            return .bindFailed(listener: listener, host: host, port: port, reason: error.displayDescription)
        }
        switch ioError.errnoCode {
        case EADDRINUSE:
            return .addressInUse(
                listener: listener,
                host: host,
                port: port,
                holder: holderProbe?.describeHolder(host: host, port: port)
            )
        case EADDRNOTAVAIL:
            return .addressUnavailable(listener: listener, host: host, port: port)
        default:
            return .bindFailed(listener: listener, host: host, port: port, reason: ioError.description)
        }
    }

    /// Whether waiting could plausibly change the outcome.
    ///
    /// `.addressInUse` is retriable because the common benign cause is a
    /// handoff — an outgoing instance (an app upgrade replacing a running
    /// copy) still holding the port for the moment it takes to exit. A
    /// conflict that outlives the retry budget is someone else's listener and
    /// no amount of further waiting fixes it. `.addressUnavailable` is
    /// retriable because a loopback alias may be mid-install. Everything else
    /// fails fast: retrying `EACCES` on a privileged port ten times just
    /// stalls the start path for ten seconds before reporting the same error.
    package var isRetriable: Bool {
        switch self {
        case .addressInUse, .addressUnavailable: return true
        case .bindFailed: return false
        }
    }

    package var errorDescription: String? {
        switch self {
        case .addressInUse(let listener, let host, let port, let holder):
            guard let holder else {
                return """
                    \(listener) could not bind \(host):\(port) — the port is already held by another \
                    process. Identify it with `lsof -nP -iTCP@\(host):\(port) -sTCP:LISTEN`, then either \
                    stop it or change the port in Settings.
                    """
            }
            return """
                \(listener) could not bind \(host):\(port) — the port is held by \(holder). Stop that \
                process to free the port, or change the port in Settings.
                """
        case .addressUnavailable(let listener, let host, let port):
            return """
                \(listener) could not bind \(host):\(port) — the address is not assigned to any interface \
                on this machine. If \(host) is a loopback alias, it needs to be installed before the \
                listener can take it.
                """
        case .bindFailed(let listener, let host, let port, let reason):
            return "\(listener) could not bind \(host):\(port) — \(reason)."
        }
    }
}
