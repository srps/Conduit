// SPDX-License-Identifier: Apache-2.0
import NIOCore

extension ChannelOptions {
    /// `TCP_NODELAY` for every channel that carries relayed user traffic.
    ///
    /// Without it, Nagle's algorithm holds small writes until the previous
    /// segment is ACKed, and the peer's delayed-ACK timer (~100 ms on macOS)
    /// holds that ACK — so each small-record hop can add up to ~200 ms.
    /// A proxy chain multiplies this: the transparent-intercept path alone is
    /// client → :443 relay → transparent proxy → upstream, three hops each
    /// way. Interactive HTTP/2 streams (Cursor's bidi agent RPC) write many
    /// small TLS records back-to-back and visibly stutter — observed as
    /// "streaming responses are being buffered by a proxy" with ~1 s
    /// response pairing before this option was applied. Standard practice
    /// for proxies (nginx/HAProxy default to nodelay); the cost is a few
    /// more small packets on the wire.
    package static var tcpNoDelay: ChannelOptions.Types.SocketOption {
        ChannelOptions.tcpOption(.tcp_nodelay)
    }
}
