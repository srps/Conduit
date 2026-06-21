// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class UpstreamTestEventTests: XCTestCase {

    @MainActor
    func testEmptyUpstreamTestNameEmitsInvalidEvent() async {
        let orchestrator = ProxyOrchestrator(config: GenericDefaults.shared.makeConfig(), logger: DiscardingLogSink())

        let result = await orchestrator.testUpstream(named: "   ")

        XCTAssertNil(result)
        XCTAssertTrue(orchestrator.eventLog.events.contains {
            $0.kind == .health &&
            $0.event == "upstream.test.invalid" &&
            $0.detail == "reason=empty_name"
        })
    }

    @MainActor
    func testMissingUpstreamTestTargetEmitsNotFoundEvent() async {
        let orchestrator = ProxyOrchestrator(config: GenericDefaults.shared.makeConfig(), logger: DiscardingLogSink())

        let result = await orchestrator.testUpstream(named: "missing")

        XCTAssertNil(result)
        XCTAssertTrue(orchestrator.eventLog.events.contains {
            $0.kind == .health &&
            $0.event == "upstream.test.not_found" &&
            $0.detail == "name=missing"
        })
    }
}
