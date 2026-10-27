// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// The alias table on its own: partitions, eviction, expiry and the bounded sweep. It takes no owner and no hop, so these tests
/// exercise the component that the service composes, not a copy of its rules.
final class RuntimeServiceAliasTableTests: XCTestCase {
    private let stop = ControlAdmission.accepted(RuntimeServiceFixtures.operation(50))

    private func fingerprint(_ value: Int) -> Data {
        RuntimeAliasTable.fingerprint(of: Data("command-\(value)".utf8))
    }

    func testTheFingerprintIsFixedSizeAndNeverTheCommandBody() throws {
        let limits = try RuntimeServiceFixtures.limits()
        let body = Data(repeating: 0x41, count: 4096)
        XCTAssertEqual(RuntimeAliasTable.fingerprint(of: body).count, limits.fingerprintBytes)
    }

    func testTheOldestAliasOfAPartitionIsEvictedToMakeRoom() throws {
        let limits = try RuntimeServiceFixtures.limits(aliases: 2)
        var table = RuntimeAliasTable(limits: limits)
        let now = ContinuousClock.now
        for id in 1...3 {
            table.record(RuntimeServiceFixtures.requestID(id), origin: .ordinary(fingerprint: fingerprint(id)), partition: .ordinary, admission: stop, now: now)
        }
        XCTAssertEqual(table.count, 2, "the count bound holds")
        XCTAssertNil(table.live(RuntimeServiceFixtures.requestID(1), now: now), "the oldest alias is the one evicted")
        XCTAssertNotNil(table.live(RuntimeServiceFixtures.requestID(3), now: now))
        XCTAssertEqual(table.bytesTotal, 2 * limits.aliasRecordWorstBytes, "the byte total charges each alias its worst record")
    }

    func testAPartitionsEvictionNeverTouchesAnotherPartition() throws {
        let limits = try RuntimeServiceFixtures.limits(aliases: 1)
        var table = RuntimeAliasTable(limits: limits)
        let now = ContinuousClock.now
        table.record(RuntimeServiceFixtures.requestID(1), origin: .ordinary(fingerprint: fingerprint(1)), partition: .ordinary, admission: stop, now: now)
        table.record(RuntimeServiceFixtures.requestID(2), origin: .ordinary(fingerprint: fingerprint(2)), partition: .stop(.dns), admission: stop, now: now)
        table.record(RuntimeServiceFixtures.requestID(3), origin: .ordinary(fingerprint: fingerprint(3)), partition: .stop(.dns), admission: stop, now: now)
        XCTAssertNotNil(table.live(RuntimeServiceFixtures.requestID(1), now: now), "a dns flood never evicts an ordinary alias")
        XCTAssertNil(table.live(RuntimeServiceFixtures.requestID(2), now: now), "the dns partition evicts its own oldest alias")
    }

    func testAnAliasExpiresFromItsAdmissionAndTheLookupRemovesIt() throws {
        let limits = try RuntimeServiceFixtures.limits()
        var table = RuntimeAliasTable(limits: limits)
        let admitted = ContinuousClock.now
        table.record(RuntimeServiceFixtures.requestID(1), origin: .ordinary(fingerprint: fingerprint(1)), partition: .ordinary, admission: stop, now: admitted)
        XCTAssertNotNil(table.live(RuntimeServiceFixtures.requestID(1), now: admitted.advanced(by: .seconds(59))))
        XCTAssertNil(table.live(RuntimeServiceFixtures.requestID(1), now: admitted.advanced(by: .seconds(60))), "age is exact at the boundary")
        XCTAssertEqual(table.count, 0, "an expired lookup removes the alias")
    }

    func testTheSweepRemovesAtMostItsBatchPerTurnFromTheExpiredPrefix() throws {
        let limits = try RuntimeServiceFixtures.limits(aliases: 4)
        var table = RuntimeAliasTable(limits: limits)
        let admitted = ContinuousClock.now
        for id in 1...3 {
            table.record(RuntimeServiceFixtures.requestID(id), origin: .ordinary(fingerprint: fingerprint(id)), partition: .ordinary, admission: stop, now: admitted)
        }
        let later = admitted.advanced(by: .seconds(120))
        table.sweep(now: later, batch: 1)
        XCTAssertEqual(table.count, 2, "one expired alias is removed per turn")
        table.sweep(now: later, batch: 10)
        XCTAssertEqual(table.count, 0, "later turns remove the rest")
    }

    func testTheSweepStopsAtTheFirstLiveAliasOfEachPartition() throws {
        let limits = try RuntimeServiceFixtures.limits(aliases: 4)
        var table = RuntimeAliasTable(limits: limits)
        let early = ContinuousClock.now
        table.record(RuntimeServiceFixtures.requestID(1), origin: .ordinary(fingerprint: fingerprint(1)), partition: .ordinary, admission: stop, now: early)
        let late = early.advanced(by: .seconds(90))
        table.record(RuntimeServiceFixtures.requestID(2), origin: .ordinary(fingerprint: fingerprint(2)), partition: .ordinary, admission: stop, now: late)
        table.sweep(now: early.advanced(by: .seconds(120)), batch: 10)
        XCTAssertEqual(table.count, 1, "the live alias behind the expired prefix is kept")
        XCTAssertNotNil(table.live(RuntimeServiceFixtures.requestID(2), now: early.advanced(by: .seconds(120))))
    }
}
