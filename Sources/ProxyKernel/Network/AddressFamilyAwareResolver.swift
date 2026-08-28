// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Whether this host can actually reach IPv6 destinations.
///
/// A corporate laptop typically carries a link-local `fe80::` address on
/// every interface and nothing else, while public DNS still answers AAAA
/// for Microsoft, Apple and Google hosts. NIO's happy-eyeballs connector
/// then tries the AAAA first, and on this stack the connect comes back as a
/// channel with no remote address (see `HalfOpenChannelFallback`). The
/// fallback recovers, but only after a wasted connect and a warning per
/// upstream connection — ~5,900 of them in three days of proxy.log.
package enum IPv6Availability {
    /// Routable here means "worth trying a global AAAA answer with": not
    /// link-local (`fe80::/10`) and not loopback.
    package static func isRoutable(ipv6 address: String) -> Bool {
        let lower = address.lowercased()
        if lower == "::1" || lower == "::" { return false }
        // fe80::/10 covers fe80–febf.
        if lower.hasPrefix("fe"), let third = lower.dropFirst(2).first, "89ab".contains(third) {
            return false
        }
        return true
    }

    private static let cacheTTL: TimeInterval = 5
    private static let cache = NIOLockedValueBox<(value: Bool, at: Date)?>(nil)

    /// Enumerates interfaces (cached for a few seconds — this runs per
    /// connect). Errors enumerating count as "IPv6 available": the AAAA
    /// path then behaves exactly as before this check existed.
    package static func hasRoutableIPv6(now: Date = Date()) -> Bool {
        if let cached = cache.withLockedValue({ $0 }), now.timeIntervalSince(cached.at) < cacheTTL {
            return cached.value
        }
        let value: Bool
        do {
            value = try System.enumerateDevices().contains { device in
                guard let address = device.address, case .v6 = address, let ip = address.ipAddress else {
                    return false
                }
                return isRoutable(ipv6: ip)
            }
        } catch {
            value = true
        }
        cache.withLockedValue { $0 = (value, now) }
        return value
    }
}

/// `getaddrinfo`-backed resolver that answers AAAA queries with nothing
/// while the host has no routable IPv6 address, so happy-eyeballs only
/// races addresses it can use. Attach with `ClientBootstrap.resolver(_:)`.
package final class AddressFamilyAwareResolver: Resolver, Sendable {
    private let group: EventLoopGroup
    private let hasRoutableIPv6: @Sendable () -> Bool

    package init(
        group: EventLoopGroup,
        hasRoutableIPv6: @escaping @Sendable () -> Bool = { IPv6Availability.hasRoutableIPv6() }
    ) {
        self.group = group
        self.hasRoutableIPv6 = hasRoutableIPv6
    }

    package func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        Self.resolve(host: host, port: port, family: AF_INET, on: group.any())
    }

    package func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        let loop = group.any()
        guard hasRoutableIPv6() else {
            return loop.makeSucceededFuture([])
        }
        return Self.resolve(host: host, port: port, family: AF_INET6, on: loop)
    }

    /// `getaddrinfo` cannot be cancelled; the connector drops the future.
    package func cancelQueries() {}

    package struct ResolutionError: Error, Equatable {
        package let host: String
        package let rc: Int32
    }

    /// Every address of `family` for `host`, in resolver order. Runs
    /// `getaddrinfo` off the event loop.
    package static func resolve(
        host: String,
        port: Int,
        family: Int32,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<[SocketAddress]> {
        let promise = eventLoop.makePromise(of: [SocketAddress].self)
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = family
            #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
            #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &result)
            defer {
                if let result { freeaddrinfo(result) }
            }
            guard rc == 0 else {
                promise.fail(ResolutionError(host: host, rc: rc))
                return
            }

            var addresses: [SocketAddress] = []
            var cursor = result
            while let info = cursor {
                if let sockaddr = info.pointee.ai_addr {
                    switch info.pointee.ai_family {
                    case AF_INET:
                        let inAddr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        addresses.append(SocketAddress(inAddr, host: host))
                    case AF_INET6:
                        let in6Addr = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                        addresses.append(SocketAddress(in6Addr, host: host))
                    default:
                        break
                    }
                }
                cursor = info.pointee.ai_next
            }
            promise.succeed(addresses)
        }
        return promise.futureResult
    }
}
