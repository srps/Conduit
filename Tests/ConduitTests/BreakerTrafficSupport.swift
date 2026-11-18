// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// A loopback port this test owned and released: bound on port 0, then closed, so a dial to it is refused by a port no
/// other service was using when it was chosen, not by a fixed port such as 9 that a local service may hold (#318).
func releasedLoopbackPort() async throws -> Int {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let port = try XCTUnwrap(channel.localAddress?.port)
    try await channel.close().get()
    return port
}

extension ConnectionPool {
    /// Fails `count` CONNECT tunnels forced through `proxy`, as traffic does: each must fail at the upstream, by a
    /// refused dial or a refusing answer, so each counts against its breaker.
    func failTunnels(
        through proxy: UpstreamProxy, count: Int, target: String = "trip.test:443",
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let coordinator = CONNECTCoordinator(
            pool: self,
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(
                    username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)
                ))
            },
            logger: DiscardingLogSink()
        )
        for _ in 0..<count {
            do {
                let established = try await coordinator.connectUpstreamTunnel(target: target, proxyChain: [proxy]).get()
                established.channel.close(mode: .all, promise: nil)
                XCTFail("\(proxy.endpoint) must fail the tunnel to \(target)", file: file, line: line)
            } catch {
                XCTAssertFalse(ConnectionPoolError.isLocalNonUpstreamFailure(error), "\(error)", file: file, line: line)
            }
        }
    }
}
