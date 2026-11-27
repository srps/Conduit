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
        var setAsides = 0
        var deleteFails = false
        var loads = 0

        init(_ stored: VPNDNSOverrideLegacyStoredRecord) {
            self.stored = stored
        }

        func load() -> VPNDNSOverrideLegacyStoredRecord {
            loads += 1
            return stored
        }

        func setAside() throws {
            setAsides += 1
            stored = .none
        }

        func delete() throws {
            deletes += 1
            if deleteFails { throw VPNDNSOverrideLegacyFileError.system("unlink", EACCES) }
            stored = .none
        }
    }

    private final class RefusingStore: VPNDNSLegacyStore {
        var read: VPNDNSRead
        init(dns: [String: VPNDNSValue]) { read = .value(dns) }
        init(read: VPNDNSRead) { self.read = read }
        func legacyDNS(service: String) -> VPNDNSRead { read }
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
        XCTAssertEqual(store.tunnel(service)?.dns?["DomainName"], .string("corp.example"), "the rest of the key is kept")
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
        XCTAssertEqual(store.dns(service: service), .absent)
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

    func testARestoreTheStoreRefusesKeepsTheRecordForAnotherRecovery() {
        let file = RecordFile(record)
        let outcome = VPNDNSOverrideLegacyRestore.run(store: RefusingStore(dns: ["ServerAddresses": .strings(["127.0.0.1"])]), file: file) { _ in }
        XCTAssertEqual(outcome, .restoreFailed(service: service))
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(file.deletes, 0)
    }

    func testNoRecordDoesNothingAndAMalformedOneIsSetAsideNotDeleted() {
        let store = FakeVPNDNSStore()
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: RecordFile(.none)) { _ in XCTFail("nothing to report") }, .noRecord)
        let broken = RecordFile(.malformed("not a record"))
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.run(store: store, file: broken) { _ in }, .malformedSetAside("not a record"))
        XCTAssertEqual(broken.setAsides, 1)
        XCTAssertEqual(broken.deletes, 0, "it may hold the only copy of the originals")
        XCTAssertEqual(store.vpnKeyWrites, [])
    }

    func testARecordThatCannotBeReadIsKeptAndNotSetAside() {
        let file = RecordFile(.unreadable("open: Permission denied"))
        let outcome = VPNDNSOverrideLegacyRestore.run(store: FakeVPNDNSStore(), file: file) { _ in }
        XCTAssertEqual(outcome, .recordUnreadable("open: Permission denied"))
        XCTAssertTrue(outcome.keepsRecord)
        XCTAssertEqual(file.deletes + file.setAsides, 0)
    }

    func testAtStartARecordIsReportedAndNothingIsWrittenOrDeleted() {
        let store = FakeVPNDNSStore()
        store.connectFullTunnel(service, servers: ["127.0.0.1"])
        let file = RecordFile(record)
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []
        let outcome = VPNDNSOverrideLegacyRestore.check(file: file) { reported.append($0) }
        XCTAssertEqual(outcome, .awaitingRecovery(service: service))
        XCTAssertEqual(reported, [outcome])
        XCTAssertTrue(outcome.keepsRecord)
        XCTAssertTrue(outcome.logLine.contains("sudo \(HelperConstants.binaryInstallPath) --restore-legacy-vpn-dns"))
        XCTAssertEqual(store.vpnKeyWrites, [], "the VPN's key is written only when a person asks")
        XCTAssertEqual(file.deletes + file.setAsides, 0)
        XCTAssertEqual(store.serverAddresses(service), ["127.0.0.1"])
    }

    func testAtStartNoRecordIsQuietAndAMalformedOneIsSetAside() {
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.check(file: RecordFile(.none)) { _ in XCTFail("nothing to report") }, .noRecord)
        let broken = RecordFile(.malformed("not a record"))
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.check(file: broken) { _ in }, .malformedSetAside("not a record"))
        XCTAssertEqual(broken.setAsides, 1)
        XCTAssertEqual(broken.deletes, 0)
        let unreadable = RecordFile(.unreadable("open: Permission denied"))
        XCTAssertEqual(VPNDNSOverrideLegacyRestore.check(file: unreadable) { _ in }, .recordUnreadable("open: Permission denied"))
        XCTAssertEqual(unreadable.deletes + unreadable.setAsides, 0)
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
        guard case .malformed = file.load() else { return XCTFail("a link is not followed") }
        try file.setAside()
        XCTAssertEqual(file.load(), .none)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path + ".malformed"), target.path, "the link itself moves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        try Data(#"{"serviceID":"com.cisco.anyconnect","originals":["192.0.2.53"]}"#.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0)
        if getuid() != 0 {
            guard case .unreadable = file.load() else { return XCTFail("an unreadable file is not malformed") }
        }
    }

    func testARecordOutOfShapeIsUndecodable() {
        for json in [#"{"serviceID":"a/b","originals":["192.0.2.53"]}"#, #"{"serviceID":"x","originals":["127.0.0.1"]}"#, "[]"] {
            guard case .malformed = VPNDNSOverrideLegacyFile.decode(Data(json.utf8)) else { return XCTFail(json) }
        }
    }
}
