// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOHTTP1

/// Answers `Expect: 100-continue` on behalf of the proxy.
///
/// The proxy buffers/spools the complete request body before forwarding
/// (replay-aware body handling for multi-leg upstream auth), so *it* is the
/// party that decides whether the client should transmit the body — not the
/// origin. Without this handler a client that honors the expectation stalls
/// (strict clients) or waits out its fallback timer (curl waits ~1 s) on
/// every upload, and the forwarded `Expect` invites an interim `100` from
/// the upstream that the response forwarders would treat as the final head.
///
/// Behavior: on a request head whose `Expect` carries the `100-continue`
/// token, immediately write `100 Continue` to the client and strip the
/// satisfied expectation from the head before passing it inward, so
/// forwarded requests never carry it. Other `Expect` values pass through
/// untouched (RFC 9110 §10.1.1 — let the origin answer 417 if it wants).
///
/// Sits between the HTTP codec and `HTTPProxyHandler`. Every pipeline
/// splice (CONNECT direct/proxied, upgrade relay) MUST remove this handler
/// before removing the decoder: post-splice traffic is raw `ByteBuffer`s,
/// and this handler's typed unwrap would fatal-error on them.
final class HTTPExpectContinueHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head(var head) = part, Self.expectsContinue(head.headers) else {
            context.fireChannelRead(data)
            return
        }

        let interim = HTTPResponseHead(version: head.version, status: .continue)
        context.writeAndFlush(wrapOutboundOut(.head(interim)), promise: nil)

        Self.removeContinueExpectation(&head.headers)
        context.fireChannelRead(wrapInboundOut(.head(head)))
    }

    static func expectsContinue(_ headers: HTTPHeaders) -> Bool {
        headers["Expect"].contains { value in
            value.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("100-continue") == .orderedSame
            }
        }
    }

    /// Removes only the `100-continue` token; any other (unknown)
    /// expectation values are preserved for the origin to judge.
    static func removeContinueExpectation(_ headers: inout HTTPHeaders) {
        let remaining = headers["Expect"].flatMap { value in
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare("100-continue") != .orderedSame }
        }
        headers.remove(name: "Expect")
        for value in remaining {
            headers.add(name: "Expect", value: value)
        }
    }
}
