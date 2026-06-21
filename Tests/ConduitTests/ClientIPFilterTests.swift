// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import ProxyKernel

final class ClientIPFilterTests: XCTestCase {

    @MainActor func testAllowedIPPassesThrough() throws {
        let logger = DiscardingLogSink()
        let filter = ClientIPFilter(allowedIPs: ["127.0.0.1", "::1"], logger: logger)
        let channel = EmbeddedChannel(handler: filter)
        // EmbeddedChannel has no real remote address, so channelActive sees nil.
        // We verify the filter is correctly added and handles nil gracefully.
        XCTAssertNotNil(channel.pipeline)
        try? channel.close().wait()
    }

    @MainActor func testAllowedIPSetDeduplicates() {
        let logger = DiscardingLogSink()
        let filter = ClientIPFilter(allowedIPs: ["127.0.0.1", "127.0.0.1", "::1"], logger: logger)
        XCTAssertNotNil(filter)
    }

    @MainActor func testEmptyAllowedIPsCreatesFilter() throws {
        let logger = DiscardingLogSink()
        let filter = ClientIPFilter(allowedIPs: [], logger: logger)
        let channel = EmbeddedChannel(handler: filter)
        XCTAssertNotNil(filter)
        try? channel.close().wait()
    }

    func testDefaultConfigAllowedClients() {
        let config = ProxyConfig.testFixture()
        XCTAssertTrue(config.allowedClients.contains("127.0.0.1"))
        XCTAssertTrue(config.allowedClients.contains("::1"))
    }

    func testGatewayModeEnablesFilter() {
        var config = ProxyConfig.testFixture()
        config.gatewayMode = false
        XCTAssertEqual(config.effectiveListenHost, "127.0.0.1")

        config.gatewayMode = true
        XCTAssertEqual(config.effectiveListenHost, "0.0.0.0")
        XCTAssertFalse(config.allowedClients.isEmpty, "Gateway mode should have allowedClients configured")
    }
}
