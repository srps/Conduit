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
}
