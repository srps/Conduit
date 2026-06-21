// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

package struct ProbeResult: Identifiable {
    package     let id: UUID
    package     let proxy: UpstreamProxy
    package     let latencyMS: Int
    package     let reachable: Bool

    package init(proxy: UpstreamProxy, latencyMS: Int, reachable: Bool) {
        self.id = proxy.id
        self.proxy = proxy
        self.latencyMS = latencyMS
        self.reachable = reachable
    }
}

package struct UpstreamProbeSummary {
    package let results: [ProbeResult]

    package var hasReachableUpstream: Bool {
        results.contains { $0.reachable }
    }

    package var bestReachableUpstream: UpstreamProxy? {
        results.first(where: { $0.reachable })?.proxy
    }
}

package final class UpstreamProber: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let timeoutSeconds: TimeInterval

    package init(group: EventLoopGroup, logger: any LogSink, timeoutSeconds: TimeInterval = 3) {
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
        // Both the caller's catch path and the handler's lifecycle callbacks
        // can race to resolve the probe outcome; funnel both through a single
        // idempotent completion so we never double-succeed the underlying
        // promise (which is a NIO fatal). See `ProbeCompletion`.
        let completion = ProbeCompletion(promise: eventLoop.makePromise(of: Bool.self))
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.milliseconds(Int64(timeoutSeconds * 1_000)))
                .channelInitializer { channel in
                    channel.pipeline.addHandler(
                        UpstreamProxyProbeHandler(
                            deadlineUptimeNanos: deadlineUptimeNanos,
                            completion: completion
                        )
                    )
                }
                .connect(host: proxy.host, port: proxy.port)
                .get()
        } catch {
            completion.complete(false)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return ProbeResult(proxy: proxy, latencyMS: elapsed, reachable: false)
        }

        let reachable = (try? await completion.future.get()) ?? false
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        channel.close(mode: .all, promise: nil)
        return ProbeResult(proxy: proxy, latencyMS: elapsed, reachable: reachable)
    }
}

/// Idempotent one-shot wrapper around an `EventLoopPromise<Bool>` shared
/// between the probe's `async` caller and its NIO `ChannelHandler`.
///
/// NIO fatal-errors on double-success, and the catch path (connect failed) and
/// the handler's lifecycle callbacks (`channelInactive`, `errorCaught`, timer)
/// can both reach the promise on a failed connect. In practice NIO only fires
/// `channelInactive` after `channelActive`, so the race rarely materializes,
/// but relying on that lifecycle invariant is fragile. The lock-guarded
/// `completed` flag here removes the assumption: the first caller wins and
/// any subsequent `complete(_:)` calls are no-ops.
private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NIOLock()
    private var completed = false
    private let promise: EventLoopPromise<Bool>

    init(promise: EventLoopPromise<Bool>) {
        self.promise = promise
    }

    var future: EventLoopFuture<Bool> { promise.futureResult }

    func complete(_ reachable: Bool) {
        let shouldSucceed: Bool = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldSucceed {
            promise.succeed(reachable)
        }
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
    private let completion: ProbeCompletion
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)
    private var timeoutTask: Scheduled<Void>?

    init(deadlineUptimeNanos: UInt64, completion: ProbeCompletion) {
        self.deadlineUptimeNanos = deadlineUptimeNanos
        self.completion = completion
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
            self?.complete(false, context: ctx)
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
            complete(false, context: context)
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
        complete(statusCode == 200 || statusCode == 407, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(false, context: context, close: false)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(false, context: context)
    }

    private func complete(_ reachable: Bool, context: ChannelHandlerContext, close: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        completion.complete(reachable)
        if close {
            context.close(promise: nil)
        }
    }
}
