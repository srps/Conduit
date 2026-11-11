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
                (DoHSessionFactory.providerAuthority(host: testCase.host, port: testCase.port, config: config) != nil),
                testCase.admitted, "\(testCase.host):\(testCase.port)"
            )
        }

        XCTAssertTrue(DoHSessionFactory.upstreamRouteCarries(provider: "https://192.0.2.10/dns-query"))
        XCTAssertFalse(DoHSessionFactory.upstreamRouteCarries(provider: "https://127.0.0.1:5053/dns-query"))
        XCTAssertFalse(DoHSessionFactory.upstreamRouteCarries(provider: "http://[::1]/dns-query"))

        config.dohProviders = []
        XCTAssertEqual(DoHSessionFactory.providerAuthority(host: "1.1.1.1", port: 443, config: config), "1.1.1.1:443", "an empty list means the shipped defaults")
        XCTAssertNil(DoHSessionFactory.providerAuthority(host: "192.0.2.10", port: 443, config: config))
    }

    /// A provider URL and the SOCKS request for it are written by different
    /// hands. Each legitimate spelling of one host is admitted, and nothing else.
    func testAProviderIsAdmittedInEverySpellingOfItsHost() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = [
            "https://doh.corp.example./dns-query",
            "https://dns.b\u{FC}cher.corp.example/dns-query",
            "https://192.0.2.10/dns-query",
            "https://[::ffff:192.0.2.20]/dns-query",
            "https://[2001:DB8::53]/dns-query",
        ]
        let cases: [(host: String, admitted: Bool)] = [
            // The DNS root dot, on either side or both.
            ("doh.corp.example", true),
            ("doh.corp.example.", true),
            ("DOH.corp.example.", true),
            ("doh.corp.example..", false),
            // CFNetwork sends the punycode form of a Unicode name. A request is ASCII.
            ("dns.xn--bcher-kva.corp.example", true),
            ("dns.b\u{FC}cher.corp.example", false),
            ("DNS.XN--BCHER-KVA.corp.example.", true),
            ("dns.bucher.corp.example", false),
            // An IPv4 address and its IPv4-mapped IPv6 form are one address.
            ("192.0.2.10", true),
            ("::ffff:192.0.2.10", true),
            ("[::ffff:192.0.2.10]", true),
            ("0:0:0:0:0:ffff:c000:20a", true),
            ("192.0.2.20", true),
            ("::ffff:192.0.2.20", true),
            ("::ffff:192.0.2.30", false),
            // IPv6, compressed or as the listener prints it off the wire.
            ("2001:db8::53", true),
            ("2001:db8:0:0:0:0:0:53", true),
            ("[2001:DB8::53]", true),
            ("2001:db8::54", false),
            // A name is matched exactly: no suffix, no prefix, no address behind it.
            ("evil.doh.corp.example", false),
            ("doh.corp.example.evil.example", false),
            ("", false),
            (".", false),
            // An address is dotted-quad, as `inet_pton` reads it, with nothing after it. Each of these is 192.0.2.10 to `inet_aton`.
            ("192.0.2.10\r\nX-Injected: 1", false),
            ("192.0.2.10\0", false),
            ("192.0.2.10 GET", false),
            ("192.0.2.10\t", false),
            ("192.0.522", false),
            ("192.522", false),
            ("3221225994", false),
            ("0xc000020a", false),
            ("0300.0.2.10", false),
            ("192.0.02.10", false),
            ("192.0.2.010", false),
            ("::ffff:192.0.2.10\0", false),
            ("2001:db8::53\0", false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                (DoHSessionFactory.providerAuthority(host: testCase.host, port: 443, config: config) != nil),
                testCase.admitted, "\"\(testCase.host)\""
            )
        }
    }

    /// The route dials the provider the config names, however the request
    /// spelled it: the request's bytes never reach the CONNECT.
    func testTheRouteDialsTheConfiguredProvidersOwnAuthority() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = [
            "https://doh.corp.example./dns-query",
            "https://dns.b\u{FC}cher.corp.example:8443/dns-query",
            "http://[::ffff:192.0.2.20]/dns-query",
            "https://[2001:DB8::53]/dns-query",
        ]
        let cases: [(host: String, port: Int, dialled: String)] = [
            ("DOH.Corp.Example", 443, "doh.corp.example.:443"),
            ("doh.corp.example.", 443, "doh.corp.example.:443"),
            ("DNS.XN--BCHER-KVA.corp.example.", 8443, "dns.xn--bcher-kva.corp.example:8443"),
            ("0:0:0:0:0:ffff:c000:214", 80, "192.0.2.20:80"),
            ("192.0.2.20", 80, "192.0.2.20:80"),
            ("2001:db8:0:0:0:0:0:53", 443, "[2001:db8::53]:443"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DoHSessionFactory.providerAuthority(host: testCase.host, port: testCase.port, config: config), testCase.dialled, testCase.host
            )
        }
    }

    /// The route is not raced for a provider on this machine, however the
    /// address is written, and is raced for a name that only looks like one.
    func testAProviderOnThisMachineIsRecognisedByItsAddressNotItsSpelling() {
        let local = [
            "https://localhost/dns-query", "https://localhost./dns-query", "https://LOCALHOST:5053/dns-query",
            "https://doh.localhost/dns-query",
            "https://127.0.0.1/dns-query", "https://127.8.9.10/dns-query", "https://127.1/dns-query", "https://2130706433/dns-query",
            "https://0.0.0.0/dns-query",
            "https://[::1]/dns-query", "https://[0:0:0:0:0:0:0:1]/dns-query", "https://[::]/dns-query",
            "https://[::ffff:127.0.0.1]/dns-query", "https://[::ffff:7f00:1]/dns-query", "https://[::127.0.0.1]/dns-query",
        ]
        for provider in local {
            XCTAssertFalse(DoHSessionFactory.upstreamRouteCarries(provider: provider), provider)
        }
        let remote = [
            "https://127.example/dns-query", "https://127.corp.example/dns-query", "https://localhost.corp.example/dns-query",
            "https://notlocalhost/dns-query", "https://192.0.2.127/dns-query", "https://[2001:db8::1]/dns-query",
            "https://[::ffff:192.0.2.10]/dns-query",
        ]
        for provider in remote {
            XCTAssertTrue(DoHSessionFactory.upstreamRouteCarries(provider: provider), provider)
        }

        var config = ProxyConfig.testFixture()
        config.dohProviders = local
        for host in ["localhost", "localhost.", "127.0.0.1", "127.1", "0.0.0.0", "::1", "::ffff:127.0.0.1", "::"] {
            XCTAssertNil(DoHSessionFactory.providerAuthority(host: host, port: 443, config: config), host)
        }
    }
}
