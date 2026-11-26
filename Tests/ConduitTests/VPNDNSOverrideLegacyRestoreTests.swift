// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import HelperSupport
@testable import PlatformMac

final class VPNDNSOverrideLegacyRestoreTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private let originals = ["192.0.2.53", "198.51.100.53"]

    private final class RecordFile: VPNDNSOverrideLegacyRecordFile {
        var stored: VPNDNSOverrideLegacyStoredRecord
        var deletes = 0
        var deleteFails = false

        init(_ stored: VPNDNSOverrideLegacyStoredRecord) {
            self.stored = stored
        }

        func load() -> VPNDNSOverrideLegacyStoredRecord { stored }

        func delete() throws {
            deletes += 1
            if deleteFails { throw VPNDNSOverrideLegacyFileError.system("unlink", EACCES) }
            stored = .none
        }
    }

    private final class RefusingStore: VPNDNSLegacyStore {
        let read: VPNDNSLegacyRead
        init(dns: [String: VPNDNSValue]) { read = .value(dns) }
        init(read: VPNDNSLegacyRead) { self.read = read }
        func legacyDNS(service: String) -> VPNDNSLegacyRead { read }
        func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool { false }
    }

    private var record: VPNDNSOverrideLegacyStoredRecord { .record(.init(serviceID: service, originals: originals)) }

    func testTheOriginalsGoBackOverTheOlderHelpersLoopbackAndTheRecordIsDeleted() {
        let store = FakeVPNDNSStore()
        store.connectFullTunnel(service, servers: ["127.0.0.1"], extra: ["DomainName": .string("corp.example")])
        let file = RecordFile(record)
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []

        let outcome = VPNDNSOverrideLegacyRestore.run(store: store, file: file) { reported.append($0) }

        XCTAssertEqual(outcome, .restored(service: service))
        XCTAssertEqual(reported, [.restored(service: service)])
        XCTAssertEqual(store.serverAddresses(service), originals)
        XCTAssertEqual(store.dns(service: service)?["DomainName"], .string("corp.example"), "the rest of the key is kept")
        XCTAssertEqual(store.vpnKeyWrites, [service])
        XCTAssertEqual(file.deletes, 1)
    }

    func testAKeyTheClientRewroteIsLeftAloneAndTheRecordIsDeleted() {
        let store = FakeVPNDNSStore()
        store.connectFullTunnel(service, servers: ["203.0.113.53"])
        let file = RecordFile(record)
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: file) { _ in }, .keyChanged(service: service))
        XCTAssertEqual(store.serverAddresses(service), ["203.0.113.53"])
        XCTAssertEqual(store.vpnKeyWrites, [])
        XCTAssertEqual(file.deletes, 1)
    }

    func testAGoneKeyIsNeverRecreated() {
        let store = FakeVPNDNSStore()
        let file = RecordFile(record)
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: file) { _ in }, .keyGone(service: service))
        XCTAssertNil(store.dns(service: service))
        XCTAssertEqual(store.vpnKeyWrites, [])
        XCTAssertEqual(file.deletes, 1)
    }

    func testAKeyThatCannotBeReadKeepsTheRecordAndIsNotWritten() {
        let file = RecordFile(record)
        let store = RefusingStore(read: .unreadable("copy: Failed!"))
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []
        let outcome = VPNDNSOverrideLegacyRestore.run(store: store, file: file) { reported.append($0) }
        XCTAssertEqual(outcome, .keyUnreadable(service: service, reason: "copy: Failed!"))
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(reported, [outcome])
        XCTAssertEqual(file.deletes, 0, "the originals stay for the next start")
    }

    func testARestoreTheStoreRefusesKeepsTheRecordForTheNextStart() {
        let file = RecordFile(record)
        let outcome = VPNDNSOverrideLegacyRestore.run(store: RefusingStore(dns: ["ServerAddresses": .strings(["127.0.0.1"])]), file: file) { _ in }
        XCTAssertEqual(outcome, .restoreFailed(service: service))
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(file.deletes, 0)
    }

    func testNoRecordDoesNothingAndAnUndecodableOneIsDeleted() {
        let store = FakeVPNDNSStore()
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: RecordFile(.none)) { _ in XCTFail("nothing to report") }, .noRecord)
        let broken = RecordFile(.undecodable("not a record"))
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: broken) { _ in }, .undecodable("not a record"))
        XCTAssertEqual(broken.deletes, 1)
        XCTAssertEqual(store.vpnKeyWrites, [])
    }

    func testADeleteThatFailsIsReported() {
        let store = FakeVPNDNSStore()
        let file = RecordFile(record)
        file.deleteFails = true
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []
        let outcome = VPNDNSOverrideLegacyRestore.run(store: store, file: file) { reported.append($0) }
        guard case .deleteFailed = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(reported.count, 2)
    }

    func testTheFileIsReadWithoutFollowingALinkAndDeletedWithItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-legacy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("vpn-dns-override.json").path
        let file = VPNDNSOverrideLegacyFile(path: path)
        XCTAssertEqual(file.load(), .none)

        try Data(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53","198.51.100.53"]}"#.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(file.load(), record)
        try file.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the empty directory goes too")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("elsewhere.json")
        try Data(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53"]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        guard case .undecodable = file.load() else { return XCTFail("a link is not followed") }
        try file.delete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "a directory with other files stays")
    }

    func testARecordOutOfShapeIsUndecodable() {
        for json in [#"{"serviceID":"a/b","originals":["192.0.2.53"]}"#, #"{"serviceID":"x","originals":["127.0.0.1"]}"#, "[]"] {
            guard case .undecodable = VPNDNSOverrideLegacyFile.decode(Data(json.utf8)) else { return XCTFail(json) }
        }
    }
}
