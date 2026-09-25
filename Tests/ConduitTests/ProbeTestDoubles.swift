// SPDX-License-Identifier: Apache-2.0
// Test doubles for `DirectConnectDetector` probes: a scripted resolver and
// a loopback listener that counts the connections a probe makes.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import ProxyKernel

/// A scripted resolver for `DirectConnectDetector` probes.
final class ProbeResolver: @unchecked Sendable {
    enum Mode {
        case noAddresses
        case addresses([SocketAddress])
        /// Lookups stay pending until `release()`.
        case held
    }

    private let mode: Mode
    private let state = NIOLockedValueBox<(lookups: Int, held: [EventLoopPromise<[SocketAddress]>])>((0, []))

    init(_ mode: Mode) { self.mode = mode }

    var lookups: Int { state.withLockedValue { $0.lookups } }

    func resolve(host _: String, port _: Int, on loop: EventLoop) -> EventLoopFuture<[SocketAddress]> {
        switch mode {
        case .noAddresses:
            state.withLockedValue { $0.lookups += 1 }
            return loop.makeSucceededFuture([])
        case .addresses(let addresses):
            state.withLockedValue { $0.lookups += 1 }
            return loop.makeSucceededFuture(addresses)
        case .held:
            let promise = loop.makePromise(of: [SocketAddress].self)
            state.withLockedValue {
                $0.lookups += 1
                $0.held.append(promise)
            }
            return promise.futureResult
        }
    }

    /// Answer every held lookup with `addresses` (none by default).
    func release(with addresses: [SocketAddress] = []) {
        let held = state.withLockedValue { state -> [EventLoopPromise<[SocketAddress]>] in
            defer { state.held.removeAll() }
            return state.held
        }
        for promise in held { promise.succeed(addresses) }
    }

    /// Lookups waiting for `release`.
    var heldCount: Int { state.withLockedValue { $0.held.count } }
}

/// A loopback listener that counts the connections it accepts.
final class CountingListener: @unchecked Sendable {
    private let channel: Channel
    private let count: NIOLockedValueBox<Int>

    private init(channel: Channel, count: NIOLockedValueBox<Int>) {
        self.channel = channel
        self.count = count
    }

    static func start() async throws -> CountingListener {
        let count = NIOLockedValueBox(0)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                count.withLockedValue { $0 += 1 }
                return child.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return CountingListener(channel: channel, count: count)
    }

    var port: Int { channel.localAddress?.port ?? 0 }
    var accepted: Int { count.withLockedValue { $0 } }
    func stop() { channel.close(promise: nil) }
}
