// SPDX-License-Identifier: Apache-2.0
import NIOCore
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

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
