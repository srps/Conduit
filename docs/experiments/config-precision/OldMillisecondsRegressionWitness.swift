// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
final class ExactMillisecondsRegressionWitnessTests: XCTestCase {
    func testWholeMillisecondTimeoutSurvivesSaveAndLoad() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-old-ms-witness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { XCTFail("owned scratch cleanup failed") }
        }
        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 1001
        let url = scratch.appendingPathComponent("config.json")
        try ProxyConfigPersistence.save(config, to: url)
        let loaded = try ProxyConfigPersistence.load(from: url)
        XCTAssertEqual(loaded.health.connectionCheckTimeout, 1.001)
        XCTAssertEqual(loaded.connectionCheckTimeoutMS, 1001)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((object["connectionCheckTimeoutMS"] as? NSNumber)?.intValue, 1001)
    }
}
