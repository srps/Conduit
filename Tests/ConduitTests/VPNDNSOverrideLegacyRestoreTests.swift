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
        var read: VPNDNSLegacyRead
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
        XCTAssertTrue(outcome.needsRetry)
        XCTAssertEqual(file.deletes + file.setAsides, 0)
    }

    func testAFailedRestoreIsTriedAgainOnTheBackoffAndOnAStoreChangeReadingBothAfresh() {
        let file = RecordFile(record)
        let store = RefusingStore(read: .unreadable("copy: Failed!"))
        var retry = VPNDNSOverrideLegacyRetry()
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []
        retry.attempt(.start, now: 100, store: store, file: file) { reported.append($0) }
        XCTAssertEqual(retry.attempts, 1)
        retry.attempt(.tick, now: 105, store: store, file: file) { reported.append($0) }
        retry.attempt(.storeChanged, now: 105, store: store, file: file) { reported.append($0) }
        XCTAssertEqual(retry.attempts, 1, "neither is due within the first delay")
        retry.attempt(.tick, now: 110, store: store, file: file) { reported.append($0) }
        XCTAssertEqual(retry.attempts, 2)
        retry.attempt(.tick, now: 125, store: store, file: file) { reported.append($0) }
        XCTAssertEqual(retry.attempts, 2, "the delay doubled to 20 s")

        let recovered = FakeVPNDNSStore()
        recovered.connectFullTunnel(service, servers: ["127.0.0.1"])
        retry.attempt(.storeChanged, now: 121, store: recovered, file: file) { reported.append($0) }
        XCTAssertEqual(retry.attempts, 3)
        XCTAssertEqual(recovered.serverAddresses(service), originals)
        XCTAssertEqual(file.loads, 3, "the record is read before every attempt")
        XCTAssertFalse(retry.pending)
        XCTAssertEqual(reported.last, .restored(service: service))
    }

    func testTheRetryStopsAtItsBoundAndSaysSo() {
        let file = RecordFile(.unreadable("read: Input/output error"))
        var retry = VPNDNSOverrideLegacyRetry()
        var reported: [VPNDNSOverrideLegacyRestore.Outcome] = []
        var now: UInt64 = 0
        for _ in 0..<100 {
            retry.attempt(.tick, now: now, store: FakeVPNDNSStore(), file: file) { reported.append($0) }
            retry.attempt(.start, now: now, store: FakeVPNDNSStore(), file: file) { reported.append($0) }
            now += 60
        }
        XCTAssertEqual(retry.attempts, VPNDNSOverrideLegacyRetry.maximumAttempts)
        XCTAssertFalse(retry.pending)
        XCTAssertEqual(reported.last, .gaveUp(attempts: VPNDNSOverrideLegacyRetry.maximumAttempts))
        XCTAssertEqual(file.deletes + file.setAsides, 0)
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
