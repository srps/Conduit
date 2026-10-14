// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import NIOCore

/// The machine's own answer to `SocketPathChecking`: the assigned addresses
/// by interface, and the source address the kernel picks for a peer, read by
/// connecting a UDP socket to it (no packet is sent). Read-only: it changes
/// nothing on the machine.
///
/// Interfaces are compared, not addresses: IPv6 may prefer a newer temporary
/// address on the same interface while the old one still works.
package struct SystemSocketPaths: SocketPathChecking {
    package init() {}

    package func verdicts(for queries: [SocketPathQuery]) -> [SocketPathVerdict] {
        guard !queries.isEmpty else { return [] }
        let interfaces: [String: String]
        do {
            interfaces = try Self.interfacesByAddress()
        } catch {
            return queries.map { _ in .unknown("interfaces_unavailable") }
        }
        // One route lookup per peer address in this call.
        var routes: [String: Route] = [:]
        return queries.map { query in
            guard let local = query.local.ipAddress, let peer = query.remote.ipAddress else {
                return .unknown("no_address")
            }
            guard let localInterface = interfaces[local] else { return .stranded("address_gone") }
            let route: Route
            if let cached = routes[peer] {
                route = cached
            } else {
                route = Self.route(to: query.remote)
                routes[peer] = route
            }
            switch route {
            case .source(let source):
                guard let sourceInterface = interfaces[source] else { return .unknown("source_unlisted") }
                return sourceInterface == localInterface ? .current : .stranded("interface_changed")
            case .none:
                return .stranded("no_route")
            case .failed(let reason):
                return .unknown(reason)
            }
        }
    }

    private enum Route {
        case source(String)
        case none
        case failed(String)
    }

    private static func interfacesByAddress() throws -> [String: String] {
        var result: [String: String] = [:]
        for device in try System.enumerateDevices() {
            guard let address = device.address?.ipAddress else { continue }
            // The first interface listing an address keeps it.
            if result[address] == nil { result[address] = device.name }
        }
        return result
    }

    /// The source address the kernel would use for `peer` now. The peer's
    /// sockaddr is used as is, so an IPv6 scope stays part of the lookup.
    private static func route(to peer: SocketAddress) -> Route {
        let family: CInt
        switch peer {
        case .v4: family = AF_INET
        case .v6: family = AF_INET6
        case .unixDomainSocket: return .failed("not_ip")
        }
        #if canImport(Darwin)
        let fd = socket(family, SOCK_DGRAM, 0)
        #else
        let fd = socket(family, CInt(SOCK_DGRAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return .failed("socket_errno_\(errno)") }
        defer { close(fd) }
        let connected = peer.withSockAddr { address, length in
            connect(fd, address, socklen_t(length))
        }
        guard connected == 0 else {
            switch errno {
            case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL: return .none
            default: return .failed("connect_errno_\(errno)")
            }
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return .failed("getsockname_errno_\(errno)") }
        let source: SocketAddress
        switch CInt(storage.ss_family) {
        case AF_INET:
            source = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { SocketAddress($0.pointee) }
            }
        case AF_INET6:
            source = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { SocketAddress($0.pointee) }
            }
        default:
            return .failed("source_family_\(storage.ss_family)")
        }
        guard let address = source.ipAddress else { return .failed("source_unnamed") }
        return .source(address)
    }
}
