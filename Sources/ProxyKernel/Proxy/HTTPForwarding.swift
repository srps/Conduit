// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

package struct HTTPRequestTarget: Sendable, Equatable {
    package var host: String
    package var port: Int
    package var directURL: URL?

    package static func parse(_ head: HTTPRequestHead) -> HTTPRequestTarget? {
        if head.method == .CONNECT {
            guard isSafeHTTPRequestTarget(head.uri),
                  let parsed = NoProxyMatcher.parseHostPort(from: head.uri),
                  let port = parsed.port,
                  isValidPort(port) else {
                return nil
            }
            return HTTPRequestTarget(host: parsed.host, port: port, directURL: URL(string: "https://\(head.uri)/"))
        }

        if let url = URL(string: head.uri), url.scheme != nil {
            guard let host = url.host, !host.isEmpty else { return nil }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard components?.user == nil, components?.password == nil else { return nil }
            let port = url.port ?? defaultPort(for: url.scheme)
            guard isValidPort(port) else { return nil }
            return HTTPRequestTarget(host: host, port: port, directURL: url)
        }

        guard isSafeHTTPRequestTarget(head.uri),
              let hostHeader = singleHostHeader(from: head.headers),
              isSafeHTTPHostHeader(hostHeader),
              let parsed = NoProxyMatcher.parseHostPort(from: hostHeader) else {
            return nil
        }
        let port = parsed.port ?? 80
        guard isValidPort(port) else { return nil }
        let urlText = "http://\(hostHeader)\(head.uri)"
        guard let url = URL(string: urlText) else { return nil }
        return HTTPRequestTarget(host: parsed.host, port: port, directURL: url)
    }

    package var pacURL: URL? {
        directURL
    }

    private static func singleHostHeader(from headers: HTTPHeaders) -> String? {
        let values = headers["Host"]
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https": return 443
        default: return 80
        }
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    package static func isSafeHTTPRequestTarget(_ value: String) -> Bool {
        !value.isEmpty && !containsHTTPControl(value)
    }

    package static func isSafeHTTPHostHeader(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, !containsHTTPControl(value) else {
            return false
        }
        let forbidden = CharacterSet(charactersIn: "/\\@?#").union(.whitespacesAndNewlines)
        return value.rangeOfCharacter(from: forbidden) == nil
    }

    package static func containsHTTPControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }
}

package enum HTTPHopByHopHeaders {
    private static let standardHopByHopHeaders = [
        "Connection",
        "Keep-Alive",
        "Proxy-Connection",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "Upgrade",
    ]

    package static func sanitizeForwardedRequestHeaders(_ headers: inout HTTPHeaders) {
        let connectionTokens = tokensNamedByConnection(headers)
        removeStandardHeaders(from: &headers)
        headers.remove(name: "Proxy-Authorization")
        for token in connectionTokens {
            headers.remove(name: token)
        }
    }

    package static func sanitizeForwardedResponseHeaders(_ headers: inout HTTPHeaders) {
        let connectionTokens = tokensNamedByConnection(headers)
        removeStandardHeaders(from: &headers)
        headers.remove(name: "Proxy-Authenticate")
        for token in connectionTokens {
            headers.remove(name: token)
        }
    }

    /// True when the request asks for an HTTP/1.1 protocol upgrade
    /// (RFC 9110 §7.8): a non-empty `Upgrade` header plus an `upgrade`
    /// token in `Connection`. WebSocket (`ws://` via an explicit proxy)
    /// is the practical case; the check is deliberately protocol-agnostic.
    package static func isUpgradeRequest(_ head: HTTPRequestHead) -> Bool {
        guard !head.headers["Upgrade"].isEmpty else { return false }
        return tokensNamedByConnection(head.headers).contains {
            $0.caseInsensitiveCompare("upgrade") == .orderedSame
        }
    }

    /// Hop-by-hop sanitization for a request we are *deliberately* relaying
    /// as a protocol upgrade: standard hop-by-hop fields are stripped, but
    /// `Upgrade` is preserved and `Connection: upgrade` is re-issued for the
    /// next hop. Without this carve-out the generic sanitizer strips the
    /// upgrade negotiation and the origin answers with a plain HTTP response.
    package static func sanitizeForwardedUpgradeRequestHeaders(_ headers: inout HTTPHeaders) {
        let upgradeValues = headers["Upgrade"]
        sanitizeForwardedRequestHeaders(&headers)
        for value in upgradeValues {
            headers.add(name: "Upgrade", value: value)
        }
        headers.replaceOrAdd(name: "Connection", value: "upgrade")
    }

    /// Response-side counterpart of
    /// `sanitizeForwardedUpgradeRequestHeaders(_:)` for a `101 Switching
    /// Protocols` head being relayed back to the client.
    package static func sanitizeForwardedUpgradeResponseHeaders(_ headers: inout HTTPHeaders) {
        let upgradeValues = headers["Upgrade"]
        sanitizeForwardedResponseHeaders(&headers)
        for value in upgradeValues {
            headers.add(name: "Upgrade", value: value)
        }
        headers.replaceOrAdd(name: "Connection", value: "upgrade")
    }

    private static func removeStandardHeaders(from headers: inout HTTPHeaders) {
        for name in standardHopByHopHeaders {
            headers.remove(name: name)
        }
    }

    private static func tokensNamedByConnection(_ headers: HTTPHeaders) -> [String] {
        headers["Connection"].flatMap { value in
            value.split(separator: ",").compactMap { raw -> String? in
                let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
        }
    }
}

package final class HTTPResponseBackpressureController: @unchecked Sendable {
    private struct State {
        var completed = false
    }

    private let clientChannel: Channel
    private let upstreamChannel: Channel
    private let observerName = "proxy.http.response.backpressure.\(UUID().uuidString)"
    private let lock = NIOLock()
    private var state = State()

    package init(clientChannel: Channel, upstreamChannel: Channel) {
        self.clientChannel = clientChannel
        self.upstreamChannel = upstreamChannel
    }

    package func install() {
        let observer = HTTPResponseClientWritabilityObserver(controller: self)
        clientChannel.pipeline.addHandler(observer, name: observerName).whenFailure { _ in }
    }

    @discardableResult
    package func write(
        _ part: HTTPServerResponsePart,
        flush: Bool,
        upstreamContext: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>
        if flush {
            future = clientChannel.writeAndFlush(part)
        } else {
            future = clientChannel.write(part)
        }
        pauseUpstreamIfNeeded(upstreamContext: upstreamContext)
        future.whenComplete { _ in
            self.clientWritabilityChanged(isWritable: self.clientChannel.isWritable)
        }
        return future
    }

    package func clientWritabilityChanged(isWritable: Bool) {
        guard isWritable, !isCompleted else { return }
        upstreamChannel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    package func complete() {
        let shouldRemove = lock.withLock { () -> Bool in
            guard !state.completed else { return false }
            state.completed = true
            return true
        }
        guard shouldRemove else { return }
        clientChannel.pipeline.removeHandler(name: observerName).whenFailure { _ in }
        upstreamChannel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    private var isCompleted: Bool {
        lock.withLock { state.completed }
    }

    private func pauseUpstreamIfNeeded(upstreamContext: ChannelHandlerContext) {
        guard !clientChannel.isWritable, !isCompleted else { return }
        upstreamContext.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
    }
}

private final class HTTPResponseClientWritabilityObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny

    private let controller: HTTPResponseBackpressureController

    init(controller: HTTPResponseBackpressureController) {
        self.controller = controller
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        controller.clientWritabilityChanged(isWritable: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
}
