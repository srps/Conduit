// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import HelperSupport

final class VPNDNSOverrideLegacyCheckTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private var directory: URL!
    private var file: VPNDNSOverrideLegacyFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-legacy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = VPNDNSOverrideLegacyFile(path: directory.appendingPathComponent("vpn-dns-override.json").path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: file.path))
    }

    private func checked() -> (VPNDNSOverrideLegacyCheck.Outcome, [VPNDNSOverrideLegacyCheck.Outcome]) {
        var reported: [VPNDNSOverrideLegacyCheck.Outcome] = []
        let outcome = VPNDNSOverrideLegacyCheck.check(file: file) { reported.append($0) }
        return (outcome, reported)
    }

    func testARecordIsReportedWithTheReconnectAndLeftInPlace() throws {
        try write(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53","198.51.100.53"]}"#)
        let (outcome, reported) = checked()
        XCTAssertEqual(outcome, .awaitingRecovery(service: service))
        XCTAssertEqual(reported, [outcome])
        XCTAssertTrue(outcome.logLine.contains("Reconnect the VPN"))
        XCTAssertFalse(outcome.logLine.contains("sudo"), "no manual step writes the VPN's key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testNoRecordIsQuiet() {
        XCTAssertEqual(VPNDNSOverrideLegacyCheck.check(file: file) { _ in XCTFail("nothing to report") }, .noRecord)
    }

    func testALinkOrAMalformedRecordIsReportedAndLeftInPlace() throws {
        let target = directory.appendingPathComponent("elsewhere.json")
        try Data(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53"]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        XCTAssertEqual(checked().0, .malformed("a link, not a file"), "a link is not followed")
        try FileManager.default.removeItem(atPath: file.path)

        try write("[]")
        let (outcome, reported) = checked()
        guard case .malformed = outcome else { return XCTFail("not a record") }
        XCTAssertEqual(reported, [outcome])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnUnreadableRecordIsReported() throws {
        try XCTSkipIf(getuid() == 0, "root reads a 0000 file")
        try write(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53"]}"#)
        chmod(file.path, 0)
        guard case .recordUnreadable = checked().0 else { return XCTFail("an unreadable file is not malformed") }
    }

    func testARecordOutOfShapeIsUndecodable() {
        for json in [#"{"serviceID":"a/b","originals":["192.0.2.53"]}"#, #"{"serviceID":"x","originals":["127.0.0.1"]}"#, "[]"] {
            guard case .malformed = VPNDNSOverrideLegacyFile.decode(Data(json.utf8)) else { return XCTFail(json) }
        }
    }
}
