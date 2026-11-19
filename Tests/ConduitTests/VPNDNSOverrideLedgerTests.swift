// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import PlatformMac

final class VPNDNSOverrideLedgerTests: XCTestCase {
    private let service = "com.cisco.anyconnect"
    private let servers = ["192.0.2.53", "198.51.100.53"]
    private let extra: [String: VPNDNSValue] = [
        "DomainName": .string("corp.example"),
        "SearchDomains": .strings(["corp.example"]),
        "SearchOrder": .number(1),
        "ConfirmedServiceID": .string("com.cisco.anyconnect"),
    ]

    private var store: FakeVPNDNSStore!
    private var probe: FakeVPNDNSForwarderProbe!
    private var file: InMemoryVPNDNSOverridePersistence!
    private var outcomes: [VPNDNSOverrideOutcome] = []
    private var ledger: VPNDNSOverrideLedger!

    override func setUp() {
        super.setUp()
        store = FakeVPNDNSStore()
        store.connectFullTunnel(service, servers: servers, extra: extra)
        probe = FakeVPNDNSForwarderProbe()
        file = InMemoryVPNDNSOverridePersistence()
        outcomes = []
        ledger = makeLedger()
    }

    private func makeLedger() -> VPNDNSOverrideLedger {
        VPNDNSOverrideLedger(store: store, probe: probe, persistence: file) { [unowned self] in outcomes.append($0) }
    }

    private func dns(_ addresses: [String]) -> [String: VPNDNSValue] {
        var value = extra
        value["ServerAddresses"] = .strings(addresses)
        return value
    }

    private func applied() {
        XCTAssertEqual(ledger.apply(service: service, expected: servers), .applied)
        outcomes = []
    }

    func testApplyPersistsTheRecordThenWritesOnlyServerAddresses() {
        let file = self.file!
        let persistedBeforeWrite = LockedFlag()
        store.beforeWrite = { _ in persistedBeforeWrite.set(file.bytes != nil) }

        XCTAssertEqual(ledger.apply(service: service, expected: servers), .applied)

        XCTAssertTrue(persistedBeforeWrite.value, "the record is on disk before the key is written")
        XCTAssertEqual(store.writes, [.set(service: service, value: dns(["127.0.0.1"]))])
        XCTAssertEqual(ledger.status(), VPNDNSOverrideRecord(serviceID: service, originals: servers))
        XCTAssertEqual(file.load(), .record(VPNDNSOverrideRecord(serviceID: service, originals: servers)))
        XCTAssertEqual(outcomes, [.applied(service: service, servers: 2)])
    }

    func testEveryRefusalWritesNothingAndHoldsNothing() {
        let cases: [(String, HelperVPNDNSOverrideRefusal, (FakeVPNDNSStore, FakeVPNDNSForwarderProbe) -> Void, String, [String])] = [
            ("no key", .notFound, { store, _ in store.setTunnel(self.service, nil) }, service, servers),
            ("no ServerAddresses", .notFound, { store, _ in store.setTunnel(self.service, .init(dns: self.extra)) }, service, servers),
            ("empty ServerAddresses", .notFound, { store, _ in store.clientRewrite(self.service, servers: []) }, service, servers),
            ("no OverridePrimary", .notFullTunnel, { store, _ in store.setTunnel(self.service, .init(dns: self.dns(self.servers), overridePrimary: false)) }, service, servers),
            ("no IPv4", .notFullTunnel, { store, _ in store.setTunnel(self.service, .init(dns: self.dns(self.servers), ipv4: false)) }, service, servers),
            ("not primary", .notPrimary, { store, _ in store.primary = "en0-service" }, service, servers),
            ("supplemental domains", .notFullTunnel, { store, _ in
                var value = self.dns(self.servers)
                value["SupplementalMatchDomains"] = .strings(["corp.example"])
                store.setTunnel(self.service, .init(dns: value))
            }, service, servers),
            ("servers changed", .changed, { _, _ in }, service, ["192.0.2.53"]),
            ("servers reordered", .changed, { _, _ in }, service, ["198.51.100.53", "192.0.2.53"]),
            ("loopback expected", .invalid, { store, _ in store.clientRewrite(self.service, servers: ["127.0.0.1"]) }, service, ["127.0.0.1"]),
            ("mapped loopback expected", .invalid, { store, _ in store.clientRewrite(self.service, servers: ["::ffff:127.0.0.2"]) }, service, ["::ffff:127.0.0.2"]),
            ("not an address", .invalid, { store, _ in store.clientRewrite(self.service, servers: ["corp.example"]) }, service, ["corp.example"]),
            ("service id with a slash", .invalid, { _, _ in }, "com.cisco/../Global", servers),
            ("relay not running", .relayNotServing, { _, probe in probe.verdict = .notRunning }, service, servers),
            ("TCP relay not listening", .relayNotServing, { _, probe in probe.tcpRelayListening = false }, service, servers),
            ("target refused", .relayNotServing, { _, probe in probe.verdict = .refused }, service, servers),
            ("target silent", .relayNotServing, { _, probe in probe.verdict = .silent }, service, servers),
            ("probe failed", .relayNotServing, { _, probe in probe.verdict = .failed("socket: EMFILE") }, service, servers),
        ]
        for (name, reason, arrange, service, expected) in cases {
            setUp()
            arrange(store, probe)
            XCTAssertEqual(ledger.apply(service: service, expected: expected), .refused(reason), name)
            XCTAssertEqual(store.writes, [], name)
            XCTAssertNil(ledger.status(), name)
            XCTAssertNil(file.bytes, name)
            XCTAssertEqual(outcomes, [.refused(service: service, reason: reason)], name)
        }
    }

    func testAnEmptySupplementalListIsStillAFullTunnel() {
        var value = dns(servers)
        value["SupplementalMatchDomains"] = .strings([])
        store.setTunnel(service, .init(dns: value))
        XCTAssertEqual(ledger.apply(service: service, expected: servers), .applied)
    }

    func testRefusalsComeInTheDesignsOrder() {
        // A split tunnel that is also not primary: the scope check speaks first.
        store.setTunnel(service, .init(dns: dns(servers), overridePrimary: false))
        store.primary = "en0-service"
        XCTAssertEqual(ledger.apply(service: service, expected: ["203.0.113.1"]), .refused(.notFullTunnel))
        // Primary but changed, with the relay down: changed comes before the probe.
        setUp()
        probe.verdict = .refused
        XCTAssertEqual(ledger.apply(service: service, expected: ["203.0.113.1"]), .refused(.changed))
        XCTAssertEqual(probe.probes, 0, "the probe is the last check")
    }

    func testAFailedWriteHoldsNothing() {
        store.failsWrites = true
        XCTAssertEqual(ledger.apply(service: service, expected: servers), .refused(.writeFailed))
        XCTAssertNil(ledger.status())
        XCTAssertNil(file.bytes)
        XCTAssertEqual(store.serverAddresses(service), servers)
    }

    func testAFailedSaveWritesNothing() {
        file.failsSave = true
        XCTAssertEqual(ledger.apply(service: service, expected: servers), .refused(.writeFailed))
        XCTAssertEqual(store.writes, [])
        XCTAssertNil(ledger.status())
        XCTAssertEqual(outcomes.last, .refused(service: service, reason: .writeFailed))
        XCTAssertTrue(outcomes.contains { if case .persistenceFailed("save", _) = $0 { return true } else { return false } })
    }

    func testARecordForAnotherServiceIsReleasedFirst() {
        applied()
        let other = "11111111-2222-3333-4444-555555555555"
        store.connectFullTunnel(other, servers: ["203.0.113.53"])

        XCTAssertEqual(ledger.apply(service: other, expected: ["203.0.113.53"]), .applied)

        XCTAssertEqual(store.serverAddresses(service), servers, "the first service's originals are back")
        XCTAssertEqual(store.serverAddresses(other), ["127.0.0.1"])
        XCTAssertEqual(ledger.status(), VPNDNSOverrideRecord(serviceID: other, originals: ["203.0.113.53"]))
        XCTAssertEqual(outcomes, [
            .released(service: service, reason: .requested, write: .restored),
            .applied(service: other, servers: 1),
        ])
    }

    func testARecordForTheSameServiceWhoseKeyTheClientRewroteIsReplaced() {
        applied()
        store.clientRewrite(service, servers: ["192.0.2.54"])

        XCTAssertEqual(ledger.apply(service: service, expected: ["192.0.2.54"]), .applied)

        XCTAssertEqual(ledger.status(), VPNDNSOverrideRecord(serviceID: service, originals: ["192.0.2.54"]))
        ledger.release(reason: .requested)
        XCTAssertEqual(store.serverAddresses(service), ["192.0.2.54"])
    }

    func testASecondApplyOverTheOverrideIsRefusedChanged() {
        applied()
        XCTAssertEqual(ledger.apply(service: service, expected: servers), .refused(.changed))
        XCTAssertEqual(ledger.status()?.originals, servers, "the record is untouched")
    }

    func testReleaseRestoresTheOriginalsFieldForField() {
        applied()
        ledger.release(reason: .requested)

        XCTAssertEqual(store.tunnel(service)?.dns, dns(servers))
        XCTAssertNil(ledger.status())
        XCTAssertNil(file.bytes)
        XCTAssertEqual(outcomes, [.released(service: service, reason: .requested, write: .restored)])
    }

    func testReleaseKeepsAFieldTheClientAddedMeanwhile() {
        applied()
        var value = store.tunnel(service)!.dns!
        value["SearchOrder"] = .number(5)
        store.setTunnel(service, .init(dns: value))

        ledger.release(reason: .requested)

        var expected = dns(servers)
        expected["SearchOrder"] = .number(5)
        XCTAssertEqual(store.tunnel(service)?.dns, expected)
    }

    func testReleaseWritesNothingOverTheClientsNewerValue() {
        applied()
        store.clientRewrite(service, servers: ["192.0.2.99"])
        let before = store.writes

        ledger.release(reason: .ownerExited)

        XCTAssertEqual(store.writes, before)
        XCTAssertEqual(store.serverAddresses(service), ["192.0.2.99"])
        XCTAssertNil(ledger.status())
        XCTAssertNil(file.bytes)
        XCTAssertEqual(outcomes, [.released(service: service, reason: .ownerExited, write: .keyChanged)])
    }

    func testReleaseWritesNothingWhenTheKeyIsGone() {
        applied()
        store.clientRemove(service)
        let before = store.writes

        ledger.release(reason: .requested)

        XCTAssertEqual(store.writes, before)
        XCTAssertNil(store.tunnel(service))
        XCTAssertEqual(outcomes, [.released(service: service, reason: .requested, write: .keyGone)])
    }

    func testAReleaseMidFlapKeepsTheClientsKeyWithTheOriginals() {
        applied()
        var flapping = try! XCTUnwrap(store.tunnel(service))
        flapping.ipv4 = false
        store.setTunnel(service, flapping)

        ledger.release(reason: .requested)

        XCTAssertEqual(store.serverAddresses(service), servers, "the client's key is back, never deleted")
        XCTAssertEqual(outcomes, [.released(service: service, reason: .requested, write: .restored)])
    }

    func testAServiceDeletedMidReleaseIsLeftHoldingTheOriginals() {
        applied()
        let store = self.store!
        store.beforeWrite = { service in
            store.beforeWrite = nil
            store.clientRemove(service)
        }

        ledger.release(reason: .requested)

        XCTAssertEqual(store.serverAddresses(service), servers, "an inert key with the originals, as the client publishes on reconnect")
        XCTAssertEqual(outcomes, [.released(service: service, reason: .requested, write: .restored)])
    }

    func testAnApplyThatFindsNoIPv4KeyPutsTheOriginalsBack() {
        let store = self.store!
        store.beforeWrite = { service in
            store.beforeWrite = nil
            var flapping = store.tunnel(service)!
            flapping.ipv4 = false
            store.setTunnel(service, flapping)
        }

        XCTAssertEqual(ledger.apply(service: service, expected: servers), .refused(.notFound))

        XCTAssertEqual(store.serverAddresses(service), servers, "no 127.0.0.1 is left, and the key is not deleted")
        XCTAssertNil(ledger.status(), "nothing is held")
        XCTAssertTrue(outcomes.contains(.serviceGoneDuringApply(service: service, restored: true)))
    }

    func testAFailedRestoreIsReportedAndTheRecordKeptForTheNextTick() {
        applied()
        store.failsWrites = true
        ledger.release(reason: .requested)
        let held = VPNDNSOverrideRecord(serviceID: service, originals: servers)
        XCTAssertEqual(ledger.status(), held)
        XCTAssertEqual(ledger.restorePending, .requested)
        XCTAssertEqual(file.load(), .record(held), "the record stays on disk")
        XCTAssertNil(ledger.lastRelease, "nothing was released yet")
        XCTAssertEqual(outcomes, [.released(service: service, reason: .requested, write: .restoreFailed)])
        XCTAssertTrue(outcomes[0].isFailure)
        XCTAssertTrue(outcomes[0].logLine.hasSuffix("write=restore_failed restore_pending=next_tick"), outcomes[0].logLine)
    }

    func testAFailedRestoreIsRetriedOnTheNextTickBeforeAnyProbeAndLands() {
        applied()
        store.failsWrites = true
        ledger.release(reason: .ownerExited)
        ledger.tick()
        XCTAssertEqual(ledger.restorePending, .ownerExited, "still failing: kept")
        XCTAssertEqual(outcomes.count, 2, "one retry per tick")

        store.failsWrites = false
        probe.verdict = .refused
        let probesBefore = probe.probes
        ledger.tick()

        XCTAssertEqual(probe.probes, probesBefore, "the retry comes before any probe")
        XCTAssertEqual(store.serverAddresses(service), servers)
        XCTAssertNil(ledger.status())
        XCTAssertNil(ledger.restorePending)
        XCTAssertNil(file.bytes)
        XCTAssertEqual(ledger.lastRelease, .ownerExited)
        XCTAssertEqual(outcomes.last, .released(service: service, reason: .ownerExited, write: .restored))
    }

    func testAPendingRestoreWhoseKeyTheClientRewroteIsForgotten() {
        applied()
        store.failsWrites = true
        ledger.release(reason: .requested)
        store.failsWrites = false
        store.clientRewrite(service, servers: ["192.0.2.99"])

        ledger.tick()

        XCTAssertNil(ledger.status())
        XCTAssertNil(file.bytes)
        XCTAssertEqual(store.serverAddresses(service), ["192.0.2.99"])
        XCTAssertEqual(outcomes.last, .released(service: service, reason: .requested, write: .keyChanged))
    }

    func testAPersistedRecordWhoseRestoreFailsAtHelperStartIsKeptForTheNextTick() {
        applied()
        store.failsWrites = true
        let restarted = makeLedger()
        restarted.start()

        let held = VPNDNSOverrideRecord(serviceID: service, originals: servers)
        XCTAssertEqual(restarted.status(), held)
        XCTAssertEqual(restarted.restorePending, .helperStart)
        XCTAssertEqual(file.load(), .record(held))
        XCTAssertEqual(outcomes, [.released(service: service, reason: .helperStart, write: .restoreFailed)])

        store.failsWrites = false
        restarted.tick()
        XCTAssertNil(restarted.status())
        XCTAssertEqual(store.serverAddresses(service), servers)
        XCTAssertEqual(outcomes.last, .released(service: service, reason: .helperStart, write: .restored))
    }

    func testAnApplyToAnotherServiceWhileARestoreIsPendingIsRefused() {
        applied()
        let other = "11111111-2222-3333-4444-555555555555"
        store.connectFullTunnel(other, servers: ["203.0.113.53"])
        store.primary = service
        store.failsWrites = true
        ledger.release(reason: .requested)
        store.primary = other
        outcomes = []

        XCTAssertEqual(ledger.apply(service: other, expected: ["203.0.113.53"]), .refused(.writeFailed))

        let held = VPNDNSOverrideRecord(serviceID: service, originals: servers)
        XCTAssertEqual(ledger.status(), held, "one record, the pending one")
        XCTAssertEqual(file.load(), .record(held), "its file is not overwritten")
        XCTAssertEqual(store.serverAddresses(other), ["203.0.113.53"])
        XCTAssertEqual(outcomes, [
            .released(service: service, reason: .requested, write: .restoreFailed),
            .refused(service: other, reason: .writeFailed),
        ])
    }

    func testReleaseWithNothingHeldWritesNothing() {
        ledger.release(reason: .requested)
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(outcomes, [.nothingToRelease(reason: .requested)])
    }

    func testAFailedDeleteIsReported() {
        applied()
        file.failsDelete = true
        ledger.release(reason: .requested)
        XCTAssertNil(ledger.status())
        XCTAssertTrue(outcomes.contains { if case .persistenceFailed("delete", _) = $0 { return true } else { return false } })
    }

    func testOneRefusedTickIsARestartTwoAreAForwarderGone() {
        applied()
        probe.verdict = .refused
        ledger.tick()
        XCTAssertNotNil(ledger.status(), "one refusal is a forwarder restart in progress")
        XCTAssertEqual(store.serverAddresses(service), ["127.0.0.1"])
        XCTAssertEqual(outcomes, [.probeMissed(service: service, verdict: .refused, consecutive: 1)])

        ledger.tick()
        XCTAssertNil(ledger.status())
        XCTAssertEqual(store.serverAddresses(service), servers)
        XCTAssertEqual(outcomes.last, .released(service: service, reason: .targetRefused, write: .restored))
    }

    func testAnAnswerBetweenRefusalsResetsTheCount() {
        applied()
        for verdict in [VPNDNSProbeVerdict.refused, .answered, .refused, .silent, .refused] {
            probe.verdict = verdict
            ledger.tick()
        }
        XCTAssertNotNil(ledger.status())
    }

    func testThreeSilentTicksRelease() {
        applied()
        probe.verdict = .silent
        ledger.tick()
        ledger.tick()
        XCTAssertNotNil(ledger.status())
        ledger.tick()
        XCTAssertNil(ledger.status())
        XCTAssertEqual(outcomes.last, .released(service: service, reason: .targetSilent, write: .restored))
    }

    func testAFailedProbeIsInconclusive() {
        applied()
        probe.verdict = .silent
        ledger.tick()
        ledger.tick()
        probe.verdict = .failed("socket: EMFILE")
        ledger.tick()
        ledger.tick()
        XCTAssertNotNil(ledger.status(), "the helper's own failure is not the forwarder's silence")
        probe.verdict = .silent
        ledger.tick()
        XCTAssertNil(ledger.status())
    }

    func testARelayThatStoppedReleasesOnTheNextTick() {
        applied()
        probe.verdict = .notRunning
        ledger.tick()
        XCTAssertNil(ledger.status())
        XCTAssertEqual(outcomes, [.released(service: service, reason: .relayStopped, write: .restored)])
    }

    func testATCPRelayThatStoppedReleasesOnTheNextTick() {
        applied()
        probe.tcpRelayListening = false
        let probesBefore = probe.probes
        ledger.tick()
        XCTAssertNil(ledger.status())
        XCTAssertEqual(store.serverAddresses(service), servers)
        XCTAssertEqual(outcomes, [.released(service: service, reason: .relayStopped, write: .restored)])
        XCTAssertEqual(probe.probes, probesBefore, "a relay without TCP is released before any query")
    }

    func testATickWithNothingHeldProbesNothing() {
        ledger.tick()
        XCTAssertEqual(probe.probes, 0)
        XCTAssertEqual(outcomes, [])
    }

    func testTheRecordIsKeptAcrossARelayRestartThatWorked() {
        applied()
        probe.verdict = .refused
        ledger.tick()
        ledger.relayRestarted(succeeded: true)
        ledger.tick()
        XCTAssertNotNil(ledger.status(), "the restart reset the count; the new target gets its own two ticks")
        XCTAssertEqual(store.serverAddresses(service), ["127.0.0.1"])
    }

    func testAFailedRelayRestartReleases() {
        applied()
        ledger.relayRestarted(succeeded: false)
        XCTAssertNil(ledger.status())
        XCTAssertEqual(outcomes, [.released(service: service, reason: .relayStopped, write: .restored)])
    }

    func testEachTriggerReleasesWithItsReason() {
        for reason in VPNDNSOverrideReleaseReason.allCases {
            setUp()
            applied()
            ledger.release(reason: reason)
            XCTAssertEqual(outcomes, [.released(service: service, reason: reason, write: .restored)], reason.rawValue)
            XCTAssertEqual(store.serverAddresses(service), servers, reason.rawValue)
        }
    }

    func testTheLastReleaseIsRememberedForStatusAndNothingToReleaseLeavesIt() {
        XCTAssertNil(ledger.lastRelease)
        applied()
        probe.verdict = .refused
        ledger.tick()
        ledger.tick()
        XCTAssertNil(ledger.status())
        XCTAssertEqual(ledger.lastRelease, .targetRefused)

        ledger.release(reason: .requested)
        XCTAssertEqual(ledger.lastRelease, .targetRefused, "a release with nothing held is no release")

        probe.verdict = .answered
        applied()
        XCTAssertEqual(ledger.lastRelease, .targetRefused, "an apply does not clear it")
        ledger.release(reason: .requested)
        XCTAssertEqual(ledger.lastRelease, .requested)
    }

    func testAHelperStartReleasesAPersistedRecord() {
        applied()
        let restarted = makeLedger()
        restarted.start()
        XCTAssertNil(restarted.status())
        XCTAssertEqual(store.serverAddresses(service), servers)
        XCTAssertNil(file.bytes)
        XCTAssertEqual(outcomes, [.released(service: service, reason: .helperStart, write: .restored)])
    }

    func testAHelperStartWithNoRecordDoesNothing() {
        ledger.start()
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(outcomes, [])
    }

    func testAnUndecodableRecordIsDeletedAndTheKeyLeftAlone() {
        let undecodable: [Data] = [
            Data("{not json".utf8),
            Data(#"{"serviceID":"com.cisco.anyconnect"}"#.utf8),
            Data(#"{"serviceID":"com.cisco.anyconnect","originals":["127.0.0.1"]}"#.utf8),
            Data(#"{"serviceID":"a/b","originals":["192.0.2.53"]}"#.utf8),
            Data(#"{"serviceID":"com.cisco.anyconnect","originals":[]}"#.utf8),
        ]
        for bytes in undecodable {
            setUp()
            store.clientRewrite(service, servers: ["127.0.0.1"])
            file.bytes = bytes
            ledger.start()
            XCTAssertNil(file.bytes, String(decoding: bytes, as: UTF8.self))
            XCTAssertEqual(store.writes, [])
            XCTAssertNil(ledger.status())
            guard case .discardedUndecodableRecord? = outcomes.first else {
                return XCTFail("expected a discarded record, got \(outcomes)")
            }
            XCTAssertTrue(outcomes[0].isFailure)
        }
    }

    func testTheRecordFileRoundTripsAtModeSixHundred() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-vpn-override-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = VPNDNSOverrideFile(path: directory.appendingPathComponent("vpn-dns-override.json").path)
        let record = VPNDNSOverrideRecord(serviceID: service, originals: servers)

        XCTAssertEqual(file.load(), .none)
        try file.save(record)
        XCTAssertEqual(file.load(), .record(record))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: file.path)), as: UTF8.self),
            #"{"originals":["192.0.2.53","198.51.100.53"],"serviceID":"com.cisco.anyconnect"}"#
        )
        try file.delete()
        XCTAssertEqual(file.load(), .none)
        XCTAssertNoThrow(try file.delete(), "deleting nothing succeeds")
    }

    func testAnOversizedRecordFileIsUndecodable() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pm-vpn-override-\(UUID().uuidString.prefix(8)).json").path
        defer { unlink(path) }
        try Data(repeating: 0x20, count: VPNDNSOverrideFile.maximumBytes + 1).write(to: URL(fileURLWithPath: path))
        guard case .undecodable = VPNDNSOverrideFile(path: path).load() else { return XCTFail("expected undecodable") }
    }

    func testNoLogLineCarriesAServerAddress() {
        applied()
        store.clientRewrite(service, servers: ["192.0.2.99"])
        ledger.release(reason: .requested)
        file.bytes = Data("{".utf8)
        ledger.start()
        let lines = [
            VPNDNSOverrideOutcome.applied(service: service, servers: 2),
            .refused(service: service, reason: .changed),
            .probeMissed(service: service, verdict: .silent, consecutive: 2),
        ].map(\.logLine) + outcomes.map(\.logLine)
        for line in lines {
            for address in servers + ["192.0.2.99", "127.0.0.1"] {
                XCTAssertFalse(line.contains(address), line)
            }
        }
        XCTAssertEqual(
            VPNDNSOverrideOutcome.released(service: service, reason: .ownerExited, write: .keyChanged).logLine,
            "vpn-dns-override released service=com.cisco.anyconnect reason=owner_exited write=key_changed"
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
