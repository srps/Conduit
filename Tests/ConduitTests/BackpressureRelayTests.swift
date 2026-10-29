// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

/// Tests verifying the backpressure pattern used by tunnel relay handlers.
/// Since the relay handlers are file-private, we test the pattern
/// through channel writability behavior on EmbeddedChannels.
final class BackpressureRelayTests: XCTestCase {

    func testEmbeddedChannelWritabilityDefaultsToTrue() {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }
        XCTAssertTrue(channel.isWritable, "New channels should be writable by default")
    }

    func testAutoReadOptionToggle() throws {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        // Set autoRead to false
        try channel.setOption(ChannelOptions.autoRead, value: false).wait()

        // Set autoRead back to true
        try channel.setOption(ChannelOptions.autoRead, value: true).wait()
    }

    func testWritabilityChangedFires() throws {
        let handler = WritabilityTracker()
        let channel = EmbeddedChannel(handler: handler)
        defer { XCTAssertNoThrow(try channel.finish()) }

        // Manually fire writability changed
        channel.pipeline.fireChannelWritabilityChanged()

        XCTAssertGreaterThanOrEqual(handler.writabilityChangedCount, 1)
    }
}

private final class WritabilityTracker: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    var writabilityChangedCount = 0

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        writabilityChangedCount += 1
        context.fireChannelWritabilityChanged()
    }
}
