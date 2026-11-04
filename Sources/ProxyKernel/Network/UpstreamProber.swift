// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

package enum ProbeOutcome: Equatable, Sendable {
    case answered, unreachable, silent
}

package struct ProbeResult: Identifiable, Sendable {
    package     let id: UUID
    package     let proxy: UpstreamProxy
    package     let latencyMS: Int
    package     let outcome: ProbeOutcome

    package var reachable: Bool { outcome == .answered }

    package init(proxy: UpstreamProxy, latencyMS: Int, outcome: ProbeOutcome) {
        self.id = proxy.id
        self.proxy = proxy
        self.latencyMS = latencyMS
        self.outcome = outcome
    }

    package init(proxy: UpstreamProxy, latencyMS: Int, reachable: Bool) {
        self.init(proxy: proxy, latencyMS: latencyMS, outcome: reachable ? .answered : .unreachable)
    }
}

package struct UpstreamProbeSummary: Sendable {
    package let results: [ProbeResult]

    package init(results: [ProbeResult]) { self.results = results }

    package var hasReachableUpstream: Bool {
        results.contains { $0.reachable }
    }

    package var bestReachableUpstream: UpstreamProxy? {
        results.first(where: { $0.reachable })?.proxy
    }

    package var isInconclusive: Bool {
        !hasReachableUpstream && results.contains { $0.outcome == .silent }
    }

    package var silentEndpoints: [String] {
        results.filter { $0.outcome == .silent }.map(\.proxy.endpoint)
    }
}

package final class UpstreamProber: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let timeoutSeconds: TimeInterval

    package static let defaultTimeoutSeconds: TimeInterval = 3

    package init(group: EventLoopGroup, logger: any LogSink, timeoutSeconds: TimeInterval = defaultTimeoutSeconds) {
        self.group = group
        self.logger = logger
        self.timeoutSeconds = timeoutSeconds
    }

    package func probeAll(_ proxies: [UpstreamProxy]) async -> [ProbeResult] {
        let enabledProxies = proxies.filter(\.enabled)
        let results = await withTaskGroup(of: ProbeResult.self, returning: [ProbeResult].self) { group in
            for proxy in enabledProxies {
                group.addTask { await self.probe(proxy) }
            }
            var collected: [ProbeResult] = []
            collected.reserveCapacity(enabledProxies.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        return results.sorted { $0.latencyMS < $1.latencyMS }
    }

    package func summarize(_ proxies: [UpstreamProxy]) async -> UpstreamProbeSummary {
        UpstreamProbeSummary(results: await probeAll(proxies))
    }

    private func probe(_ proxy: UpstreamProxy) async -> ProbeResult {
        let start = DispatchTime.now()
        let totalBudgetNanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let deadlineUptimeNanos = start.uptimeNanoseconds &+ totalBudgetNanos
        let eventLoop = group.next()
        let outcomePromise = eventLoop.makePromise(of: ProbeOutcome.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .resolver(AddressFamilyAwareResolver(group: group))
                .connectTimeout(.milliseconds(Int64(timeoutSeconds * 1_000)))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(
                        UpstreamProxyProbeHandler(
                            deadlineUptimeNanos: deadlineUptimeNanos,
                            outcome: outcomePromise
                        )
                    )
                }
                .connect(host: proxy.host, port: proxy.port)
                .get()
        } catch {
            outcomePromise.succeed(.unreachable)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return ProbeResult(proxy: proxy, latencyMS: elapsed, outcome: .unreachable)
        }

        let outcome: ProbeOutcome
        do {
            outcome = try await outcomePromise.futureResult.get()
        } catch {
            logger.log(.warning, "Probe of \(proxy.endpoint) ended without an outcome: \(error.displayDescription)", category: .network)
            outcome = .unreachable
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        channel.close(mode: .all, promise: nil)
        return ProbeResult(proxy: proxy, latencyMS: elapsed, outcome: outcome)
    }
}

private final class UpstreamProxyProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// Cap on probe response head accumulation. Sized well above any realistic
    /// CONNECT response (status line + headers, including multi-KB Kerberos /
    /// Negotiate challenge tokens) so legitimate upstreams never hit it, but
    /// still bounds the memory a clearly misbehaving peer can force us to hold.
    static let maxAccumulatedBytes = 64 * 1024

    private let deadlineUptimeNanos: UInt64
    private let outcome: EventLoopPromise<ProbeOutcome>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)
    private var timeoutTask: Scheduled<Void>?

    init(deadlineUptimeNanos: UInt64, outcome: EventLoopPromise<ProbeOutcome>) {
        self.deadlineUptimeNanos = deadlineUptimeNanos
        self.outcome = outcome
    }

    func channelActive(context: ChannelHandlerContext) {
        nonisolated(unsafe) let ctx = context
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let remainingNanos: Int64
        if deadlineUptimeNanos > nowNanos {
            let delta = deadlineUptimeNanos - nowNanos
            remainingNanos = Int64(min(delta, UInt64(Int64.max)))
        } else {
            remainingNanos = 0
        }
        timeoutTask = context.eventLoop.scheduleTask(in: .nanoseconds(remainingNanos)) { [weak self] in
            self?.complete(.silent, context: ctx)
        }

        let request =
            "CONNECT example.com:443 HTTP/1.1\r\n" +
            "Host: example.com:443\r\n" +
            "Proxy-Connection: Keep-Alive\r\n" +
            "\r\n"
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)

        if accumulated.readableBytes > Self.maxAccumulatedBytes {
            complete(.unreachable, context: context)
            return
        }

        guard let response = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ), response.contains("\r\n\r\n") else {
            return
        }

        let statusCode = response
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) }
        complete(statusCode == 200 || statusCode == 407 ? .answered : .unreachable, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.unreachable, context: context, close: false)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.unreachable, context: context)
    }

    private func complete(_ outcome: ProbeOutcome, context: ChannelHandlerContext, close: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        self.outcome.succeed(outcome)
        if close {
            context.close(promise: nil)
        }
    }
}
