// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOEmbedded
import XCTest

extension XCTestCase {
    func closeAtTearDown(_ channel: Channel) {
        addTeardownBlock {
            do {
                try await channel.close().get()
            } catch ChannelError.alreadyClosed {
            }
        }
    }

    /// Async fixtures must also finish when an earlier operation throws.
    func finishAtTearDown(
        _ channel: NIOAsyncTestingChannel, file: StaticString = #filePath, line: UInt = #line
    ) {
        addTeardownBlock {
            let leftOvers = try await channel.finish(acceptAlreadyClosed: true)
            XCTAssertTrue(leftOvers.isClean, file: file, line: line)
        }
    }
}
