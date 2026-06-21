// SPDX-License-Identifier: Apache-2.0
import Darwin
import NIOCore

/// TCP keepalive parameters applied to every accepted client channel in `LocalProxyServer`
/// and to every outbound upstream socket in `ConnectionPool`. These cover the "zombie TCP"
/// case where the peer is silently gone but no FIN/RST was delivered (firewall drop, VPN
/// disconnect, laptop-on-another-network), which is the only long-silence failure mode the
/// relay itself cannot detect without probing the socket.
///
/// Defaults chosen for Cursor-style streaming:
/// * 60 s of complete silence before we probe → coexists with normal LLM thinking gaps
/// * 15 s between probes, 4 probes → worst-case zombie detection ≤ 2 minutes
/// Total time-to-detect-dead-peer = keepIdleSeconds + keepIntervalSeconds * keepCountProbes.
package struct TCPKeepaliveConfig: Sendable, Equatable {
    package var keepIdleSeconds: Int
    package var keepIntervalSeconds: Int
    package var keepCountProbes: Int

    package init(keepIdleSeconds: Int = 60, keepIntervalSeconds: Int = 15, keepCountProbes: Int = 4) {
        self.keepIdleSeconds = keepIdleSeconds
        self.keepIntervalSeconds = keepIntervalSeconds
        self.keepCountProbes = keepCountProbes
    }

    package static let `default` = TCPKeepaliveConfig()
}

/// Darwin TCP option wrappers for `NIOBSDSocket.Option`.
/// `TCP_KEEPALIVE` on Darwin is the idle-seconds-before-probing option
/// (Linux's `TCP_KEEPIDLE` equivalent). Same semantic, different constant name.
package enum TCPKeepaliveOption {
    package static var keepIdle: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: Darwin.TCP_KEEPALIVE)
    }
    package static var keepInterval: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: Darwin.TCP_KEEPINTVL)
    }
    package static var keepCount: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: Darwin.TCP_KEEPCNT)
    }
}

/// Applies the keepalive options to an already-open channel. Intended for accepted client
/// channels where NIO has already handed us an opened socket.
package func applyTCPKeepalive(
    to channel: Channel,
    config: TCPKeepaliveConfig = .default
) -> EventLoopFuture<Void> {
    channel.setOption(ChannelOptions.socketOption(.so_keepalive), value: 1).flatMap {
        channel.setOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle), value: CInt(config.keepIdleSeconds))
    }.flatMap {
        channel.setOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval), value: CInt(config.keepIntervalSeconds))
    }.flatMap {
        channel.setOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount), value: CInt(config.keepCountProbes))
    }
}
