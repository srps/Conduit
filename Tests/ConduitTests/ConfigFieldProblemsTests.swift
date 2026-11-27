// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class ConfigFieldProblemsTests: XCTestCase {
    func testIndexesBoundaryErrorsByField() {
        var config = ProxyConfig()
        config.localPort = 70_000
        config.maxConnections = 0
        config.noProxyHosts = ["ok.example", "bad host with spaces"]

        let problems = ConfigFieldProblems(config: config)

        XCTAssertNotNil(problems.message(for: "proxy.port"))
        XCTAssertTrue(problems.isInvalid("proxy.maxConnections"))
        XCTAssertNil(problems.message(for: "routing.noProxyHosts[0]"))
        XCTAssertNotNil(problems.message(for: "routing.noProxyHosts[1]"))
        XCTAssertNil(problems.message(for: "proxy.socksPort"))
    }

    func testAggregateBypassProblemHasAnEditorMessage() {
        var config = ProxyConfig()
        config.noProxyHosts = Array(repeating: "short.example", count: 257)
        XCTAssertNotNil(ConfigFieldProblems(config: config).message(for: "routing.noProxyHosts"))
    }

    func testConflictsAreListedSeparatelyAndFilterable() {
        var config = ProxyConfig()
        config.socksEnabled = true
        config.socksPort = config.localPort

        let problems = ConfigFieldProblems(config: config)

        XCTAssertFalse(problems.conflicts.isEmpty)
        XCTAssertFalse(problems.conflicts(mentioning: ["SOCKS port"]).isEmpty)
        XCTAssertTrue(problems.conflicts(mentioning: ["tunnel"]).isEmpty)
        XCTAssertNil(problems.message(for: "proxy.socksPort"), "a conflict is not a per-field problem")
    }

    /// The tunnel editor shows a proxied tunnel's remote host problem on that row, without holding back the proxy.
    func testAProxiedTunnelRemoteHostThatIsNotAHostIsAFieldProblem() {
        var config = ProxyConfig()
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 15432, remoteHost: "bücher.corp.example", remotePort: 5432, proxied: true, label: "db"),
            TunnelDefinition(localPort: 15433, remoteHost: "bücher.corp.example", remotePort: 5432, proxied: false, label: "direct"),
        ]

        let problems = ConfigFieldProblems(config: config)

        let message = problems.message(for: "tunnels.definitions[0](db).remoteHost")
        XCTAssertTrue(message?.contains("the remote host is not a host name or IP address") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("A-label form") == true, message ?? "nil")
        XCTAssertNil(problems.message(for: "tunnels.definitions[1](direct).remoteHost"), "a direct tunnel never writes a CONNECT")
        XCTAssertEqual(config.startBlockingProblems.map(\.check), [String]())


        for host in ["db.corp.example", "db.corp.example.", "10.0.0.5", "fd00::5", "_svc.corp.example"] {
            config.tunnels.definitions[0].remoteHost = host
            XCTAssertNil(ConfigFieldProblems(config: config).message(for: "tunnels.definitions[0](db).remoteHost"), host)
        }
    }

    /// The message reaches log lines and the save banner, so it names the field and a reason and never the host: not
    /// through a blank label, which spells the host, nor through the domain-name reason, which can quote a label.
    func testAProxiedTunnelRemoteHostProblemNeverEchoesTheHost() throws {
        let sentinel = "zq7sentinel"
        let rows = [
            ("", "db.\(sentinel).example\r\nX-Injected: 1"),
            ("", "db \(sentinel).example"),
            ("db", "\(sentinel) db.example"),
            ("db", "bücher-\(sentinel).example"),
            ("db", "-\(sentinel).example"),
            ("db", "\(sentinel)\(String(repeating: "a", count: 60)).example"),
        ]
        for (label, host) in rows {
            var config = ProxyConfig()
            let tunnel = TunnelDefinition(localPort: 15432, remoteHost: host, remotePort: 5432, proxied: true, label: label)
            config.tunnels.definitions = [tunnel]
            let field = "tunnels.definitions[0](\(tunnel.effectiveLabel)).remoteHost"
            let message = try XCTUnwrap(ConfigFieldProblems(config: config).message(for: field), host.debugDescription)
            let bytes = Data(message.utf8)
            XCTAssertNil(bytes.range(of: Data(sentinel.utf8)), "\(host.debugDescription): \(message.debugDescription)")
            XCTAssertFalse(bytes.contains { $0 < 0x20 || $0 >= 0x7F }, "\(host.debugDescription): \(message.debugDescription)")
            XCTAssertTrue(message.hasPrefix("tunnels.definitions[0].remoteHost: "), message)
        }
    }

    func testCleanConfigHasNoProblems() {
        XCTAssertTrue(ConfigFieldProblems(config: ProxyConfig()).isEmpty)
    }

    // The two Advanced fields that had no boundary rule, so their Settings
    // rows showed nothing when wrong.

    func testCircuitBreakerWindowRefusesNegativeAndAcceptsZero() {
        var config = ProxyConfig()
        config.circuitBreakerWindowSeconds = -1
        XCTAssertNotNil(ConfigFieldProblems(config: config).message(for: "health.circuitBreakerWindowSeconds"))

        config.circuitBreakerWindowSeconds = 0
        XCTAssertNil(ConfigFieldProblems(config: config).message(for: "health.circuitBreakerWindowSeconds"),
                     "0 is the documented 'no window' value, not an error")
    }

    func testInboundWarnThresholdNeedsAtLeastOne() {
        var config = ProxyConfig()
        config.inboundConnectionWarnThreshold = 0
        XCTAssertNotNil(ConfigFieldProblems(config: config).message(for: "proxy.inboundConnectionWarnThreshold"))
    }

    func testInboundWarnThresholdAtOrAboveMaxLimitIsAConflictTheAdvancedSectionShows() {
        var config = ProxyConfig()
        config.inboundConnectionWarnThreshold = config.inboundConnectionMaxLimit

        let problems = ConfigFieldProblems(config: config)

        XCTAssertFalse(problems.conflicts(mentioning: ["proxy.inboundConnection"]).isEmpty)
        XCTAssertNil(problems.message(for: "proxy.inboundConnectionWarnThreshold"),
                     "the threshold is a legal number on its own; only the pair conflicts")

        config.inboundConnectionWarnThreshold = config.inboundConnectionMaxLimit - 1
        XCTAssertTrue(ConfigFieldProblems(config: config).conflicts(mentioning: ["proxy.inboundConnection"]).isEmpty)
    }
}
