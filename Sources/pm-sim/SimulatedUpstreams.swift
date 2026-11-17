// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// The upstream probe the actual-host scenarios inject (decision 0033). It answers as a refused connection would, so a
/// routing verdict needs no dial; the health loop still dials the scenario's `ClosingUpstream`.
enum SimulatedUpstreams {
    @Sendable static func unreachable(_ upstreams: [UpstreamProxy]) async -> UpstreamProbeSummary {
        UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: false) })
    }
}

/// The upstream an actual-host scenario owns: a loopback listener on an ephemeral port that closes every connection it
/// accepts, so each exchange fails the way an unreachable upstream does. It counts what it accepted, which is the
/// evidence that the host's dials reached it and nothing else. `open()` registers its close with the scenario's
/// cleanup as it binds, so every way out of the scenario closes it, a throw included, unless a pinned host keeps it.
final class ClosingUpstream: @unchecked Sendable {
    let port: Int
    private let channel: Channel
    private let acceptedBox: NIOLockedValueBox<Int>
    private let keptOpen = NIOLockedValueBox(false)

    var accepted: Int { acceptedBox.withLockedValue { $0 } }
    var proxy: UpstreamProxy { UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: port, priority: 0) }

    @RuntimeActor
    static func open() async throws -> ClosingUpstream {
        let upstream = try await ClosingUpstream()
        ScenarioCleanup.register { await upstream.closeUnlessKept() }
        return upstream
    }

    private init() async throws {
        let accepted = NIOLockedValueBox(0)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                accepted.withLockedValue { $0 += 1 }
                return child.close()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            try await channel.close().get()
            throw ScenarioExecutionError(message: "the closing upstream has no bound port")
        }
        self.port = port
        self.channel = channel
        acceptedBox = accepted
    }

    /// Leaves the listener open for the rest of the process, for a host whose shutdown was not confirmed: whatever
    /// that host still dials reaches this listener and nothing else.
    func keepOpenForPinnedHost() {
        keptOpen.withLockedValue { $0 = true }
    }

    private func closeUnlessKept() async {
        guard !keptOpen.withLockedValue({ $0 }) else { return }
        do {
            try await channel.close().get()
        } catch {
            FileHandle.standardError.write(Data("pm-sim: the owned upstream on port \(port) did not close: \(error)\n".utf8))
        }
    }
}
