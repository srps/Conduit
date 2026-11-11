// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class DoHSessionFactoryTests: XCTestCase {

    private func localProxyPorts(port configured: Int, bound: Int?) -> [Int] {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = configured
        config.upstreams = []
        return DoHSessionFactory.routes(for: config, localProxyPort: bound).compactMap { $0.proxy?.port }
    }

    func testRoutesTargetTheBoundProxyPortNotTheConfiguredOne() {
        XCTAssertEqual(localProxyPorts(port: 0, bound: 51_234), [51_234], "port 0 bound to a port routes to that port")
        XCTAssertEqual(localProxyPorts(port: 0, bound: nil), [], "port 0 with no listener has no local route")
        XCTAssertEqual(localProxyPorts(port: 3128, bound: nil), [3128], "a fixed port with no listener keeps its configured route")
        XCTAssertEqual(localProxyPorts(port: 3128, bound: 3128), [3128])
    }

    /// Decision 0045: a DoH lookup sent straight at the upstream meets its
    /// 407, which macOS answered with a credential dialog for Conduit.
    func testRoutesAreDirectAndTheListenerNeverTheUpstream() {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        XCTAssertFalse(config.enabledUpstreams.isEmpty)

        let routes = DoHSessionFactory.routes(for: config, localProxyPort: 3128)

        XCTAssertEqual(routes.map { $0.proxy.map { "\($0.host):\($0.port)" } ?? "direct" }, ["direct", "127.0.0.1:3128"])
    }
}
