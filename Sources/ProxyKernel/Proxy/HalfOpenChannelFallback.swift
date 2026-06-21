// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOCore
import NIOPosix

/// Errors surfaced from the explicit-IPv4 reconnect path used when NIO's
/// happy-eyeballs connector reports a half-open channel.
package enum DirectIPv4FallbackError: Error, LocalizedError {
    case resolutionFailed(host: String, rc: Int32)
    case noIPv4Address(host: String)
    case resolutionTimedOut(host: String)

    package var errorDescription: String? {
        switch self {
        case .resolutionFailed(let host, let rc):
            return "IPv4 fallback resolution failed for \(host) (getaddrinfo rc=\(rc))"
        case .noIPv4Address(let host):
            return "IPv4 fallback: \(host) has no A record"
        case .resolutionTimedOut(let host):
            return "IPv4 fallback resolution timed out for \(host)"
        }
    }
}

package enum HalfOpenChannelFallback {
    private static let resolveIPv4TimeoutSeconds: Int64 = 10

    /// If a supposedly-connected channel has no remote address, close it and
    /// reconnect to the first IPv4 address for the same host.
    package static func apply(
        upstreamChannel: Channel,
        host: String,
        port: Int,
        on eventLoop: EventLoop,
        ipv4Reconnect: @escaping @Sendable (SocketAddress) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        if upstreamChannel.remoteAddress != nil {
            return eventLoop.makeSucceededFuture(upstreamChannel)
        }
        upstreamChannel.close(mode: .all, promise: nil)
        return resolveIPv4(host: host, port: port, on: eventLoop)
            .flatMap(ipv4Reconnect)
    }

    /// Resolve `host` to the first IPv4 `SocketAddress`. Uses `getaddrinfo`
    /// on a background queue and races it with a timeout so a blocked resolver
    /// cannot hang the request indefinitely.
    package static func resolveIPv4(
        host: String,
        port: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<SocketAddress> {
        let promise = eventLoop.makePromise(of: SocketAddress.self)
        let timeout = eventLoop.scheduleTask(in: .seconds(resolveIPv4TimeoutSeconds)) {
            promise.fail(DirectIPv4FallbackError.resolutionTimedOut(host: host))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
            #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &result)
            defer {
                if let result {
                    freeaddrinfo(result)
                }
            }

            guard rc == 0, let result else {
                eventLoop.execute {
                    timeout.cancel()
                    promise.fail(DirectIPv4FallbackError.resolutionFailed(host: host, rc: rc))
                }
                return
            }

            var cursor: UnsafeMutablePointer<addrinfo>? = result
            while let info = cursor {
                if info.pointee.ai_family == AF_INET,
                   let sockaddr = info.pointee.ai_addr {
                    let inAddr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }
                    let address = SocketAddress(inAddr, host: host)
                    eventLoop.execute {
                        timeout.cancel()
                        promise.succeed(address)
                    }
                    return
                }
                cursor = info.pointee.ai_next
            }

            eventLoop.execute {
                timeout.cancel()
                promise.fail(DirectIPv4FallbackError.noIPv4Address(host: host))
            }
        }
        return promise.futureResult
    }
}
