// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Resolves an origin hostname for the transparent proxy's **direct** relay path.
///
/// This deliberately bypasses the system resolver. An intercepted hostname has
/// an `/etc/resolver/<domain>` file pointing it at the transparent proxy's own
/// loopback listener, and `LocalDNSForwarder` synthesizes the same answer for
/// anything that reaches it — so `getaddrinfo("api2.cursor.sh")` returns
/// `127.44.3.0`, the listener itself. A direct relay built on that answer would
/// connect to itself and spin. Implementations must resolve out-of-band and
/// reject loopback/link-local answers.
package protocol OriginResolving: Sendable {
    func resolveOrigin(host: String, port: Int, on eventLoop: EventLoop) -> EventLoopFuture<SocketAddress>
}

package enum OriginResolverError: Error, LocalizedError, Equatable {
    case unresolved(host: String)
    case selfReferential(host: String, ip: String)

    package var errorDescription: String? {
        switch self {
        case .unresolved(let host):
            return "no public A record for \(host)"
        case .selfReferential(let host, let ip):
            return "\(host) resolved to \(ip) (loopback/link-local) — refusing to relay to ourselves"
        }
    }
}

/// `OriginResolving` over DNS-over-HTTPS.
///
/// Answers are cached by hostname for the record's TTL (clamped) so the common
/// path costs nothing. A cache miss pays one TLS handshake against a DoH
/// provider.
///
/// Each lookup builds and tears down its own ephemeral `URLSession`. That is
/// deliberate, and is the cheap version of the machinery `LocalDNSForwarder`
/// needs: a long-lived session pins TCP keep-alive sockets to whatever route
/// existed when they were opened, and this resolver runs *precisely* when the
/// route just changed (VPN down). A fresh session per miss cannot reuse a
/// socket pinned to a dead utun, so there is nothing to reset on wake — and no
/// `invalidate()`-while-in-flight hazard to manage (see `DoHTransports`).
package final class DoHOriginResolver: OriginResolving {
    private struct CacheEntry {
        let ip: String
        let expiresAt: Date
    }

    /// Bounds the cache. Intercept rules cover a handful of domains, so this is
    /// generous; the cap only exists so a pathological rule set can't grow it
    /// without limit.
    private static let maximumEntries = 256
    private static let maximumTTL: TimeInterval = 300
    private static let fallbackTTL: TimeInterval = 60
    private static let requestTimeout: TimeInterval = 4

    private let logger: any LogSink
    private let dohProviders: @Sendable () -> [String]
    private let cache = NIOLockedValueBox<[String: CacheEntry]>([:])

    package init(logger: any LogSink, dohProviders: @escaping @Sendable () -> [String]) {
        self.logger = logger
        self.dohProviders = dohProviders
    }

    package func resolveOrigin(host: String, port: Int, on eventLoop: EventLoop) -> EventLoopFuture<SocketAddress> {
        let key = host.lowercased()

        if let ip = cachedIP(for: key) {
            return eventLoop.makeCompletedFuture { try Self.address(ip: ip, port: port, host: host) }
        }

        let providers = dohProviders()
        let promise = eventLoop.makePromise(of: SocketAddress.self)
        Task { [self] in
            guard let answer = await lookupA(host: key, providers: providers) else {
                promise.fail(OriginResolverError.unresolved(host: host))
                return
            }
            do {
                let address = try Self.address(ip: answer.ip, port: port, host: host)
                store(ip: answer.ip, ttl: answer.ttl, for: key)
                logger.log(.debug, "Origin resolver: \(host) → \(answer.ip) via DoH.", category: .network)
                promise.succeed(address)
            } catch {
                // A blocked answer is never cached: it is either a rebinding
                // attempt or our own intercept leaking back in, and both should
                // be re-evaluated on the next attempt.
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    /// Rejects answers that point back at this machine before they can become a
    /// relay loop.
    ///
    /// `gatewayMode: true` is passed unconditionally — it is what enables the
    /// IP-literal rules in `MetadataBlocklist`, and those rules are what we
    /// want here regardless of the user's gateway setting. This is a
    /// loop-prevention guard on our own direct path, not the SSRF policy that
    /// `gatewayMode` governs for relayed clients. RFC-1918 stays allowed, so a
    /// split-horizon origin on a corporate subnet still works.
    package static func address(ip: String, port: Int, host: String) throws -> SocketAddress {
        guard !MetadataBlocklist.isBlockedResolvedAddress(ip, gatewayMode: true) else {
            throw OriginResolverError.selfReferential(host: host, ip: ip)
        }
        return try SocketAddress(ipAddress: ip, port: port)
    }

    private func cachedIP(for key: String) -> String? {
        cache.withLockedValue { entries in
            guard let entry = entries[key] else { return nil }
            guard entry.expiresAt > Date() else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.ip
        }
    }

    private func store(ip: String, ttl: TimeInterval, for key: String) {
        let expiresAt = Date().addingTimeInterval(min(max(ttl, 1), Self.maximumTTL))
        cache.withLockedValue { entries in
            entries[key] = CacheEntry(ip: ip, expiresAt: expiresAt)
            guard entries.count > Self.maximumEntries else { return }
            let now = Date()
            entries = entries.filter { $0.value.expiresAt > now }
            while entries.count > Self.maximumEntries,
                  let soonest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                entries.removeValue(forKey: soonest)
            }
        }
    }

    /// A records only. The transparent proxy binds an IPv4 loopback listener and
    /// its clients reached it over IPv4, so an IPv6 origin buys nothing here.
    ///
    /// Every provider is tried in both encodings, first usable answer wins.
    /// Neither encoding is universal: of the three providers shipped in the
    /// default config, only Cloudflare answers `dns-json` on `/dns-query`
    /// (quad9 and dns.google reply `400`), while all three accept RFC 8484
    /// wire format. A JSON-only resolver would work today purely because
    /// Cloudflare is listed first, and would fail closed — i.e. black-hole the
    /// intercepted connection — the moment someone reordered the list. Same
    /// reasoning as `DNSForwardingHandler.resolveViaDoH`.
    private func lookupA(host: String, providers: [String]) async -> (ip: String, ttl: TimeInterval)? {
        let providers = providers.isEmpty ? ["https://cloudflare-dns.com/dns-query"] : providers
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        let query = DNSWireFormat.buildQuery(domain: host, qtype: 1)

        return await withTaskGroup(of: (ip: String, ttl: TimeInterval)?.self) { group in
            for provider in providers {
                group.addTask { await Self.fetchJSON(url: "\(provider)?name=\(encoded)&type=A") }
                group.addTask { await Self.fetchWire(provider: provider, query: query) }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// A short-lived session per request. See the type doc: nothing to reset on
    /// wake, and no invalidate-while-in-flight hazard.
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        // Empty, not nil: nil inherits the system proxy settings, which point at
        // Conduit's own listener. The DoH lookup would then be proxied through
        // the process trying to perform it.
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    private static func fetchJSON(url: String) async -> (ip: String, ttl: TimeInterval)? {
        guard let url = URL(string: url) else { return nil }
        let session = session()
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = payload["Answer"] as? [[String: Any]] else {
            return nil
        }

        for answer in answers {
            // type 1 == A. CNAMEs (type 5) share this array and lead it — their
            // `data` is a hostname. Filtering on type, not position, is what
            // keeps `api2geo.cursor.sh.` from being handed to the connect path.
            guard let type = answer["type"] as? Int, type == 1,
                  let ip = answer["data"] as? String else { continue }
            let ttl = (answer["TTL"] as? Int).map(TimeInterval.init) ?? fallbackTTL
            return (ip, ttl)
        }
        return nil
    }

    /// RFC 8484 wire format (`POST application/dns-message`).
    private static func fetchWire(provider: String, query: [UInt8]) async -> (ip: String, ttl: TimeInterval)? {
        guard let url = URL(string: provider) else { return nil }
        let session = session()
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(query)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count >= 12 else {
            return nil
        }

        let bytes = [UInt8](data)
        guard DNSWireFormat.responseQuestionMatches(query: query, response: bytes),
              let answer = DNSWireFormat.firstIPv4Answer(in: bytes) else {
            return nil
        }
        return (answer.ip, TimeInterval(answer.ttl))
    }
}
