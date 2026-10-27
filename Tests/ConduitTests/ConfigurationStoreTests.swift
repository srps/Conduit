// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The configuration store core over the fake file access and a real lease on a scratch root (decisions 0015, 0017, 0018, 0020, 0025
/// and 0027). The fake holds the bytes and records each read and write, and its observation log holds 16 calls, so every fixture
/// keeps its trace short. Nothing here exercises a Stop, an apply, an incarnation fence of a host, or a physical power loss.
@MainActor
final class ConfigurationStoreTests: XCTestCase {
    /// One store over a scratch root. The root's session is taken through the production bootstrap before anything is seeded, and the store
    /// is built over that session. `close` releases the session's lease through the scratch helper, and removes the directory only when that
    /// release returned `.released`. An unconfirmed close fails the test and keeps the directory, since its lock may still be held.
    /// Internal, so the preservation tests in `ConfigurationStorePreservationTests` share the same seeding.
    @MainActor
    final class Fixture {
        let directory: URL
        let session: StateRootSession
        let plan: StateRootPlan
        let access: FakeStateFileAccess
        let store: ConfigurationStore
        /// The runtime bytes the fixture seeded, or nil when it seeded none. A test compares against these, so an unchanged file is shown
        /// to be unchanged, not merely present.
        let seededRuntime: Data?
        /// Whether every queued physical step this fixture's store started has finished. It is true at setup. A test that launches queued work
        /// clears it before the launch and sets it again only after that work's call is awaited. While it is false, `close` keeps the directory
        /// and releases nothing: the queued step still holds the session.
        var ownedWorkQuiesced = true

        init(runtime: Data? = nil, platform: Data? = nil, preferences: Data? = nil) throws {
            directory = try StateRootScratch.make("configuration-store")
            // A refused bootstrap throws and the directory is kept on purpose. A refusal can be an unconfirmed close or a foreign holder of the
            // root, so nothing is removed here. The original error propagates and fails the test.
            session = try acquireScratchStateRoot(
                RuntimeEnvironment(configDirectory: directory, configFile: directory.appendingPathComponent("config.json"))
            )
            plan = session.plan
            var files: [String: Data] = [:]
            // A sidecar with no runtime file is refused at startup, as the legacy loader always refused it, so a sidecar fixture seeds defaults.
            let seeded = try runtime ?? (platform == nil && preferences == nil ? nil : ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()))
            seededRuntime = seeded
            if let seeded { files[plan.config.path] = seeded }
            if let platform { files[plan.platformConfig.path] = platform }
            if let preferences { files[plan.preferences.path] = preferences }
            access = FakeStateFileAccess(files: files)
            store = ConfigurationStore(session: session, access: access, work: PlatformWork(label: "test.configuration-store"))
        }

        func close() {
            // While queued work may still hold the session, release nothing and keep the directory. The session then closes when its last
            // reference goes, and that close reports through the helper's own callback.
            guard ownedWorkQuiesced else { return }
            // Only a confirmed close lets the protected root go. An unconfirmed one has already failed the test, and its directory stays.
            if releaseScratchStateRoot(session) == .released {
                StateRootScratch.remove(directory)
            }
        }
    }

    /// The staged runtime file is not a JSON object, so a witness cannot add a key to it.
    private struct SeedNotAnObject: Error {}

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    private func preferenceBytes(showMenuBarIcon: Bool) throws -> Data {
        var preferences = AppPreferences()
        preferences.showMenuBarIcon = showMenuBarIcon
        return try AppPreferencesPersistence.stagedData(for: preferences)
    }

    private func describe(_ outcome: ConfigurationWriteOutcome) -> String {
        switch outcome {
        case .persisted: "persisted"
        case .unchanged: "unchanged"
        case .notPersisted: "notPersisted"
        case .unknown: "unknown"
        case .conflict: "conflict"
        case .notAttempted(let reason): "notAttempted(\(reason))"
        }
    }

    private func adoptedLoad(_ fixture: Fixture) async -> ConfigurationSlots<ConfigurationComponentLoad>? {
        guard case .admitted(let report) = await fixture.store.load(context: Self.context),
              case .adopted(let loaded) = report.outcome else {
            XCTFail("the load was not adopted")
            return nil
        }
        return loaded
    }

    private func writes(_ fixture: Fixture, at path: String) -> Int {
        fixture.access.observations.filter { if case .write(let written, _) = $0 { written == path } else { false } }.count
    }

    /// Commits the store's current runtime and platform values at their current tokens, the canonical no-op save. A present file whose
    /// verified value is the candidate is verified without a write, so an external change is a conflict that latches. Returns the file that
    /// conflicted, or nil, and fails the test on any write.
    private func latchByNoOpCommit(_ fixture: Fixture) async -> ConfigurationComponent? {
        guard let current = fixture.store.values else {
            XCTFail("the store holds no values")
            return nil
        }
        let before = writes(fixture, at: fixture.plan.config.path) + writes(fixture, at: fixture.plan.platformConfig.path)
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(
            current.runtime, current.platform, expecting: tokens, context: Self.context
        ) else {
            XCTFail("the no-op commit was not admitted")
            return nil
        }
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path) + writes(fixture, at: fixture.plan.platformConfig.path), before, "a no-op commit writes nothing")
        if case .conflict = result.platform { return .platform }
        if case .conflict = result.runtime { return .runtime }
        return nil
    }

    // MARK: - Open and reload

    /// One observation adopts the values and one baseline per file, each from the same bytes the shared decode read.
    func testOpenAdoptsValuesAndBaselinesFromOneObservation() async throws {
        let runtime = try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig())
        let fixture = try Fixture(runtime: runtime, platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()),
                                  preferences: try preferenceBytes(showMenuBarIcon: false))
        defer { fixture.close() }

        guard let loaded = await adoptedLoad(fixture) else { return }
        XCTAssertEqual(loaded.runtime, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(loaded.platform, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false)
        XCTAssertNotNil(fixture.store.baselineToken(for: .runtime))
        XCTAssertFalse(fixture.access.observations.contains { if case .write = $0 { true } else { false } })
    }

    /// Missing files are absent and uncommitted. Each one still has an absent baseline, and the open writes nothing.
    func testMissingFilesAreAbsentUncommittedAndNothingIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }

        guard let loaded = await adoptedLoad(fixture) else { return }
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: false))
        XCTAssertNotNil(fixture.store.baselineToken(for: .preferences))
        XCTAssertTrue(fixture.access.observations.allSatisfy { if case .read = $0 { true } else { false } })
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path))
    }

    /// A refused startup input is never a baseline: no write can be authorized from it, and it names the refusal.
    func testARefusedStartupHoldsNoBaseline() async throws {
        let fixture = try Fixture(runtime: Data("not json".utf8))
        defer { fixture.close() }

        guard case .admitted(let report) = await fixture.store.load(context: Self.context) else {
            return XCTFail("the load was not admitted")
        }
        guard case .refused(.invalidContent) = report.outcome else {
            return XCTFail("the refused runtime was not reported: \(report.outcome)")
        }
        XCTAssertNil(fixture.store.baselineToken(for: .runtime))
        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(),
            expecting: ConfigurationSlots(runtime: nil, platform: nil, preferences: nil), context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.runtime), "notAttempted(noAuthoritativeBaseline)")
        XCTAssertEqual(describe(result.platform), "notAttempted(noAuthoritativeBaseline)")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), Data("not json".utf8))
    }

    // MARK: - Commits

    /// A coupled commit writes the platform file first, then the runtime file. Each receipt names its file's new version, and an
    /// old token no longer authorizes anything.
    func testACoupledCommitPersistsBothFilesAndRetiresTheOldTokens() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: fixture.store.baselineToken(for: .preferences)
        )
        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.platform), "persisted")
        XCTAssertEqual(describe(result.runtime), "persisted")
        XCTAssertNotNil(fixture.access.storedBytes(at: fixture.plan.config.path))
        XCTAssertNotEqual(fixture.store.baselineToken(for: .runtime), tokens.runtime)

        let stale = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
        )
        guard case .admitted(let again) = stale else { return XCTFail("the second commit was not admitted") }
        XCTAssertEqual(describe(again.runtime), "notAttempted(baselineMismatch)")
        XCTAssertEqual(describe(again.platform), "notAttempted(baselineMismatch)")
    }

    /// A present platform file whose verified content already is the candidate is verified without a save. The runtime update persists
    /// only the runtime file, and no platform write is made.
    func testAnUnchangedPlatformFileIsVerifiedWithoutASaveWhileTheRuntimeUpdatePersists() async throws {
        let platformPath: String
        let fixture = try Fixture(platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()))
        defer { fixture.close() }
        platformPath = fixture.plan.platformConfig.path
        guard await adoptedLoad(fixture) != nil else { return }
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        let admission = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context)
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.platform), "unchanged")
        XCTAssertEqual(describe(result.runtime), "persisted")
        XCTAssertEqual(writes(fixture, at: platformPath), 0)
    }

    /// An external change to the platform file is a conflict, and the runtime write is held behind it. Nothing is overwritten.
    func testAnExternalChangeToThePlatformFileConflictsAndHoldsTheRuntimeWrite() async throws {
        let externalPlatform = Data("{\"launchAtLogin\":true}".utf8)
        let fixture = try Fixture(platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        fixture.access.externalEdit(.replace(externalPlatform), at: fixture.plan.platformConfig.path)

        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.platform), "conflict")
        XCTAssertEqual(describe(result.runtime), "notAttempted(heldBehindPlatform)")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), externalPlatform)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), fixture.seededRuntime)
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
    }

    /// A value that cannot be staged starts no write, and the refusal names the field, never the value.
    func testAStagingRefusalStartsNoWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        var preferences = AppPreferences()
        preferences.preferredBrowserTestURL = String(repeating: "a", count: 300_000)

        let admission = await fixture.store.commitPreferences(preferences, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context)
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        guard case .notAttempted(.stagingRefused(.sidecarResourceLimit)) = result.preferences else {
            return XCTFail("the staging refusal names its closed reason, got \(describe(result.preferences))")
        }
        XCTAssertFalse(fixture.access.observations.contains { if case .write = $0 { true } else { false } })
    }

    /// A no-op commit of the current value reports an external change and does not adopt it or write over it. The change latches the
    /// baseline, so no write is authorized.
    func testANoOpCommitReportsAChangeWithoutAdoptingIt() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil, let current = fixture.store.values?.preferences else { return XCTFail("the load was not adopted") }
        let token = fixture.store.baselineToken(for: .preferences)
        let external = try preferenceBytes(showMenuBarIcon: false)
        fixture.access.externalEdit(.replace(external), at: fixture.plan.preferences.path)

        guard case .admitted(let noOp) = await fixture.store.commitPreferences(current, expecting: token, context: Self.context) else {
            return XCTFail("the no-op commit was not admitted")
        }
        XCTAssertEqual(describe(noOp.preferences), "conflict")
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, true)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.preferences.path), external)
        XCTAssertEqual(writes(fixture, at: fixture.plan.preferences.path), 0)
        guard case .admitted(let commit) = await fixture.store.commitPreferences(AppPreferences(), expecting: token, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(commit.preferences), "notAttempted(noAuthoritativeBaseline)")
    }

    /// An observed external change latches the baseline until a reload. Restoring the old bytes does not lift the latch, the old token stays
    /// refused, and a reload adopts the current bytes so that a new token authorizes a save.
    func testAnObservedChangeLatchesUntilAReloadEvenWhenTheOldBytesReturn() async throws {
        let original = try preferenceBytes(showMenuBarIcon: true)
        let fixture = try Fixture(preferences: original)
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        let oldToken = fixture.store.baselineToken(for: .preferences)

        fixture.access.externalEdit(.replace(try preferenceBytes(showMenuBarIcon: false)), at: fixture.plan.preferences.path)
        guard case .admitted(let conflicted) = await fixture.store.commitPreferences(AppPreferences(), expecting: oldToken, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(conflicted.preferences), "conflict")

        fixture.access.externalEdit(.replace(original), at: fixture.plan.preferences.path)
        guard case .admitted(let stillLatched) = await fixture.store.commitPreferences(AppPreferences(), expecting: oldToken, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(stillLatched.preferences), "notAttempted(noAuthoritativeBaseline)")

        guard await adoptedLoad(fixture) != nil else { return }
        let reloaded = fixture.store.baselineToken(for: .preferences)
        XCTAssertNotNil(reloaded)
        XCTAssertNotEqual(reloaded, oldToken)
        var changed = AppPreferences()
        changed.showMenuBarIcon = false
        guard case .admitted(let after) = await fixture.store.commitPreferences(changed, expecting: reloaded, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(after.preferences), "persisted")
    }

    // MARK: - Busy slot

    /// Only one operation holds the store's slot. Of two overlapping calls, the one that finds the slot held returns busy, and nothing is queued.
    func testASecondOperationIsRefusedWhileTheFirstHoldsTheSlot() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        let token = fixture.store.baselineToken(for: .preferences)
        let first = Task { await fixture.store.load(context: Self.context) }
        let second = await fixture.store.commitPreferences(AppPreferences(), expecting: token, context: Self.context)
        let firstAdmission = await first.value

        let busyCount = [isBusy(firstAdmission), isBusy(second)].filter { $0 }.count
        XCTAssertEqual(busyCount, 1, "exactly one of two overlapping calls is refused")
        XCTAssertFalse(fixture.store.isBusy)
    }

    private func isBusy<Value>(_ admission: ConfigurationStoreAdmission<Value>) -> Bool {
        if case .busy = admission { return true }
        return false
    }

    // MARK: - Presence, exhaustion and adapter faults

    /// A journal presence that cannot be checked holds the whole load: nothing is adopted, and no baseline is issued until a later load succeeds.
    func testAnUnknownJournalPresenceHoldsTheLoadAndEveryBaseline() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        defer { fixture.close() }
        fixture.access.schedulePresence(.statusFailed(errno: EIO))
        guard case .admitted(let held) = await fixture.store.load(context: Self.context) else {
            return XCTFail("the load was not admitted")
        }
        XCTAssertEqual(held.outcome, .refused(.journalPresenceUnknown(.statusFailed(errno: EIO))))
        XCTAssertNil(fixture.store.values)
        XCTAssertNil(fixture.store.baselineToken(for: .preferences))
        fixture.access.schedulePresence(nil)
        guard await adoptedLoad(fixture) != nil else { return }
        XCTAssertNotNil(fixture.store.baselineToken(for: .preferences))
    }

    /// The OS presence check reads metadata only: an absent journal is absent, and a present one is present.
    func testTheOSPresenceCheckReportsAbsenceAndPresenceOfTheJournal() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let access = OSStateFileAccess()
        XCTAssertEqual(access.entryPresence(fixture.plan.journal), .success(false))
        try Data().write(to: URL(fileURLWithPath: fixture.plan.journal.path))
        XCTAssertEqual(access.entryPresence(fixture.plan.journal), .success(true))
    }

    /// A component at its maximum version refuses a write before any I/O. A no-op commit is still verified without a write, a changed file
    /// still latches, and a new store incarnation recovers. No version wraps.
    func testAComponentAtItsMaximumVersionRefusesWritesBeforeAnyIO() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.store.exhaustVersionForTesting(.preferences)
        let token = fixture.store.baselineToken(for: .preferences)
        var changed = AppPreferences()
        changed.showMenuBarIcon = false
        let before = fixture.access.observations.count

        guard case .admitted(let refused) = await fixture.store.commitPreferences(changed, expecting: token, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(refused.preferences), "notAttempted(versionExhausted)")
        XCTAssertEqual(fixture.access.observations.count, before, "the refusal makes no read and no write")

        guard let current = fixture.store.values?.preferences,
              case .admitted(let verified) = await fixture.store.commitPreferences(current, expecting: token, context: Self.context) else {
            return XCTFail("the no-op commit was not admitted")
        }
        XCTAssertEqual(describe(verified.preferences), "unchanged")
        XCTAssertEqual(writes(fixture, at: fixture.plan.preferences.path), 0)

        fixture.access.externalEdit(.replace(try preferenceBytes(showMenuBarIcon: false)), at: fixture.plan.preferences.path)
        guard case .admitted(let reloaded) = await fixture.store.load(context: Self.context) else {
            return XCTFail("the reload was not admitted")
        }
        XCTAssertEqual(reloaded.outcome, .refused(.versionExhausted(.preferences)))
        XCTAssertNil(fixture.store.baselineToken(for: .preferences))

        // A test-only second store over the same session models a fresh incarnation. The first store is not used after this point.
        let recovered = ConfigurationStore(session: fixture.session, access: fixture.access, work: PlatformWork(label: "test.configuration-store.recovery"))
        guard case .admitted(let fresh) = await recovered.load(context: Self.context), case .adopted = fresh.outcome else {
            return XCTFail("the new store did not adopt the file")
        }
        XCTAssertNotNil(recovered.baselineToken(for: .preferences))
    }

    /// A platform file with the same parsed value and different formatting is verified, not rewritten. The runtime write is the only write, so
    /// it takes the one scheduled failure. A platform rewrite would have consumed that failure first.
    func testAFormattedUnchangedPlatformFileIsVerifiedAndOnlyTheRuntimeIsWritten() async throws {
        let formatted = try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()) + Data("\n".utf8)
        let fixture = try Fixture(platform: formatted)
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.scheduleWrites([.init(landing: .failsBeforeLanding(errno: 28))])
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(result.platform), "unchanged")
        XCTAssertEqual(describe(result.runtime), "notPersisted")
        guard case .notPersisted(.writeFailed(errno: 28)) = result.runtime else {
            return XCTFail("the runtime write carries the scheduled failure, got \(describe(result.runtime))")
        }
        XCTAssertEqual(writes(fixture, at: fixture.plan.platformConfig.path), 0)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), formatted)
    }

    /// A landed write that reports an error is persisted, and the reported error is kept beside the persisted fact (decision 0015).
    func testALandedWriteThatReportsAnErrorIsPersistedWithItsErrorKept() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.scheduleWrites([.init(landing: .landsThenFails(errno: 5))])
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        guard case .persisted(_, reportedWriteError: .writeFailed(errno: 5)) = result.platform else {
            return XCTFail("a landed write with a reported error is persisted, got \(describe(result.platform))")
        }
        XCTAssertEqual(describe(result.runtime), "persisted")
    }

    /// A read-back that shows neither the staged bytes nor the prior is unknown. The baseline is latched, so no later save is authorized
    /// until a reload.
    func testAnUnknownReadBackLatchesTheBaselineUntilAReload() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        let token = fixture.store.baselineToken(for: .preferences)
        // The write lands, and then another party's bytes replace it before read-back.
        fixture.access.scheduleWrites([.init(landing: .lands, editAfterWrite: .replace(Data("other".utf8)))])
        var changed = AppPreferences()
        changed.showMenuBarIcon = false
        guard case .admitted(let first) = await fixture.store.commitPreferences(changed, expecting: token, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(first.preferences), "unknown")
        XCTAssertNil(fixture.store.baselineToken(for: .preferences))
        guard case .admitted(let second) = await fixture.store.commitPreferences(changed, expecting: token, context: Self.context) else {
            return XCTFail("the second commit was not admitted")
        }
        XCTAssertEqual(describe(second.preferences), "notAttempted(noAuthoritativeBaseline)")
    }

    /// An error no known refusal describes keeps only its code. Its description, which carries a private marker, reaches no outcome.
    func testAnUnexpectedErrorKeepsOnlyItsCode() {
        struct PrivateFailure: LocalizedError {
            var errorDescription: String? { "PRIVATE-MARKER configuration value" }
        }
        let staging = ConfigurationStoreIO.stagingRefusal(for: PrivateFailure())
        let loading = ConfigurationStoreIO.loadRefusal(for: PrivateFailure())
        guard case .unexpected = staging, case .unexpected = loading else {
            return XCTFail("an unknown error is kept as its code only: \(staging), \(loading)")
        }
        XCTAssertFalse("\(staging) \(loading)".contains("PRIVATE-MARKER"))
    }

    /// A field label is kept only when it is a short identifier path, so no value can pass as one.
    func testAFieldLabelAcceptsOnlyAShortIdentifierPath() {
        XCTAssertNotNil(ConfigurationFieldLabel("health.connectionCheckTimeout"))
        XCTAssertNil(ConfigurationFieldLabel("PRIVATE-MARKER value"))
        XCTAssertNil(ConfigurationFieldLabel(String(repeating: "a", count: 65)))
        XCTAssertNil(ConfigurationFieldLabel(""))
    }

    // MARK: - Worker gate, partial and unknown results, and load warnings

    /// A file access that holds the worker's next read until the test releases it. The hold runs on the `PlatformWork` thread, so the
    /// MainActor stays free and a second operation is refused while the first is still in flight. It is a gate, not a timing race. Every
    /// wait is bounded, so a missing entry or release fails the test rather than hanging it.
    private final class GatedAccess: StateFileAccessing, @unchecked Sendable {
        /// The bound for each wait. A passing run never comes near it, and a failing run ends instead of hanging.
        static let bound: DispatchTimeInterval = .seconds(20)

        let inner: FakeStateFileAccess
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        /// A dedicated serial queue for the test's own waiting, so the wait never occupies the cooperative pool.
        private let waiter = DispatchQueue(label: "test.configuration-store.gate-wait")
        private let lock = NSLock()
        private var armed = false
        private var releasedOnce = false

        init(inner: FakeStateFileAccess) {
            self.inner = inner
        }

        func armOnNextRead() {
            lock.withLock { armed = true }
        }

        /// Waits, off the MainActor and off the cooperative pool, until the worker has entered the held read. False means no entry came
        /// within the bound.
        func waitUntilEntered() async -> Bool {
            let entered = self.entered
            let bound = Self.bound
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiter.async {
                    continuation.resume(returning: entered.wait(timeout: .now() + bound) == .success)
                }
            }
        }

        /// Lets the held read proceed. Repeated calls release once, so a cleanup path can call it after the test already did.
        func releaseWorker() {
            let first = lock.withLock { () -> Bool in
                let wasFirst = !releasedOnce
                releasedOnce = true
                return wasFirst
            }
            if first { released.signal() }
        }

        func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
            let hold = lock.withLock { () -> Bool in
                let wasArmed = armed
                armed = false
                return wasArmed
            }
            if hold {
                entered.signal()
                // Bounded: a release that never comes ends the hold, and the read proceeds so the worker can finish.
                _ = released.wait(timeout: .now() + Self.bound)
            }
            return inner.readConfigurationFile(file, limit: limit)
        }

        func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
            inner.replaceConfigurationFile(file, bytes: bytes)
        }

        func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
            inner.entryPresence(file)
        }
    }

    /// A read held on the worker keeps the store's one slot. Overlapping loads and every kind of commit are refused as busy, queue no I/O,
    /// and keep the fake's log unchanged. A cancelled caller detaches only its wait, so the slot stays held until the worker returns.
    func testAHeldWorkerReadKeepsTheSlotAndRefusesOtherOperationsWithoutQueuedIO() async throws {
        let fixture = try Fixture(preferences: try preferenceBytes(showMenuBarIcon: true))
        // Registered first, so it runs last. It removes the directory only if no queued work is still in flight.
        defer { fixture.close() }
        let gated = GatedAccess(inner: fixture.access)
        // Registered after `close`, so it runs first: a held worker read is released before `close` decides.
        defer { gated.releaseWorker() }
        let store = ConfigurationStore(session: fixture.session, access: gated, work: PlatformWork(label: "test.configuration-store.gate"))
        guard case .admitted = await store.load(context: Self.context) else { return XCTFail("the first load was not admitted") }
        let token = store.baselineToken(for: .preferences)
        guard let platformToken = store.baselineToken(for: .platform) else { return XCTFail("the platform holds no baseline") }
        let runtimeToken = store.baselineToken(for: .runtime)

        gated.armOnNextRead()
        // Queued work is in flight from here until its call is awaited below. A failing wait returns early with the flag clear, so `close`
        // keeps the directory and releases nothing.
        fixture.ownedWorkQuiesced = false
        let held = Task { await store.load(context: Self.context) }
        guard await gated.waitUntilEntered() else { return XCTFail("the held read was never entered within the bound") }
        XCTAssertTrue(store.isBusy, "the held read holds the slot")
        let loggedWhileHeld = fixture.access.observations.count

        for round in 0..<2 {
            let load = await store.load(context: Self.context)
            let preferences = await store.commitPreferences(AppPreferences(), expecting: token, context: Self.context)
            let coupled = await store.commitRuntimeAndPlatform(
                GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(),
                expecting: ConfigurationSlots(runtime: nil, platform: nil, preferences: nil), context: Self.context
            )
            let launch = await store.commitLaunchAtLogin(enabled: true, expecting: platformToken, context: Self.context, claim: .neverRevoked)
            let dns = await store.commitDNSLifecycle(enabled: true, expecting: runtimeToken, context: Self.context, claim: .neverRevoked)
            XCTAssertTrue(isBusy(load), "round \(round): a load made while the slot is held is refused as busy")
            XCTAssertTrue(isBusy(preferences), "round \(round): a commit made while the slot is held is refused as busy")
            XCTAssertTrue(isBusy(coupled), "round \(round): a coupled commit made while the slot is held is refused as busy")
            XCTAssertTrue(isBusy(launch), "round \(round): a launch-at-login commit made while the slot is held is refused as busy")
            XCTAssertTrue(isBusy(dns), "round \(round): a DNS lifecycle commit made while the slot is held is refused as busy")
        }
        XCTAssertEqual(fixture.access.observations.count, loggedWhileHeld, "refused calls make no read or write, so no I/O is queued")
        XCTAssertTrue(store.isBusy, "refusals do not clear the slot")

        // A cancelled caller only detaches its wait. The worker's read is still in flight, so the slot stays held until it returns.
        held.cancel()
        XCTAssertTrue(store.isBusy, "a cancelled caller does not release the slot while the worker is still in flight")
        let afterCancel = await store.load(context: Self.context)
        XCTAssertTrue(isBusy(afterCancel), "a load after the cancellation is still refused as busy")
        gated.releaseWorker()
        let heldAdmission = await held.value
        // The awaited call has returned, so the queued read is finished and nothing this fixture started is in flight.
        fixture.ownedWorkQuiesced = true
        guard case .admitted = heldAdmission else { return XCTFail("the held load was not admitted") }
        XCTAssertFalse(store.isBusy, "the slot is released when the held call returns")
        XCTAssertNotNil(store.baselineToken(for: .preferences))
    }

    /// A platform write whose read-back cannot be classified is unknown. The platform is not verified, so the runtime write is held, and the
    /// runtime file keeps its bytes (decision 0025).
    func testAnUnknownPlatformWriteHoldsTheRuntimeWrite() async throws {
        let fixture = try Fixture(runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.scheduleWrites([.init(landing: .lands, editAfterWrite: .replace(Data("other".utf8)))])
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(result.platform), "unknown")
        XCTAssertEqual(describe(result.runtime), "notAttempted(heldBehindPlatform)")
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), fixture.seededRuntime)
    }

    /// A platform write that lands and a runtime write that fails is a partial result. Each file reports its own outcome, and nothing rolls back
    /// or retries.
    func testAPartialCommitReportsEachFileSeparately() async throws {
        let fixture = try Fixture(runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.scheduleWrites([.init(landing: .lands), .init(landing: .failsBeforeLanding(errno: 28))])
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(result.platform), "persisted")
        guard case .notPersisted(.writeFailed(errno: 28)) = result.runtime else {
            return XCTFail("the runtime reports its own failure, got \(describe(result.runtime))")
        }
        XCTAssertNotNil(fixture.access.storedBytes(at: fixture.plan.platformConfig.path))
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), fixture.seededRuntime)
    }

    /// A finite matrix over the coupled commit's faults. Each row scripts the platform write and the runtime write, and it names what the
    /// store must report, what each file must hold, and whether each baseline still holds a token. A platform that does not verify holds the
    /// runtime write. Nothing rolls back, and nothing retries.
    func testTheCoupledCommitReportsEachFaultAndHoldsTheRuntimeBehindAnUnverifiedPlatform() async throws {
        let defaults = GenericDefaults.shared.makeConfig()
        var renamed = defaults
        renamed.profileName = "Renamed"
        let seededRuntime = try ProxyConfigPersistence.stagedFileData(for: defaults)
        let renamedRuntime = try ProxyConfigPersistence.stagedFileData(for: renamed)
        let platformDefaults = try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        let externalPlatform = Data("{\"launchAtLogin\":true}".utf8)
        let other = Data("other".utf8)
        let lands = FakeStateFileAccess.WriteScript(landing: .lands)

        struct Row {
            let name: String
            let platformWrite: FakeStateFileAccess.WriteScript
            let runtimeWrite: FakeStateFileAccess.WriteScript
            let changePlatformFirst: Bool
            let platform: String
            let runtime: String
            let writes: Int
            let platformToken: Bool
            let runtimeToken: Bool
            let platformBytes: Data?
            let runtimeBytes: Data?
        }
        let rows = [
            Row(name: "both verify", platformWrite: lands, runtimeWrite: lands, changePlatformFirst: false,
                platform: "persisted", runtime: "persisted", writes: 2, platformToken: true, runtimeToken: true,
                platformBytes: platformDefaults, runtimeBytes: renamedRuntime),
            Row(name: "platform write fails before landing", platformWrite: .init(landing: .failsBeforeLanding(errno: 5)), runtimeWrite: lands,
                changePlatformFirst: false, platform: "notPersisted", runtime: "notAttempted(heldBehindPlatform)", writes: 1,
                platformToken: true, runtimeToken: true, platformBytes: nil, runtimeBytes: seededRuntime),
            Row(name: "platform read-back unknown", platformWrite: .init(landing: .lands, editAfterWrite: .replace(other)), runtimeWrite: lands,
                changePlatformFirst: false, platform: "unknown", runtime: "notAttempted(heldBehindPlatform)", writes: 1,
                platformToken: false, runtimeToken: true, platformBytes: other, runtimeBytes: seededRuntime),
            Row(name: "platform changed before the check", platformWrite: lands, runtimeWrite: lands, changePlatformFirst: true,
                platform: "conflict", runtime: "notAttempted(heldBehindPlatform)", writes: 0,
                platformToken: false, runtimeToken: true, platformBytes: externalPlatform, runtimeBytes: seededRuntime),
            Row(name: "runtime write fails before landing", platformWrite: lands, runtimeWrite: .init(landing: .failsBeforeLanding(errno: 28)),
                changePlatformFirst: false, platform: "persisted", runtime: "notPersisted", writes: 2,
                platformToken: true, runtimeToken: true, platformBytes: platformDefaults, runtimeBytes: seededRuntime),
            Row(name: "runtime read-back unknown", platformWrite: lands,
                runtimeWrite: .init(landing: .lands, editAfterWrite: .replace(other)),
                changePlatformFirst: false, platform: "persisted", runtime: "unknown", writes: 2,
                platformToken: true, runtimeToken: false, platformBytes: platformDefaults, runtimeBytes: other),
            Row(name: "runtime lands and reports an error", platformWrite: lands, runtimeWrite: .init(landing: .landsThenFails(errno: 5)),
                changePlatformFirst: false, platform: "persisted", runtime: "persisted", writes: 2,
                platformToken: true, runtimeToken: true, platformBytes: platformDefaults, runtimeBytes: renamedRuntime),
        ]

        for row in rows {
            let fixture = try Fixture(runtime: seededRuntime, platform: row.changePlatformFirst ? platformDefaults : nil)
            defer { fixture.close() }
            guard await adoptedLoad(fixture) != nil else { continue }
            if row.changePlatformFirst {
                fixture.access.externalEdit(.replace(externalPlatform), at: fixture.plan.platformConfig.path)
            }
            fixture.access.scheduleWrites([row.platformWrite, row.runtimeWrite])
            let tokens = ConfigurationSlots(
                runtime: fixture.store.baselineToken(for: .runtime),
                platform: fixture.store.baselineToken(for: .platform),
                preferences: nil
            )
            guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
                return XCTFail("the commit was not admitted, row \(row.name)")
            }
            let label = "row \(row.name)"
            XCTAssertEqual(describe(result.platform), row.platform, label)
            XCTAssertEqual(describe(result.runtime), row.runtime, label)
            XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), row.platformBytes, label)
            XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), row.runtimeBytes, label)
            XCTAssertEqual(fixture.store.baselineToken(for: .platform) != nil, row.platformToken, label)
            XCTAssertEqual(fixture.store.baselineToken(for: .runtime) != nil, row.runtimeToken, label)
            XCTAssertEqual(fixture.access.observations.filter { if case .write = $0 { true } else { false } }.count, row.writes, label)
        }
    }

    /// A refused decode reports the loader's fixed text, and no byte of the refused input reaches the outcome.
    func testARefusedRuntimeReasonNamesNoInputByte() async throws {
        let fixture = try Fixture(runtime: Data("PRIVATE-MARKER not json".utf8))
        defer { fixture.close() }
        guard case .admitted(let report) = await fixture.store.load(context: Self.context),
              case .refused(.invalidContent(let reason)) = report.outcome else {
            return XCTFail("the refused runtime was not reported")
        }
        XCTAssertEqual(reason.rawValue, "The configuration is not valid Conduit JSON.")
        XCTAssertFalse("\(report.outcome)".contains("PRIVATE-MARKER"))
    }

    /// The staged defaults runtime file with extra top-level keys, so a witness can seed a legacy value of the wrong kind.
    private func runtimeFile(adding extra: [String: Any]) throws -> Data {
        let staged = try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig())
        guard var object = try JSONSerialization.jsonObject(with: staged) as? [String: Any] else {
            throw SeedNotAnObject()
        }
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// A canonical runtime file with no legacy platform or preferences keys, and no sidecars, adopts the defaults with no fallback and no
    /// warning. Each absent legacy key reads as its default, so the migration stays pending (decisions 0023 and 0026). A runtime file that
    /// carries valid legacy values adopts those instead. This witness does not cover that case.
    func testAMissingSidecarBesideAPresentRuntimeFileAdoptsDefaultsWithNoWarning() async throws {
        let fixture = try Fixture(runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()))
        defer { fixture.close() }
        guard let loaded = await adoptedLoad(fixture) else { return }
        XCTAssertEqual(loaded.platform, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(fixture.store.values?.preferences, AppPreferences())
        XCTAssertEqual(fixture.store.values?.platform, PlatformIntegrationConfig())
        XCTAssertNotNil(fixture.store.baselineToken(for: .preferences))
        XCTAssertTrue(fixture.access.observations.allSatisfy { if case .read = $0 { true } else { false } }, "the open writes nothing")
    }

    /// A legacy preferences value of the wrong kind refuses that component alone. The typed fallback is reported, the defaults are used, and
    /// nothing is pending, because a refused value is not a migration. The runtime file itself still loads.
    func testAMalformedLegacyPreferencesValueFallsBackWithItsTypedWarning() async throws {
        let fixture = try Fixture(runtime: try runtimeFile(adding: ["showMenuBarIcon": "bad"]))
        defer { fixture.close() }
        guard let loaded = await adoptedLoad(fixture) else { return }
        XCTAssertEqual(loaded.runtime, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(
            loaded.preferences,
            ConfigurationComponentLoad(present: false, migrationPending: false, fallback: .legacyPreferencesRefusedUsingDefaults)
        )
        XCTAssertEqual(fixture.store.values?.preferences, AppPreferences())
    }

    /// A legacy platform value of the wrong kind is the platform's own fallback, and it leaves the preferences component untouched.
    func testAMalformedLegacyPlatformValueFallsBackWithItsTypedWarning() async throws {
        let fixture = try Fixture(runtime: try runtimeFile(adding: ["launchAtLogin": "bad"]))
        defer { fixture.close() }
        guard let loaded = await adoptedLoad(fixture) else { return }
        XCTAssertEqual(
            loaded.platform,
            ConfigurationComponentLoad(present: false, migrationPending: false, fallback: .legacyPlatformRefusedUsingDefaults)
        )
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(fixture.store.values?.platform, PlatformIntegrationConfig())
    }

    /// A failed runtime write over a larger prior file reads the whole prior back, so the result is verified not-persisted, not unknown. The
    /// prior is the defaults followed by 8 KiB of whitespace, and the candidate is shorter than it.
    func testAFailedRuntimeWriteOverALargerPriorReadsTheWholePriorBack() async throws {
        let larger = try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()) + Data(repeating: 0x20, count: 8 * 1024)
        let fixture = try Fixture(runtime: larger)
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.scheduleWrites([.init(landing: .lands), .init(landing: .failsBeforeLanding(errno: 28))])
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(renamed, PlatformIntegrationConfig(), expecting: tokens, context: Self.context) else {
            return XCTFail("the commit was not admitted")
        }
        XCTAssertEqual(describe(result.platform), "persisted")
        guard case .notPersisted(.writeFailed(errno: 28)) = result.runtime else {
            return XCTFail("the runtime is verified not persisted over its prior, got \(describe(result.runtime))")
        }
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), larger, "the prior bytes are unchanged")
        XCTAssertNotNil(fixture.store.baselineToken(for: .runtime), "a verified not-persisted write keeps the runtime baseline")
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 1)
    }

    // MARK: - Per-component authority

    /// A refused runtime keeps its own reason, and a platform file that is authorized is held behind it. Nothing is written.
    func testAnAuthorizedPlatformIsHeldBehindARefusedRuntimeWithItsOwnReason() async throws {
        let fixture = try Fixture(platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        fixture.access.externalEdit(.replace(try ProxyConfigPersistence.stagedFileData(for: renamed)), at: fixture.plan.config.path)
        // A no-op commit verifies the platform and finds the runtime file changed, which latches the runtime baseline. The runtime is then
        // refused while the platform stays valid.
        guard case .runtime = await latchByNoOpCommit(fixture) else { return XCTFail("the no-op commit did not latch the runtime") }
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.runtime), "notAttempted(noAuthoritativeBaseline)")
        XCTAssertEqual(describe(result.platform), "notAttempted(heldBehindRuntime)")
        XCTAssertEqual(writes(fixture, at: fixture.plan.platformConfig.path), 0)
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
    }

    /// The reverse: a refused platform keeps its own reason, and an authorized runtime is held behind it.
    func testAnAuthorizedRuntimeIsHeldBehindARefusedPlatformWithItsOwnReason() async throws {
        let fixture = try Fixture(platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        fixture.access.externalEdit(.replace(Data("{\"launchAtLogin\":true}".utf8)), at: fixture.plan.platformConfig.path)
        guard case .platform = await latchByNoOpCommit(fixture) else { return XCTFail("the no-op commit did not latch the platform") }
        let tokens = ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.platform), "notAttempted(noAuthoritativeBaseline)")
        XCTAssertEqual(describe(result.runtime), "notAttempted(heldBehindPlatform)")
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
    }

    /// Both refused, each with its own reason: the runtime has no authority, and the platform token names no baseline it holds.
    func testBothRefusedComponentsKeepTheirOwnDifferentReasons() async throws {
        let fixture = try Fixture(platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()))
        defer { fixture.close() }
        guard await adoptedLoad(fixture) != nil else { return }
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        fixture.access.externalEdit(.replace(try ProxyConfigPersistence.stagedFileData(for: renamed)), at: fixture.plan.config.path)
        // A no-op commit at valid tokens finds the changed runtime file, which latches its baseline: the runtime now has no authority.
        guard case .runtime = await latchByNoOpCommit(fixture) else { return XCTFail("the no-op commit did not latch the runtime") }
        // The runtime is latched (no baseline), and the platform token is missing while the platform still holds its baseline (a mismatch).
        let admission = await fixture.store.commitRuntimeAndPlatform(
            GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(),
            expecting: ConfigurationSlots(runtime: nil, platform: nil, preferences: nil), context: Self.context
        )
        guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(describe(result.runtime), "notAttempted(noAuthoritativeBaseline)")
        XCTAssertEqual(describe(result.platform), "notAttempted(baselineMismatch)")
        XCTAssertEqual(writes(fixture, at: fixture.plan.platformConfig.path), 0)
    }

    // MARK: - Unknown fields

    /// A valid runtime file with an unknown top-level field is accepted on read (decision 0022). An external edit that adds one changes the
    /// bytes, so an ordinary save conflicts and latches the baseline until a reload. The file is kept as it was edited. With the platform
    /// sidecar present, the runtime write's own pre-read reports the conflict. With it missing, the platform's first write checks the same
    /// runtime bytes as its source and holds first, so the runtime write is held behind it. Both latch the runtime file until a reload.
    func testAValidUnknownFieldEditToTheRuntimeFileConflictsAndLatchesUntilAReload() async throws {
        let platformCases: [(platform: Data?, runtime: ConfigurationWriteOutcome, platformOutcome: String)] = [
            (try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()), .conflict, "unchanged"),
            (nil, .notAttempted(.heldBehindPlatform), "notAttempted(sourceChanged)"),
        ]
        for row in platformCases {
            let fixture = try Fixture(
                runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()),
                platform: row.platform
            )
            defer { fixture.close() }
            guard await adoptedLoad(fixture) != nil else { return }
            let tokenBefore = fixture.store.baselineToken(for: .runtime)
            let edited = try runtimeFile(adding: ["futureField": "accepted-and-skipped"])
            fixture.access.externalEdit(.replace(edited), at: fixture.plan.config.path)

            let tokens = ConfigurationSlots(runtime: tokenBefore, platform: fixture.store.baselineToken(for: .platform), preferences: nil)
            let admission = await fixture.store.commitRuntimeAndPlatform(
                GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(), expecting: tokens, context: Self.context
            )
            guard case .admitted(let result) = admission else { return XCTFail("the commit was not admitted") }
            XCTAssertEqual(result.runtime, row.runtime)
            XCTAssertEqual(describe(result.platform), row.platformOutcome)
            XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), edited, "the edited file is kept")
            XCTAssertNil(fixture.store.baselineToken(for: .runtime), "the changed runtime bytes latch the runtime baseline")

            guard let reloaded = await adoptedLoad(fixture) else { return }
            XCTAssertEqual(reloaded.runtime, ConfigurationComponentLoad(present: true, migrationPending: false))
            XCTAssertNotEqual(fixture.store.baselineToken(for: .runtime), tokenBefore, "a reload issues a newer baseline")
        }
    }

    // MARK: - Bounded model over runtime and platform

    /// A bounded model of the runtime and platform files through the coupled commit, the no-op commit, reload and saved tokens. The model holds
    /// each file's external variant, the baseline the store last adopted, the latch, the version, and the parsed value it last adopted or
    /// wrote. Variants: the runtime defaults, the renamed runtime, and the defaults with trailing whitespace; the platform defaults and the
    /// defaults with trailing whitespace. A missing platform sidecar takes the runtime variant the last adopted reload saw as its source, and
    /// its first write is held when the runtime bytes differ from it. Each step is a model decision, and each store result must match it. The trace of each seed is part
    /// of the failure label, so a counterexample replays. It has no read or write faults, which the focused tests above cover. It does not explore interleavings.
    func testABoundedModelOverRuntimeAndPlatformMatchesTheStoreForReplayableSeeds() async throws {
        let defaults = GenericDefaults.shared.makeConfig()
        var renamed = defaults
        renamed.profileName = "Renamed"
        let whitespace = Data("\n".utf8)
        let runtimeFiles = [
            try ProxyConfigPersistence.stagedFileData(for: defaults),
            try ProxyConfigPersistence.stagedFileData(for: renamed),
            try ProxyConfigPersistence.stagedFileData(for: defaults) + whitespace,
        ]
        let runtimeVariantValue = [0, 1, 0]
        let platformFiles = [
            try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()),
            try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig()) + whitespace,
        ]
        let stepsPerSeed = 24
        let components: [ConfigurationComponent] = [.runtime, .platform]
        // Every result the model expected, across all seeds. The seeds must reach each outcome class, or the run proves less than it claims.
        var covered = Set<String>()

        for seed in [UInt64(1), 7, 42, 99, 123, 256, 1024, 2026] {
            var source = ReplaySource(seed: seed)
            let fixture = try Fixture(runtime: runtimeFiles[0])
            defer { fixture.close() }
            // Per component (runtime, platform): the external variant (nil is missing), the adopted baseline variant, and the latch.
            var external: [Int?] = [0, nil]
            var baseline: [Int?] = [nil, nil]
            var latched = [false, false]
            var version = [0, 0]
            var modelValue = [0, 0]
            var adopted = false
            var savedVersion: [Int?] = [nil, nil]
            // The runtime variant (nil is missing) a missing platform sidecar takes its values from: the one the last adopted reload saw.
            // It is read only while the adopted platform is missing, and the platform's first write checks it before anything else.
            var platformSource: Int?
            var tokens = ConfigurationSlots<ConfigurationBaselineToken?>(runtime: nil, platform: nil, preferences: nil)
            var trace: [String] = []

            /// The reason the store must refuse a token-bearing operation for one component, or nil when its authority holds.
            func authorityRefusal(_ index: Int) -> String? {
                if !adopted || latched[index] { return "notAttempted(noAuthoritativeBaseline)" }
                if savedVersion[index] == nil || savedVersion[index] != version[index] { return "notAttempted(baselineMismatch)" }
                return nil
            }

            /// Saves the store's current tokens with the model's version. A token is valid only while the version it was saved at still holds.
            func snapshot() {
                tokens = ConfigurationSlots(
                    runtime: fixture.store.baselineToken(for: .runtime),
                    platform: fixture.store.baselineToken(for: .platform),
                    preferences: nil
                )
                savedVersion = (0..<2).map { index -> Int? in adopted && !latched[index] ? version[index] : nil }
            }

            // Every seed opens with a fixed scenario: the first load adopts the platform file as missing, and a no-op commit writes it. The
            // platform then disappears (op 6), and the fresh-token commit holds the runtime write behind that conflict. The reload re-adopts
            // the missing platform and a no-op commit writes it again, so the runtime probe below leaves the platform present and authorized.
            // Then a runtime rename, a no-op commit that verifies the platform and latches the runtime, and a fresh-token commit reach
            // heldBehindRuntime. The source probe (op 8) follows, so `sourceChanged` is reached on every seed too. The random steps follow.
            // Those outcomes are therefore reached on every seed, not only by chance.
            var pending: [Int] = [1, 2, 4, 6, 3, 1, 4, 7, 4, 3, 8]
            var forceFresh = true
            var executedSteps = 0
            for step in 0..<stepsPerSeed {
                fixture.access.clearObservations()
                let label = "seed \(seed), step \(step), trace \(trace.joined(separator: " ; "))"
                // Each iteration runs one operation: a queued one from a probe, or a random one.
                let op = pending.isEmpty ? source.next(6) : pending.removeFirst()
                switch op {
                case 0:
                    // An external edit to one file: removal, or one of its variants.
                    let index = source.next(2)
                    let choice = source.next(index == 0 ? 4 : 3) - 1
                    external[index] = choice < 0 ? nil : choice
                    let path = index == 0 ? fixture.plan.config.path : fixture.plan.platformConfig.path
                    let bytes = index == 0 ? runtimeFiles : platformFiles
                    let edit: FakeStateFileAccess.ExternalEdit
                    if let variant = external[index] {
                        edit = .replace(bytes[variant])
                    } else {
                        edit = .remove
                    }
                    fixture.access.externalEdit(edit, at: path)
                    trace.append("edit \(components[index]) \(external[index].map { String($0) } ?? "missing")")

                case 1:
                    trace.append("reload")
                    let refused = external[0] == nil && external[1] != nil
                    guard case .admitted(let report) = await fixture.store.load(context: Self.context) else {
                        return XCTFail("the reload was not admitted, \(label)")
                    }
                    if refused {
                        latched = [true, true]
                    } else {
                        for index in 0..<2 {
                            if !adopted || latched[index] || baseline[index] != external[index] { version[index] += 1 }
                            baseline[index] = external[index]
                            latched[index] = false
                        }
                        modelValue = [external[0].map { runtimeVariantValue[$0] } ?? 0, 0]
                        adopted = true
                        platformSource = external[0]
                    }
                    if case .adopted = report.outcome {
                        XCTAssertFalse(refused, label)
                    } else {
                        XCTAssertTrue(refused, label)
                    }

                case 2:
                    trace.append("snapshot tokens")
                    snapshot()

                case 3, 4:
                    // Half the commits take fresh tokens, so most of them are authorized and reach the coupled path. The rest keep their
                    // saved tokens, which go stale as soon as a version moves. Op 4 is the no-op commit: the store's current runtime value
                    // under fresh tokens, which verifies each present file and latches a changed one without writing it.
                    let proposal: Int
                    if op == 4 {
                        trace.append("fresh tokens")
                        snapshot()
                        proposal = modelValue[0]
                        trace.append("commit current runtime-value \(proposal)")
                    } else {
                        if forceFresh || source.next(2) == 0 {
                            trace.append("fresh tokens")
                            snapshot()
                        }
                        forceFresh = false
                        proposal = source.next(2)
                        trace.append("commit runtime-value \(proposal)")
                    }
                    let expectRuntime: String
                    let expectPlatform: String
                    // Each component's authority is decided on its own, as the store decides it. A refused file keeps its own reason. An
                    // authorized file is held behind the refused one, so the two never share a cause. No state changes on any refusal.
                    if authorityRefusal(0) != nil || authorityRefusal(1) != nil {
                        expectRuntime = authorityRefusal(0) ?? "notAttempted(heldBehindPlatform)"
                        expectPlatform = authorityRefusal(1) ?? "notAttempted(heldBehindRuntime)"
                    } else {
                        // The platform file first. A missing one checks its runtime source before its own pre-read, so changed runtime
                        // bytes hold it and latch both files. Then a changed identity conflicts, a present file is verified, and a missing
                        // file is written.
                        if baseline[1] == nil && external[0] != platformSource {
                            latched = [true, true]
                            expectPlatform = "notAttempted(sourceChanged)"
                            expectRuntime = "notAttempted(heldBehindPlatform)"
                        } else if external[1] != baseline[1] {
                            latched[1] = true
                            expectPlatform = "conflict"
                            expectRuntime = "notAttempted(heldBehindPlatform)"
                        } else {
                            if external[1] == nil {
                                external[1] = 0
                                baseline[1] = 0
                                version[1] += 1
                                expectPlatform = "persisted"
                            } else {
                                expectPlatform = "unchanged"
                            }
                            if external[0] != baseline[0] {
                                latched[0] = true
                                expectRuntime = "conflict"
                            } else if external[0] != nil && modelValue[0] == proposal {
                                expectRuntime = "unchanged"
                            } else {
                                let variant = proposal == 1 ? 1 : 0
                                external[0] = variant
                                baseline[0] = variant
                                version[0] += 1
                                modelValue[0] = proposal
                                expectRuntime = "persisted"
                            }
                        }
                    }
                    let candidate = proposal == 1 ? renamed : defaults
                    guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(
                        candidate, PlatformIntegrationConfig(), expecting: tokens, context: Self.context
                    ) else { return XCTFail("the commit was not admitted, \(label)") }
                    XCTAssertEqual(describe(result.runtime), expectRuntime, label)
                    XCTAssertEqual(describe(result.platform), expectPlatform, label)
                    covered.formUnion([expectRuntime, expectPlatform])
                    XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), external[0].map { runtimeFiles[$0] }, label)

                case 5:
                    // A probe. Random steps rarely reach a platform conflict while the runtime is still authorized, so the probe restores the
                    // runtime file, reloads, changes the platform identity, and commits with fresh tokens, in that order.
                    trace.append("probe")
                    external[0] = 0
                    fixture.access.externalEdit(.replace(runtimeFiles[0]), at: fixture.plan.config.path)
                    pending = [1, 6, 3]
                    forceFresh = true

                case 6:
                    // The platform identity changes from the adopted baseline, so the next platform check sees a conflict.
                    external[1] = baseline[1] == nil ? 0 : nil
                    let edit: FakeStateFileAccess.ExternalEdit = external[1] == nil ? .remove : .replace(platformFiles[0])
                    fixture.access.externalEdit(edit, at: fixture.plan.platformConfig.path)
                    trace.append("platform identity \(external[1].map { String($0) } ?? "missing")")

                case 7:
                    // The runtime identity changes from the adopted baseline, and the next no-op commit latches it. The fresh-token commit then
                    // refuses the runtime while the platform stays authorized, so the platform is held behind the runtime (`heldBehindRuntime`).
                    external[0] = 1
                    fixture.access.externalEdit(.replace(runtimeFiles[1]), at: fixture.plan.config.path)
                    trace.append("runtime identity renamed")
                    forceFresh = true

                case 8:
                    // A source probe: the runtime file is restored and the platform sidecar removed, a reload adopts the missing sidecar
                    // with the restored runtime bytes as its source, the runtime is renamed outside the store, and a fresh-token commit
                    // reaches the platform's source check (`sourceChanged`).
                    trace.append("source probe")
                    external = [0, nil]
                    fixture.access.externalEdit(.replace(runtimeFiles[0]), at: fixture.plan.config.path)
                    fixture.access.externalEdit(.remove, at: fixture.plan.platformConfig.path)
                    pending = [1, 7, 3]
                    forceFresh = true

                default:
                    preconditionFailure("the model has no operation \(op)")
                }
                XCTAssertLessThanOrEqual(fixture.access.observations.count, FakeStateFileAccess.observationCapacity, label)
                executedSteps += 1
            }
            // The trace keeps every operation as replay evidence, so it is longer than the step budget. The budget counts loop iterations.
            XCTAssertEqual(executedSteps, stepsPerSeed, "the seed ran its full budget, seed \(seed)")
        }
        let required: Set<String> = [
            "persisted", "unchanged", "conflict", "notAttempted(noAuthoritativeBaseline)",
            "notAttempted(baselineMismatch)", "notAttempted(heldBehindPlatform)", "notAttempted(heldBehindRuntime)",
            "notAttempted(sourceChanged)",
        ]
        XCTAssertTrue(covered.isSuperset(of: required), "the seeds did not reach every outcome class; missing \(required.subtracting(covered).sorted())")
    }

    // MARK: - Bounded model

    /// A replay source for the model. Each seed produces the same operations on every run.
    private struct ReplaySource {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &* 2_654_435_761 &+ 1
        }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// A bounded model of the preferences file. It tracks the external bytes, the baseline the store last adopted, whether an observed
    /// change has latched that baseline, and the store's file version. It decides each result from those alone, following decisions 0027
    /// and 0021. It also tracks the runtime file the missing sidecar takes its values from: its variant on disk (the defaults, the defaults
    /// with a legacy `showMenuBarIcon: false`, or missing), and the variant the store last adopted as the sidecar's source. A reload that
    /// changes the missing sidecar's effective value takes a newer version, and a first write is held when the runtime variant on disk is
    /// not the source. It is a model of the rules, not the store's code. Each segment starts a new store on the same external bytes and runs
    /// five operations, and each step clears the fake's 16-call log. Interleavings are covered separately.
    func testABoundedModelOverPreferencesMatchesTheStoreForReplayableSeeds() async throws {
        // The runtime variants: the defaults, and the defaults carrying a legacy preference value that differs from the default.
        let runtimeVariants = [
            try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()),
            try runtimeFile(adding: ["showMenuBarIcon": false]),
        ]
        // Every outcome class the preferences model can reach, across all seeds. The seeds must reach each one, or the run proves less.
        var reached = Set<String>()
        var refusedLoads = 0
        // Reloads where only the missing sidecar's value moved: its absence is the same, and its version still advances.
        var valueMovedReloads = 0
        for seed in [UInt64(1), 7, 42, 99, 123, 256, 1024, 2026] {
            var source = ReplaySource(seed: seed)
            let variants = [try preferenceBytes(showMenuBarIcon: true), try preferenceBytes(showMenuBarIcon: false)]
            var external: Data? = variants[0]
            // The parsed showMenuBarIcon of the external bytes: true for the defaults and their whitespace variant, false for the other value.
            var externalShows: Bool? = true
            var trace: [String] = []
            for segment in 0..<3 {
                let fixture = try Fixture(preferences: external)
                defer { fixture.close() }
                var adopted = false
                var latched = false
                var modelBaseline: Data?
                var modelVersion: UInt64 = 0
                // The runtime variant on disk (nil is missing). A segment starts with the runtime file the fixture seeded: the defaults
                // beside a sidecar, and none beside a missing one.
                var runtimeVariant: Int? = fixture.seededRuntime != nil ? 0 : nil
                // The runtime variant the store last adopted as the missing sidecar's source, and the showMenuBarIcon it last adopted.
                var modelSource: Int?
                var adoptedShows = true
                /// The showMenuBarIcon a load adopts: the sidecar's own value, or the runtime file's legacy value when the sidecar is missing.
                func loadedShows() -> Bool {
                    external == nil ? runtimeVariant != 1 : externalShows != false
                }
                func adoptModel() {
                    let valueMoved = external == nil && adoptedShows != loadedShows()
                    if !adopted || latched || modelBaseline != external || valueMoved { modelVersion += 1 }
                    if adopted, !latched, modelBaseline == external, valueMoved { valueMovedReloads += 1 }
                    modelBaseline = external
                    modelSource = runtimeVariant
                    adoptedShows = loadedShows()
                    adopted = true
                    latched = false
                }
                guard await adoptedLoad(fixture) != nil else { return }
                adoptModel()
                // A token saved at the start of a segment. It goes stale once the version moves, and it is never valid in another segment.
                let savedToken = fixture.store.baselineToken(for: .preferences)

                for step in 0..<5 {
                    let label = "seed \(seed), segment \(segment), step \(step), trace \(trace.joined(separator: " ; "))"
                    // Each step has its own call log, so one step's calls never count against the fake's 16-call budget.
                    fixture.access.clearObservations()
                    let token = fixture.store.baselineToken(for: .preferences)
                    // Each seed opens with the value probe, so a reload where only the missing sidecar's value moved is reached on every seed.
                    let op = segment == 0 && step == 0 ? 5 : source.next(5)
                    switch op {
                    case 5:
                        // The value probe: the sidecar is removed and the runtime restored to the defaults, a reload adopts the missing
                        // sidecar, the runtime gains the legacy value outside the store, and a second reload adopts that value.
                        trace.append("value probe")
                        external = nil
                        externalShows = nil
                        fixture.access.externalEdit(.remove, at: fixture.plan.preferences.path)
                        for variant in [0, 1] {
                            runtimeVariant = variant
                            fixture.access.externalEdit(.replace(runtimeVariants[variant]), at: fixture.plan.config.path)
                            guard await adoptedLoad(fixture) != nil else { return XCTFail("the probe reload was not adopted, \(label)") }
                            adoptModel()
                        }
                        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, label)
                        XCTAssertEqual(fixture.store.baselineToken(for: .preferences)?.version, modelVersion, label)
                    case 4:
                        // A runtime edit with no reload: the defaults, the legacy value, or removal. Beside a missing sidecar it changes the
                        // source the next first write checks, and the next reload's value.
                        let choice = source.next(3)
                        runtimeVariant = choice < 2 ? choice : nil
                        if let runtimeVariant {
                            fixture.access.externalEdit(.replace(runtimeVariants[runtimeVariant]), at: fixture.plan.config.path)
                        } else {
                            fixture.access.externalEdit(.remove, at: fixture.plan.config.path)
                        }
                        trace.append("edit runtime \(runtimeVariant.map { $0 == 1 ? "legacy" : "defaults" } ?? "missing")")
                    case 0:
                        // An external edit: removal, a value, the other value, or the same value with trailing whitespace.
                        switch source.next(4) {
                        case 0:
                            external = nil
                            fixture.access.externalEdit(.remove, at: fixture.plan.preferences.path)
                        case 1:
                            external = variants[0]
                            fixture.access.externalEdit(.replace(variants[0]), at: fixture.plan.preferences.path)
                        case 2:
                            external = variants[1]
                            fixture.access.externalEdit(.replace(variants[1]), at: fixture.plan.preferences.path)
                        default:
                            external = variants[0] + Data("\n".utf8)
                            fixture.access.externalEdit(.replace(variants[0] + Data("\n".utf8)), at: fixture.plan.preferences.path)
                        }
                        externalShows = external.map { $0 != variants[1] }
                        trace.append("edit prefs \(external == nil ? "missing" : (externalShows == true ? "shows" : "other"))")
                    case 1:
                        // The startup gate: a missing runtime file is refused while a preferences sidecar exists, and a refusal latches every
                        // component until a later load succeeds. A missing sidecar beside a present runtime file adopts the defaults with no
                        // warning (the witness below). The model removes or restores the runtime file itself, so the refusal is reached.
                        if source.next(3) == 0 {
                            runtimeVariant = nil
                            fixture.access.externalEdit(.remove, at: fixture.plan.config.path)
                        } else if runtimeVariant == nil {
                            runtimeVariant = 0
                            fixture.access.externalEdit(.replace(runtimeVariants[0]), at: fixture.plan.config.path)
                        }
                        let refused = runtimeVariant == nil && external != nil
                        trace.append("reload runtime \(runtimeVariant == nil ? "missing" : "present")")
                        guard case .admitted(let report) = await fixture.store.load(context: Self.context) else {
                            return XCTFail("the reload was not admitted, \(label)")
                        }
                        var isRefused = false
                        if case .refused = report.outcome { isRefused = true }
                        XCTAssertEqual(isRefused, refused, label)
                        if refused {
                            latched = true
                            refusedLoads += 1
                        } else {
                            adoptModel()
                        }
                    case 2, 3:
                        // Op 3 is the no-op commit: the value the store last adopted or wrote, under the current token. It verifies a present
                        // file without writing it and latches a changed one, or one that appeared. For a file still missing it would be a
                        // first write, which op 2 covers, so the step leaves that file as it is.
                        if op == 3, !latched, modelBaseline == nil, external == nil {
                            trace.append("no-op commit skipped: missing")
                            break
                        }
                        var proposed = AppPreferences()
                        let presented: ConfigurationBaselineToken?
                        if op == 3 {
                            proposed.showMenuBarIcon = adoptedShows
                            presented = token
                        } else {
                            proposed.showMenuBarIcon = source.next(2) == 0
                            // One commit in four presents the segment's saved token, which goes stale once the version moves.
                            presented = source.next(4) == 0 ? savedToken : token
                        }
                        let presentedValid = presented?.version == modelVersion
                        let staged = try AppPreferencesPersistence.stagedData(for: proposed)
                        let expected: String
                        if latched {
                            expected = "notAttempted(noAuthoritativeBaseline)"
                        } else if !presentedValid {
                            expected = "notAttempted(baselineMismatch)"
                        } else if modelBaseline == nil && runtimeVariant != modelSource {
                            // The adopted sidecar is missing, so its first write checks the runtime source before its own pre-read.
                            expected = "notAttempted(sourceChanged)"
                            latched = true
                        } else if external != modelBaseline {
                            expected = "conflict"
                            latched = true
                        } else if external != nil && externalShows == proposed.showMenuBarIcon {
                            // The parsed value is equal, so the present file is verified and never rewritten, whatever its formatting.
                            expected = "unchanged"
                        } else {
                            expected = "persisted"
                            modelBaseline = staged
                            external = staged
                            externalShows = proposed.showMenuBarIcon
                            adoptedShows = proposed.showMenuBarIcon
                            modelVersion += 1
                        }
                        trace.append("\(op == 3 ? "no-op " : "")commit prefs \(proposed.showMenuBarIcon ? "shows" : "other") \(presented == token ? "current" : "saved")")
                        guard case .admitted(let result) = await fixture.store.commitPreferences(proposed, expecting: presented, context: Self.context) else {
                            return XCTFail("the commit was not admitted, \(label)")
                        }
                        XCTAssertEqual(describe(result.preferences), expected, label)
                        reached.insert(expected)
                        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.preferences.path), external, label)
                    default:
                        preconditionFailure("the model has no operation \(op)")
                    }
                }
            }
        }
        // The seeds reach every class the model can produce for the preferences file, and at least one refused load. The refusal is the
        // runtime-missing case, which the store refuses at its own boundary (decision 0023).
        let required: Set<String> = [
            "persisted", "unchanged", "conflict",
            "notAttempted(noAuthoritativeBaseline)", "notAttempted(baselineMismatch)", "notAttempted(sourceChanged)",
        ]
        XCTAssertTrue(reached.isSuperset(of: required), "the seeds did not reach every outcome class; missing \(required.subtracting(reached).sorted())")
        XCTAssertGreaterThan(refusedLoads, 0, "the seeds reached the refused load")
        XCTAssertGreaterThan(valueMovedReloads, 0, "the seeds reached a reload where only the missing sidecar's value moved")
    }
}
