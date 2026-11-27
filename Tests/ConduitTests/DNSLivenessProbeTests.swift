// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class DNSLivenessProbeTests: XCTestCase {
    func testTheLivenessProbeIsAnsweredWhileEveryUpstreamIsSilent() async throws {
        let doh = try await AnsweringDoHProvider.start(group: MultiThreadedEventLoopGroup.singleton, ip: "198.51.100.7", silent: true)
        addTeardownBlock { await doh.channel.closeForTest() }
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])]
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerEndpoint = { _ in ("127.0.0.1", 9) }
        let forwarder = LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton, logger: RecordingLogSink(minLevel: .debug),
            configProvider: { frozen }, tuning: tuning
        )
        try await forwarder.start(host: "127.0.0.1", port: 0)
        addTeardownBlock { await forwarder.stop() }
        let port = try XCTUnwrap(forwarder.listeningPort)

        let liveness = await Task.detached { SystemDNSManager.dnsLiveness(onPort: port, timeoutMilliseconds: 500) }.value

        XCTAssertEqual(liveness, .live)
        XCTAssertEqual(doh.requestCount(), 0, "the probe never reached an upstream")
    }
}
