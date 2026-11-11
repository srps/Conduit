// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class DoHSessionFactoryTests: XCTestCase {

    private func localProxyPorts(port configured: Int, bound: Int?) -> [Int] {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = configured
        config.upstreams = []
        return DoHSessionFactory.routes(for: config, localProxyPort: bound, upstreamRoutePort: nil).compactMap {
            if case .clientListener(_, let port) = $0 { return port }
            return nil
        }
    }

    func testRoutesTargetTheBoundProxyPortNotTheConfiguredOne() {
        XCTAssertEqual(localProxyPorts(port: 0, bound: 51_234), [51_234], "port 0 bound to a port routes to that port")
        XCTAssertEqual(localProxyPorts(port: 0, bound: nil), [], "port 0 with no listener has no local route")
        XCTAssertEqual(localProxyPorts(port: 3128, bound: nil), [3128], "a fixed port with no listener keeps its configured route")
        XCTAssertEqual(localProxyPorts(port: 3128, bound: 3128), [3128])
    }

    /// No route names an upstream proxy to `URLSession`: the upstream is
    /// reached only behind Conduit's own listeners, which do the authenticating.
    func testRoutesAreDirectTheListenerAndTheUpstreamRouteNeverTheUpstreamItself() {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        XCTAssertFalse(config.enabledUpstreams.isEmpty)

        XCTAssertEqual(
            DoHSessionFactory.routes(for: config, localProxyPort: 3128, upstreamRoutePort: 50_001),
            [.direct, .clientListener(host: "127.0.0.1", port: 3128), .upstream(port: 50_001)]
        )
        XCTAssertEqual(
            DoHSessionFactory.routes(for: config, localProxyPort: 3128, upstreamRoutePort: nil),
            [.direct, .clientListener(host: "127.0.0.1", port: 3128)],
            "no bound upstream-route listener, no upstream route"
        )
    }

    func testTheUpstreamRouteIsAbsentWhenNoUpstreamIsEnabled() {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        config.upstreams = config.upstreams.map { var upstream = $0; upstream.enabled = false; return upstream }

        XCTAssertEqual(
            DoHSessionFactory.routes(for: config, localProxyPort: 3128, upstreamRoutePort: 50_001),
            [.direct, .clientListener(host: "127.0.0.1", port: 3128)]
        )
    }

    func testTheUpstreamRouteSessionIsALoopbackSOCKSProxy() {
        let proxy = DoHSessionFactory.socksProxyDictionary(port: 50_001)
        XCTAssertEqual(proxy[kCFNetworkProxiesSOCKSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxy[kCFNetworkProxiesSOCKSPort as String] as? Int, 50_001)
        XCTAssertEqual(proxy[kCFNetworkProxiesSOCKSEnable as String] as? Bool, true)
        XCTAssertNil(proxy[kCFNetworkProxiesHTTPProxy as String], "an HTTP proxy could answer 407")
    }

    func testOnlyAConfiguredProvidersOwnHostAndPortIsAProviderEndpoint() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = [
            "https://192.0.2.10/dns-query",
            "https://doh.corp.example:8443/dns-query",
            "http://192.0.2.20/dns-query",
            "https://[2001:db8::53]/dns-query",
            "https://127.0.0.1:5053/dns-query",
            "https://localhost/dns-query",
        ]
        let cases: [(host: String, port: Int, admitted: Bool)] = [
            ("192.0.2.10", 443, true),
            ("192.0.2.10", 80, false),
            ("192.0.2.10", 22, false),
            ("doh.corp.example", 8443, true),
            ("DoH.Corp.Example", 8443, true),
            ("doh.corp.example", 443, false),
            ("192.0.2.20", 80, true),
            ("192.0.2.20", 443, false),
            // As the SOCKS listener spells an IPv6 address read off the wire.
            ("2001:db8:0:0:0:0:0:53", 443, true),
            ("2001:db8::53", 443, true),
            ("2001:db8::54", 443, false),
            ("intranet.corp.example", 443, false),
            // A provider on this machine is not reached through an upstream.
            ("127.0.0.1", 5053, false),
            ("localhost", 443, false),
            ("198.51.100.7", 443, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DoHSessionFactory.isProviderEndpoint(host: testCase.host, port: testCase.port, config: config),
                testCase.admitted, "\(testCase.host):\(testCase.port)"
            )
        }

        XCTAssertTrue(DoHSessionFactory.upstreamRouteCarries(provider: "https://192.0.2.10/dns-query"))
        XCTAssertFalse(DoHSessionFactory.upstreamRouteCarries(provider: "https://127.0.0.1:5053/dns-query"))
        XCTAssertFalse(DoHSessionFactory.upstreamRouteCarries(provider: "http://[::1]/dns-query"))

        config.dohProviders = []
        XCTAssertTrue(DoHSessionFactory.isProviderEndpoint(host: "1.1.1.1", port: 443, config: config), "an empty list means the shipped defaults")
        XCTAssertFalse(DoHSessionFactory.isProviderEndpoint(host: "192.0.2.10", port: 443, config: config))
    }
}
