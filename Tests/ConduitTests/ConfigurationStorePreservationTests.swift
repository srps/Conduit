// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The preservation guard of the configuration store (decision 0026), and the loader parity it rests on. A runtime rewrite drops the legacy
/// preference values its file carries, so the store holds the rewrite until the preferences sidecar verifies in the same physical step. A
/// shadowed value (its sidecar exists) is guarded too, because the sidecar is the authority that a rewrite must not replace blindly. The
/// tests use the fake file access over a real lease, as `ConfigurationStoreTests` does.
///
/// Known limit, pinned by `testADeletionAfterTheGuardCheckIsNotExcluded`: a sidecar changed after its check and before the runtime bytes are
/// replaced is not excluded. The guard is not a multi-file atomic claim (decision 0027).
@MainActor
final class ConfigurationStorePreservationTests: XCTestCase {
    private struct SeedFailure: Error {}

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    /// The legacy preference values a runtime file carries: a non-default boolean and a URL, so both are checked after a reload.
    private func legacyValues() -> [String: Any] {
        ["showMenuBarIcon": false, "preferredBrowserTestURL": "https://example.test/check"]
    }

    /// The canonical defaults runtime file with extra top-level keys, so a witness can carry legacy values of any kind.
    private func legacyRuntime(_ extra: [String: Any]) throws -> Data {
        let staged = try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig())
        guard var object = try JSONSerialization.jsonObject(with: staged) as? [String: Any] else { throw SeedFailure() }
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The canonical defaults runtime file with raw members placed first, in the order given. A dictionary cannot hold a duplicate key, so a
    /// witness with duplicates splices its members into the staged bytes. The staged object is never empty, so its first byte is the `{`.
    private func rawLegacyRuntime(prefix: String) throws -> Data {
        let staged = try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig())
        guard staged.first == UInt8(ascii: "{") else { throw SeedFailure() }
        return Data("{\(prefix),".utf8) + staged.dropFirst()
    }

    private func preferenceBytes(showMenuBarIcon: Bool) throws -> Data {
        var preferences = AppPreferences()
        preferences.showMenuBarIcon = showMenuBarIcon
        return try AppPreferencesPersistence.stagedData(for: preferences)
    }

    private func renamedConfig() -> ProxyConfig {
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        return renamed
    }

    /// The runtime and platform tokens the store currently issues. The preferences token belongs to `commitPreferences`, not here.
    private func currentTokens(_ fixture: ConfigurationStoreTests.Fixture) -> ConfigurationSlots<ConfigurationBaselineToken?> {
        ConfigurationSlots(
            runtime: fixture.store.baselineToken(for: .runtime),
            platform: fixture.store.baselineToken(for: .platform),
            preferences: nil
        )
    }

    private func adopt(_ fixture: ConfigurationStoreTests.Fixture) async -> ConfigurationSlots<ConfigurationComponentLoad>? {
        guard case .admitted(let report) = await fixture.store.load(context: Self.context),
              case .adopted(let loaded) = report.outcome else {
            XCTFail("the load was not adopted")
            return nil
        }
        return loaded
    }

    private func commit(
        _ fixture: ConfigurationStoreTests.Fixture,
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig
    ) async -> RuntimePlatformCommitResult? {
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(
            runtime, platform, expecting: currentTokens(fixture), context: Self.context
        ) else {
            XCTFail("the commit was not admitted")
            return nil
        }
        return result
    }

    private func isPersisted(_ outcome: ConfigurationWriteOutcome) -> Bool {
        if case .persisted = outcome { true } else { false }
    }

    private func isUnchanged(_ outcome: ConfigurationWriteOutcome) -> Bool {
        if case .unchanged = outcome { true } else { false }
    }

    private func writes(_ fixture: ConfigurationStoreTests.Fixture, at path: String) -> Int {
        fixture.access.observations.filter { if case .write(let written, _) = $0 { written == path } else { false } }.count
    }

    /// The order of the physical calls since the last `clearObservations`, by file. Each phase clears the fake's log at its boundary, because
    /// one fixture's log holds only 16 calls. A phase is asserted before it is cleared, so no call is dropped unseen.
    private func phaseShape(_ fixture: ConfigurationStoreTests.Fixture) -> [String] {
        fixture.access.observations.map { observation in
            let file = switch observation {
            case .read(let path, _), .write(let path, _): fileName(path, in: fixture)
            }
            switch observation {
            case .read: return "read \(file)"
            case .write: return "write \(file)"
            }
        }
    }

    private func fileName(_ path: String, in fixture: ConfigurationStoreTests.Fixture) -> String {
        switch path {
        case fixture.plan.config.path: "runtime"
        case fixture.plan.platformConfig.path: "platform"
        case fixture.plan.preferences.path: "preferences"
        default: "other"
        }
    }

    // MARK: - Legacy values in the runtime file

    /// A canonical rewrite drops the legacy preferences, so it is held until the sidecar is saved and verified. The platform file is written
    /// first, and that partial save is reported as it is. After the explicit save, the retry persists, and a reload keeps the exact values.
    func testARuntimeRewriteHoldsUntilTheLegacyPreferencesAreSavedAndVerified() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
        defer { fixture.close() }
        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        let legacy = fixture.store.values?.preferences
        XCTAssertEqual(legacy?.showMenuBarIcon, false)
        let runtimeBytes = fixture.seededRuntime
        // Phase: the held commit. The load's three reads are cleared first, so the log holds only this phase.
        fixture.access.clearObservations()

        guard let held = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(held.platform), "the platform file verified first, and that save is reported")
        XCTAssertEqual(held.runtime, .notAttempted(.preservationHeld(.sidecarAbsent)))
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes, "the runtime bytes are preserved")
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        // The platform file's replacement, then the sidecar check, which is the last call: no runtime call follows it.
        XCTAssertEqual(phaseShape(fixture), ["read platform", "write platform", "read platform", "read preferences"])
        fixture.access.clearObservations()

        // The migration path is the explicit preferences save, through the same writer, with the store's current token.
        guard case .admitted(let saved) = await fixture.store.commitPreferences(
            legacy!, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context
        ) else { return XCTFail("the preferences save was not admitted") }
        XCTAssertTrue(isPersisted(saved.preferences))
        XCTAssertEqual(phaseShape(fixture), ["read preferences", "write preferences", "read preferences"])
        fixture.access.clearObservations()

        // Phase: the retry. The platform is verified, the sidecar is verified in the same step, and only then the runtime file is replaced.
        guard let retried = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isUnchanged(retried.platform), "the platform file is verified, not rewritten")
        XCTAssertTrue(isPersisted(retried.runtime), "the sidecar is verified, so the runtime rewrite may proceed")
        XCTAssertEqual(
            phaseShape(fixture),
            ["read platform", "read preferences", "read runtime", "write runtime", "read runtime"],
            "the sidecar is checked after the platform and immediately before the runtime replacement"
        )
        fixture.access.clearObservations()

        guard let reloaded = await adopt(fixture) else { return }
        XCTAssertEqual(reloaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(fixture.store.values?.preferences, legacy, "a reload after the allowed rewrite keeps the exact preference values")
        let runtime = String(decoding: fixture.access.storedBytes(at: fixture.plan.config.path) ?? Data(), as: UTF8.self)
        XCTAssertFalse(runtime.contains("showMenuBarIcon"), "the canonical runtime file carries no legacy preference keys")
    }

    /// Without a verified sidecar, a rewrite of a changed runtime file is held, and the runtime bytes survive it. Only the platform file moves.
    func testAChangedRuntimeWithLegacyPreferencesIsHeldWhileTheSidecarIsAbsent() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        let runtimeBytes = fixture.seededRuntime
        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertEqual(result.runtime, .notAttempted(.preservationHeld(.sidecarAbsent)))
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes)
    }

    /// A sidecar that exists at load is the authority, and the runtime file's values beside it are shadowed. A rewrite must still verify the
    /// sidecar, so a sidecar that is deleted or changed before the commit holds the rewrite and latches the sidecar's baseline.
    func testASidecarPresentAtLoadThatIsDeletedOrChangedBeforeTheCommitHoldsAndLatches() async throws {
        let changed = try preferenceBytes(showMenuBarIcon: false)
        let mutations: [FakeStateFileAccess.ExternalEdit] = [.remove, .replace(changed)]
        for mutation in mutations {
            let fixture = try ConfigurationStoreTests.Fixture(
                runtime: try legacyRuntime(legacyValues()),
                preferences: try preferenceBytes(showMenuBarIcon: true)
            )
            defer { fixture.close() }
            guard let loaded = await adopt(fixture) else { return }
            XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
            let runtimeBytes = fixture.seededRuntime
            fixture.access.externalEdit(mutation, at: fixture.plan.preferences.path)

            guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
            XCTAssertEqual(result.runtime, .notAttempted(.preservationHeld(.sidecarChanged)), "\(mutation)")
            XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes, "\(mutation)")
            XCTAssertNil(fixture.store.baselineToken(for: .preferences), "a changed sidecar is latched until a reload")
        }
    }

    /// A sidecar created by someone else after the load is a change, not an absence. The platform file is written first, as the coupled order
    /// requires, so that save is reported as persisted. The runtime bytes and the created sidecar are left as they are, and the sidecar's
    /// baseline is latched.
    func testASidecarCreatedAfterTheLoadPreservesTheRuntimeAndSidecarAfterAPlatformSave() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        let runtimeBytes = fixture.seededRuntime
        let created = try preferenceBytes(showMenuBarIcon: true)
        fixture.access.externalEdit(.replace(created), at: fixture.plan.preferences.path)

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.platform), "the platform save precedes the sidecar check, and it is reported")
        XCTAssertEqual(result.runtime, .notAttempted(.preservationHeld(.sidecarChanged)))
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes, "the runtime bytes are preserved")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.preferences.path), created, "the created sidecar is left alone")
        XCTAssertEqual(writes(fixture, at: fixture.plan.preferences.path), 0)
        XCTAssertNil(fixture.store.baselineToken(for: .preferences))
    }

    /// A read that fails during the sidecar check holds the rewrite with its typed read error. Nothing is latched, so the baseline still
    /// authorizes a later check. The platform read is the first read, so only the sidecar's read fails.
    func testAFailedSidecarReadHoldsWithItsTypedErrorAndDoesNotLatch() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try legacyRuntime(legacyValues()),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        let readError = ConfigurationFileError.unreadable(.readFailed(EIO), closeErrno: nil)
        // The platform check reads once and verifies. The next read is the sidecar check, and it fails.
        fixture.access.scheduleReads([.actual, .failed(readError)])

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertEqual(result.runtime, .notAttempted(.preservationHeld(.sidecarUnreadable(readError))))
        XCTAssertNotNil(fixture.store.baselineToken(for: .preferences), "an unreadable sidecar does not latch its baseline")
    }

    /// A preferences save that did not persist, or that is unknown, never lets the runtime rewrite proceed. A not-persisted save keeps the
    /// absent baseline, so the sidecar is still absent. An unknown save latches, so no baseline authorizes the check.
    func testAFailedOrUnknownPreferencesSaveNeverRewritesTheRuntimeFile() async throws {
        let scenarios: [(write: FakeStateFileAccess.WriteScript, expected: ConfigurationNotAttemptedReason)] = [
            (.init(landing: .failsBeforeLanding(errno: 28)), .preservationHeld(.sidecarAbsent)),
            (.init(landing: .lands, editAfterWrite: .replace(Data("other-writer".utf8))), .preservationHeld(.noAuthoritativeSidecarBaseline)),
        ]
        for scenario in scenarios {
            let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
            defer { fixture.close() }
            guard let loaded = await adopt(fixture) else { return }
            XCTAssertEqual(loaded.preferences.migrationPending, true)
            let runtimeBytes = fixture.seededRuntime
            fixture.access.scheduleWrites([scenario.write])
            guard case .admitted(let saved) = await fixture.store.commitPreferences(
                fixture.store.values!.preferences, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context
            ) else { return XCTFail("the preferences save was not admitted") }
            XCTAssertFalse(isPersisted(saved.preferences), "the save did not verify")

            guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
            XCTAssertEqual(result.runtime, .notAttempted(scenario.expected))
            XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes)
        }
    }

    // MARK: - Where the guard does not apply

    /// A runtime file with no legacy preference keys creates no dependency, so the rewrite needs no preferences sidecar.
    func testAbsentLegacyKeysCauseNoNewDependency() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.runtime))
        XCTAssertEqual(writes(fixture, at: fixture.plan.preferences.path), 0)
    }

    /// A null legacy value is absent to the typed decoders, so it creates no dependency either.
    func testANullLegacyValueCreatesNoDependency() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(["showMenuBarIcon": NSNull()]))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.runtime))
    }

    /// An unchanged runtime file with legacy values verifies without a rewrite, so it drops nothing and needs no sidecar. A platform-only
    /// update still persists.
    func testAnUnchangedRuntimeWithLegacyValuesStillTakesAPlatformOnlyUpdate() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        let runtimeBytes = fixture.seededRuntime
        var platform = PlatformIntegrationConfig()
        platform.manageSystemProxy.toggle()
        guard let result = await commit(fixture, GenericDefaults.shared.makeConfig(), platform) else { return }
        XCTAssertTrue(isUnchanged(result.runtime), "the runtime file verifies without a rewrite, got \(result.runtime)")
        XCTAssertTrue(isPersisted(result.platform))
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes)
    }

    /// A refused legacy preference value is not a dependency. Its defaults and typed warning come from the load report, the coupled commit is
    /// not vetoed, and the next reload reports only what the file then holds: the rewrite removed the malformed key, so no fallback is left.
    func testAMalformedLegacyValueIsNotVetoedAndTheReloadReportsOnlyWhatTheFileHolds() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(["showMenuBarIcon": "bad"]))
        defer { fixture.close() }
        guard let first = await adopt(fixture) else { return }
        XCTAssertEqual(
            first.preferences,
            ConfigurationComponentLoad(present: false, migrationPending: false, fallback: .legacyPreferencesRefusedUsingDefaults)
        )
        XCTAssertEqual(fixture.store.values?.preferences, AppPreferences())

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.runtime), "the malformed value is not a dependency, so the rewrite persists")

        guard let reloaded = await adopt(fixture) else { return }
        XCTAssertEqual(reloaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
    }

    /// A malformed legacy value that the user repairs in the file is adopted on the next reload, with its actual values and no fallback.
    func testAnExternalRepairOfAMalformedLegacyValueIsAdoptedWithNoFallbackOnReload() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(["showMenuBarIcon": "bad"]))
        defer { fixture.close() }
        guard let first = await adopt(fixture) else { return }
        XCTAssertEqual(first.preferences.fallback, .legacyPreferencesRefusedUsingDefaults)

        fixture.access.externalEdit(.replace(try legacyRuntime(legacyValues())), at: fixture.plan.config.path)
        guard let repaired = await adopt(fixture) else { return }
        XCTAssertEqual(repaired.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertNil(repaired.preferences.fallback, "the reload reports the repaired file, not the earlier warning")
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false)
        XCTAssertEqual(fixture.store.values?.preferences.preferredBrowserTestURL, "https://example.test/check")
    }

    /// The presence bit clears on the verified canonical rewrite, so a later rewrite does not check the sidecar again. The rewrite removes
    /// the legacy keys, so nothing is left for the sidecar to protect.
    func testThePresenceBitClearsOnTheVerifiedRewriteAndIsRecomputedOnReload() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(legacyValues()))
        defer { fixture.close() }
        guard await adopt(fixture) != nil else { return }
        guard case .admitted(let saved) = await fixture.store.commitPreferences(
            fixture.store.values!.preferences, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context
        ) else { return XCTFail("the preferences save was not admitted") }
        XCTAssertTrue(isPersisted(saved.preferences))
        guard let retried = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(retried.runtime))
        // The log holds the save and the guarded rewrite so far. It is cleared before the later commit, so that phase stays within the budget.
        fixture.access.clearObservations()

        fixture.access.externalEdit(.remove, at: fixture.plan.preferences.path)
        guard let later = await commit(fixture, GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(later.runtime), "a cleared presence bit needs no sidecar")
        XCTAssertEqual(phaseShape(fixture), ["read platform", "read runtime", "write runtime", "read runtime"], "no sidecar check follows")
    }

    // MARK: - The check is not a multi-file claim

    /// The guard reads the sidecar and then replaces the runtime file. A noncooperating editor can delete the sidecar in that window, and the
    /// guard does not exclude it, because it is not a multi-file atomic claim (decision 0027). This pins the actual loss: the runtime rewrite
    /// proceeds, the sidecar's bytes are gone, and the shadowed runtime value goes with them. The sidecar holds `false`, which differs from the
    /// default `true`, so the reload shows the loss instead of hiding it.
    func testADeletionAfterTheGuardCheckIsNotExcluded() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try legacyRuntime(legacyValues()),
            preferences: try preferenceBytes(showMenuBarIcon: false)
        )
        defer { fixture.close() }
        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, "the sidecar's false is adopted before the commit")
        // The next read of the sidecar is the guard's check, and the removal applies right after it returns.
        fixture.access.scheduleEditAfterNextRead(.remove, at: fixture.plan.preferences.path)

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.runtime), "the check passed before the sidecar was removed, so the rewrite proceeded")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path))
        guard let reloaded = await adopt(fixture) else { return }
        XCTAssertEqual(reloaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, true, "the sidecar's false is lost, and the reload shows the default")
    }

    // MARK: - Shadowed legacy values (observe-only membership)

    /// A shadowed wrong-kind value is observed and skipped, so the file is accepted with no fallback and no warning. The sidecar stays the
    /// authority: its value is adopted, and the runtime rewrite runs after the guard verifies the sidecar as current.
    func testAShadowedWrongKindLegacyValueIsSkippedAndTheSidecarStaysAuthoritative() async throws {
        let wrongKinds: [[String: Any]] = [["showMenuBarIcon": "bad"], ["showMenuBarIcon": [1, 2], "preferredBrowserTestURL": 7]]
        for extra in wrongKinds {
            let fixture = try ConfigurationStoreTests.Fixture(
                runtime: try legacyRuntime(extra),
                preferences: try preferenceBytes(showMenuBarIcon: false)
            )
            defer { fixture.close() }
            guard let loaded = await adopt(fixture) else { return }
            XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false), "\(extra)")
            XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, "the sidecar's value is adopted, not the defaults")
            fixture.access.clearObservations()

            guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
            XCTAssertTrue(isPersisted(result.runtime), "the sidecar verifies as current, so the rewrite proceeds: \(extra)")
            XCTAssertEqual(
                phaseShape(fixture),
                ["read platform", "write platform", "read platform", "read preferences", "read runtime", "write runtime", "read runtime"],
                "the sidecar is verified immediately before the runtime replacement: \(extra)"
            )
            fixture.access.clearObservations()

            guard let reloaded = await adopt(fixture) else { return }
            XCTAssertEqual(reloaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false), "\(extra)")
            XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, "\(extra)")
        }
    }

    /// A shadowed null is absent to the decoders, so it creates no dependency on the sidecar. Deleting the sidecar before the commit does not
    /// hold the runtime rewrite, and the deleted sidecar is not recreated.
    func testAShadowedNullLegacyValueCreatesNoDependencyWhenItsSidecarIsDeletedBeforeTheCommit() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try legacyRuntime(["showMenuBarIcon": NSNull(), "preferredBrowserTestURL": NSNull()]),
            preferences: try preferenceBytes(showMenuBarIcon: false)
        )
        defer { fixture.close() }
        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, "the sidecar's value is adopted")
        fixture.access.externalEdit(.remove, at: fixture.plan.preferences.path)
        fixture.access.clearObservations()

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(result.runtime), "a null creates no dependency, so the sidecar's deletion does not hold the rewrite")
        XCTAssertFalse(phaseShape(fixture).contains("read preferences"), "no sidecar check runs")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path), "the deleted sidecar is not recreated")
        XCTAssertEqual(writes(fixture, at: fixture.plan.preferences.path), 0)
        let runtime = String(decoding: fixture.access.storedBytes(at: fixture.plan.config.path) ?? Data(), as: UTF8.self)
        XCTAssertFalse(runtime.contains("showMenuBarIcon"), "the canonical runtime file carries no legacy key")
    }

    /// A null first occurrence wins over a later non-null duplicate, because the filter keeps only the first. A null is absent to the decoders
    /// and is not presence, so the duplicate creates no dependency, whether the sidecar is absent (required) or present (shadowed). The raw
    /// bytes keep the duplicates in order, which a dictionary cannot.
    func testAFirstNullLegacyKeyWinsOverALaterDuplicateWhetherRequiredOrShadowed() async throws {
        let nullThenValue = #""showMenuBarIcon":null,"showMenuBarIcon":true"#

        // Required: no sidecar, so the first null reads as absent and the default holds. The later `true` is never read.
        let absentSidecar = try ConfigurationStoreTests.Fixture(runtime: try rawLegacyRuntime(prefix: nullThenValue))
        defer { absentSidecar.close() }
        guard let absentLoad = await adopt(absentSidecar) else { return }
        XCTAssertEqual(absentLoad.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(absentSidecar.store.values?.preferences.showMenuBarIcon, true, "the default holds, and the later duplicate is ignored")
        absentSidecar.access.clearObservations()
        guard let absentResult = await commit(absentSidecar, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(absentResult.runtime), "no dependency, so the rewrite is not held")
        XCTAssertFalse(phaseShape(absentSidecar).contains("read preferences"), "no sidecar check runs")

        // Shadowed: the sidecar holds `false`. The first null is not presence, so no check runs and the sidecar's value stays adopted.
        let presentSidecar = try ConfigurationStoreTests.Fixture(
            runtime: try rawLegacyRuntime(prefix: nullThenValue),
            preferences: try preferenceBytes(showMenuBarIcon: false)
        )
        defer { presentSidecar.close() }
        guard let presentLoad = await adopt(presentSidecar) else { return }
        XCTAssertEqual(presentLoad.preferences, ConfigurationComponentLoad(present: true, migrationPending: false))
        XCTAssertEqual(presentSidecar.store.values?.preferences.showMenuBarIcon, false, "the sidecar's value is adopted, not the later duplicate")
        presentSidecar.access.clearObservations()
        guard let presentResult = await commit(presentSidecar, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(presentResult.runtime), "no dependency, so the rewrite is not held")
        XCTAssertFalse(phaseShape(presentSidecar).contains("read preferences"), "no sidecar check runs")
        XCTAssertEqual(writes(presentSidecar, at: presentSidecar.plan.preferences.path), 0)
    }

    /// An explicit legacy value equal to the default is still present, so the rewrite is held until the same explicit value is saved. Presence
    /// comes from the key, never from equality with the default.
    func testAnExplicitDefaultLegacyValueIsPresentAndHoldsUntilTheSameValueIsSaved() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try legacyRuntime(["showMenuBarIcon": true]))
        defer { fixture.close() }
        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.preferences, ConfigurationComponentLoad(present: false, migrationPending: true))
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, true, "the explicit value equals the default")
        let runtimeBytes = fixture.seededRuntime

        guard let held = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertEqual(held.runtime, .notAttempted(.preservationHeld(.sidecarAbsent)), "the key is present, though it equals the default")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes)

        guard case .admitted(let saved) = await fixture.store.commitPreferences(
            fixture.store.values!.preferences, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context
        ) else { return XCTFail("the preferences save was not admitted") }
        XCTAssertTrue(isPersisted(saved.preferences))

        guard let retried = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertTrue(isPersisted(retried.runtime), "the same explicit value is saved and verified, so the rewrite proceeds")
    }

    /// A deleted platform sidecar that shadowed platform values is a platform change. The platform's own baseline check holds the runtime,
    /// and the preferences guard is never reached. The runtime bytes stay as they were, and no platform file is written.
    func testADeletedPlatformSidecarWithShadowedPlatformValuesHoldsTheRuntimeThroughItsOwnCheck() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try legacyRuntime(["launchAtLogin": true, "manageSystemProxy": "bad"]),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.platform, ConfigurationComponentLoad(present: true, migrationPending: false))
        let runtimeBytes = fixture.seededRuntime
        fixture.access.externalEdit(.remove, at: fixture.plan.platformConfig.path)
        fixture.access.clearObservations()

        guard let result = await commit(fixture, renamedConfig(), PlatformIntegrationConfig()) else { return }
        XCTAssertFalse(isPersisted(result.platform), "the platform's baseline no longer matches, so nothing is verified")
        XCTAssertEqual(result.runtime, .notAttempted(.heldBehindPlatform))
        XCTAssertNil(fixture.store.baselineToken(for: .platform), "the changed platform file is latched")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), "no platform file is written over the deletion")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), runtimeBytes)
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        XCTAssertFalse(phaseShape(fixture).contains("read preferences"), "the preferences guard is never reached")
        XCTAssertFalse(phaseShape(fixture).contains("read runtime"), "the runtime is not read, so no runtime I/O happens")
    }

    // MARK: - Loader parity

    /// The store adopts the same values as the shared loader over the same bytes. The loader is `loadAllMigrating`, which writes its
    /// migrations to the directory it reads, so each side reads its own copy of the same bytes.
    func testTheStoreAdoptsTheSameValuesAsTheSharedLoaderOverTheSameBytes() async throws {
        let witnesses: [(runtime: Data, preferences: Data?)] = [
            (try legacyRuntime(legacyValues()), nil),
            (try legacyRuntime(["showMenuBarIcon": "bad"]), nil),
            (try legacyRuntime(legacyValues()), try preferenceBytes(showMenuBarIcon: true)),
        ]
        for witness in witnesses {
            let fixture = try ConfigurationStoreTests.Fixture(runtime: witness.runtime, preferences: witness.preferences)
            defer { fixture.close() }
            guard let loaded = await adopt(fixture) else { return }

            let directory = try StateRootScratch.make("configuration-parity")
            defer { StateRootScratch.remove(directory) }
            let environment = RuntimeEnvironment(configDirectory: directory, configFile: directory.appendingPathComponent("config.json"))
            try witness.runtime.write(to: environment.configFile)
            if let preferences = witness.preferences {
                try preferences.write(to: environment.preferencesFile)
            }
            let shared = try ProxyConfigPersistence.loadAllMigrating(in: environment)

            XCTAssertEqual(fixture.store.values?.runtime, shared.config)
            XCTAssertEqual(fixture.store.values?.platform, shared.platformConfig)
            XCTAssertEqual(fixture.store.values?.preferences, shared.appPreferences)
            if let warning = loaded.preferences.fallback?.warning {
                XCTAssertTrue(shared.warnings.contains(warning), "the shared loader reports the same typed warning")
            } else {
                XCTAssertFalse(
                    shared.warnings.contains(ConfigurationLegacyFallback.legacyPreferencesRefusedUsingDefaults.warning),
                    "the shared loader reports no fallback the store does not"
                )
            }
        }
    }

    /// A sidecar beside a missing runtime file is refused by both loaders, so neither adopts defaults over it.
    func testASidecarBesideAMissingRuntimeFileIsRefusedByBothLoaders() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(preferences: try preferenceBytes(showMenuBarIcon: false))
        defer { fixture.close() }
        fixture.access.externalEdit(.remove, at: fixture.plan.config.path)
        guard case .admitted(let report) = await fixture.store.load(context: Self.context),
              case .refused(.invalidContent) = report.outcome else {
            return XCTFail("the store did not refuse the missing runtime file")
        }
        XCTAssertNil(fixture.store.baselineToken(for: .preferences))

        let directory = try StateRootScratch.make("configuration-parity")
        defer { StateRootScratch.remove(directory) }
        let environment = RuntimeEnvironment(configDirectory: directory, configFile: directory.appendingPathComponent("config.json"))
        try preferenceBytes(showMenuBarIcon: false).write(to: environment.preferencesFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadAllMigrating(in: environment))
    }

    /// The deliberate difference: `ProxyConfigPersistence.load(in:)` counts runtime artifacts as prior state, and the store does not. A
    /// snapshot beside a missing config is refused by the single-file loader, and the store adopts defaults with no runtime file.
    func testARuntimeArtifactBesideAMissingConfigIsRefusedByThePMProxyLoaderOnly() async throws {
        let fixture = try ConfigurationStoreTests.Fixture()
        defer { fixture.close() }
        let environment = RuntimeEnvironment(configDirectory: fixture.directory, configFile: URL(fileURLWithPath: fixture.plan.config.path))
        try Data("{}".utf8).write(to: environment.snapshotFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.load(in: environment))

        guard let loaded = await adopt(fixture) else { return }
        XCTAssertEqual(loaded.runtime, ConfigurationComponentLoad(present: false, migrationPending: false))
    }
}
