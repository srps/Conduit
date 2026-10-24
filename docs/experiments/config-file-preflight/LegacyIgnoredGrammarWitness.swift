// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
final class ConfigLegacyIgnoredGrammarWitnessTests: XCTestCase {
    func testActualPersistenceDecoderIgnoredValueGrammar() throws {
        let original = try CanonicalJSON.encoder().encode(ProxyConfig.testFixture())
        XCTAssertEqual(original.last, UInt8(ascii: "}"))
        let base = original.dropLast()
        let cases: [(String, [UInt8])] = [
            ("lone_high", Array(#""\uD800""#.utf8)),
            ("bad_hex", Array(#""\uZZZZ""#.utf8)),
            ("bad_escape", Array(#""\x""#.utf8)),
            ("huge_number", Array("1e400".utf8)),
            ("bad_utf8", [0x22, 0x80, 0x22]),
            ("raw_control", [0x22, 0x01, 0x22])
        ]
        for (name, value) in cases {
            let bytes = Data(base) + Data(#","ignored":"#.utf8) + Data(value) + Data("}".utf8)
            let candidate = try ProxyConfigPersistence.decode(bytes, source: "synthetic-ignored-" + name)
            XCTAssertEqual(candidate.profileName, ProxyConfig.testFixture().profileName)
            print("LEGACY_IGNORED_WITNESS case=\(name) actual_persistence_accepted=true")
        }
    }
}
