// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The runtime file is the source of a missing sidecar's values: its legacy keys when it carries them, and the defaults when it does not
/// (decisions 0023 and 0026). A missing sidecar's own baseline is its absence, which says nothing about that source. These witnesses pin
/// the authority the store issues over such a sidecar: a reload that changes its effective value retires its token, and its first write
/// checks the runtime bytes the store established, so it never shadows values the runtime file gained after the store observed it. They
/// use the fake file access over a real lease, as `ConfigurationStoreTests` does.
///
/// Known limit, pinned by `testARuntimeEditAfterTheSourceCheckIsNotExcluded`: the check is not a multi-file atomic claim (decision 0027).
final class ConfigurationStoreSourceTests: XCTestCase {
    private struct SeedFailure: Error {}

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    /// The canonical defaults runtime file with extra top-level keys, so a witness can carry legacy values.
    @RuntimeActor private func runtimeFile(_ extra: [String: Any] = [:], profileName: String? = nil) throws -> Data {
        var config = GenericDefaults.shared.makeConfig()
        if let profileName { config.profileName = profileName }
        let staged = try ProxyConfigPersistence.stagedFileData(for: config)
        guard !extra.isEmpty else { return staged }
        guard var object = try JSONSerialization.jsonObject(with: staged) as? [String: Any] else { throw SeedFailure() }
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @RuntimeActor private func isPersisted(_ outcome: ConfigurationWriteOutcome) -> Bool {
        if case .persisted = outcome { true } else { false }
    }

    @RuntimeActor private func adopt(_ fixture: ConfigurationStoreTests.Fixture) async -> ConfigurationLoadOutcome? {
        guard case .admitted(let report) = await fixture.store.load(context: Self.context) else {
            XCTFail("the load was not admitted")
            return nil
        }
        return report.outcome
    }

    @RuntimeActor private func adopted(_ fixture: ConfigurationStoreTests.Fixture) async -> Bool {
        guard case .adopted = await adopt(fixture) else {
            XCTFail("the load was not adopted")
            return false
        }
        return true
    }

    @RuntimeActor private func commitCoupled(
        _ fixture: ConfigurationStoreTests.Fixture,
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        platformToken: ConfigurationBaselineToken?
    ) async -> RuntimePlatformCommitResult? {
        guard case .admitted(let result) = await fixture.store.commitRuntimeAndPlatform(
            runtime, platform,
            expecting: ConfigurationSlots(runtime: fixture.store.baselineToken(for: .runtime), platform: platformToken, preferences: nil),
            context: Self.context
        ) else {
            XCTFail("the commit was not admitted")
            return nil
        }
        return result
    }

    @RuntimeActor private func commitPreferences(
        _ fixture: ConfigurationStoreTests.Fixture,
        _ preferences: AppPreferences,
        token: ConfigurationBaselineToken?
    ) async -> ConfigurationWriteOutcome? {
        guard case .admitted(let result) = await fixture.store.commitPreferences(preferences, expecting: token, context: Self.context) else {
            XCTFail("the preferences commit was not admitted")
            return nil
        }
        return result.preferences
    }

    /// The physical calls since the last `clearObservations`, by file, so a witness shows where the source read sits.
    @RuntimeActor private func phaseShape(_ fixture: ConfigurationStoreTests.Fixture) -> [String] {
        fixture.access.observations.map { observation in
            let (verb, path) = switch observation {
            case .read(let path, _): ("read", path)
            case .write(let path, _): ("write", path)
            }
            let file = switch path {
            case fixture.plan.config.path: "runtime"
            case fixture.plan.platformConfig.path: "platform"
            case fixture.plan.preferences.path: "preferences"
            default: "other"
            }
            return "\(verb) \(file)"
        }
    }

    @RuntimeActor private func decidedPreferences() -> AppPreferences {
        var decided = AppPreferences()
        decided.preferredBrowserTestURL = "https://example.test/decided"
        return decided
    }

    // MARK: - A reload that changes a missing sidecar's effective value

    /// The platform sidecar is missing, so the runtime file's legacy `launchAtLogin` is its value. An external edit flips it, and the reload
    /// adopts the new value. A token issued for the old value must not authorize a write: the caller decided from a value that is gone.
    @RuntimeActor func testAReloadThatChangesAMissingPlatformSidecarsLegacyValueRetiresItsToken() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile(["launchAtLogin": true]))
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.platform.launchAtLogin, true)
        let stale = fixture.store.baselineToken(for: .platform)
        XCTAssertNotNil(stale)

        fixture.access.externalEdit(.replace(try runtimeFile(["launchAtLogin": false])), at: fixture.plan.config.path)
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.platform.launchAtLogin, false, "the reload adopts the edited legacy value")
        XCTAssertNotEqual(fixture.store.baselineToken(for: .platform), stale, "the effective platform value changed, so the token must change")

        // The caller still holds the old token and the value it decided from.
        var decided = PlatformIntegrationConfig()
        decided.launchAtLogin = true
        fixture.access.clearObservations()
        guard let result = await commitCoupled(fixture, fixture.store.values!.runtime, decided, platformToken: stale) else { return }
        XCTAssertEqual(result.platform, .notAttempted(.baselineMismatch), "the stale platform token must be refused")
        XCTAssertEqual(result.runtime, .notAttempted(.heldBehindPlatform))
        XCTAssertEqual(phaseShape(fixture), [], "a refused token does no I/O")
        XCTAssertNil(
            fixture.access.storedBytes(at: fixture.plan.platformConfig.path),
            "no platform sidecar is created from the stale value over the edited legacy value"
        )
    }

    /// The same for the preferences sidecar, through its own commit.
    @RuntimeActor func testAReloadThatChangesAMissingPreferencesSidecarsLegacyValueRetiresItsToken() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile(["showMenuBarIcon": false]))
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false)
        let stale = fixture.store.baselineToken(for: .preferences)
        XCTAssertNotNil(stale)

        fixture.access.externalEdit(.replace(try runtimeFile(["showMenuBarIcon": true])), at: fixture.plan.config.path)
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, true, "the reload adopts the edited legacy value")
        XCTAssertNotEqual(fixture.store.baselineToken(for: .preferences), stale, "the effective preferences value changed, so the token must change")

        var decided = AppPreferences()
        decided.showMenuBarIcon = false
        guard let outcome = await commitPreferences(fixture, decided, token: stale) else { return }
        XCTAssertEqual(outcome, .notAttempted(.baselineMismatch), "the stale preferences token must be refused")
        XCTAssertNil(
            fixture.access.storedBytes(at: fixture.plan.preferences.path),
            "no preferences sidecar is created from the stale value over the edited legacy value"
        )
    }

    /// A reload that moves a missing sidecar's version needs a newer version, so a sidecar at its maximum refuses the reload before anything
    /// is adopted, as a changed file of its own does.
    @RuntimeActor func testAReloadThatChangesAMissingSidecarsValueAtItsMaximumVersionIsRefused() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile(["showMenuBarIcon": false]))
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        fixture.store.exhaustVersionForTesting(.preferences)
        fixture.access.externalEdit(.replace(try runtimeFile(["showMenuBarIcon": true])), at: fixture.plan.config.path)

        let outcome = await adopt(fixture)
        guard case .refused(.versionExhausted(.preferences)) = outcome else {
            return XCTFail("the reload must be refused for the exhausted preferences version, got \(String(describing: outcome))")
        }
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false, "the refused reload adopts nothing")
    }

    /// A runtime edit that leaves a missing sidecar's effective value as it was keeps the sidecar's token, and so does any runtime edit
    /// beside a present sidecar, because the sidecar is then its own source.
    @RuntimeActor func testAHarmlessRuntimeEditOrAPresentSidecarKeepsTheSidecarToken() async throws {
        let missing = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile(["showMenuBarIcon": false]))
        defer { missing.close() }
        guard await adopted(missing) else { return }
        let kept = missing.store.baselineToken(for: .preferences)
        missing.access.externalEdit(.replace(try runtimeFile(["showMenuBarIcon": false], profileName: "Renamed")), at: missing.plan.config.path)
        guard await adopted(missing) else { return }
        XCTAssertEqual(missing.store.baselineToken(for: .preferences), kept, "the effective value is unchanged, so the token holds")
        // The reload refreshed the source to the edited bytes, so the kept token's first write proceeds.
        guard let written = await commitPreferences(missing, missing.store.values!.preferences, token: kept) else { return }
        XCTAssertTrue(isPersisted(written), "got \(written)")

        var shadowed = AppPreferences()
        shadowed.showMenuBarIcon = false
        let present = try ConfigurationStoreTests.Fixture(
            runtime: try runtimeFile(["showMenuBarIcon": true]),
            preferences: try AppPreferencesPersistence.stagedData(for: shadowed)
        )
        defer { present.close() }
        guard await adopted(present) else { return }
        let presentToken = present.store.baselineToken(for: .preferences)
        present.access.externalEdit(.replace(try runtimeFile(["showMenuBarIcon": false])), at: present.plan.config.path)
        guard await adopted(present) else { return }
        XCTAssertEqual(present.store.baselineToken(for: .preferences), presentToken, "a present sidecar has no runtime source")
    }

    // MARK: - The first sidecar write after an external runtime edit

    /// The runtime file carried no legacy preference keys at load, so the missing sidecar's value is the defaults. An external edit then adds a
    /// legacy value to the runtime file, with no reload. The first sidecar write would shadow that value with one decided from the defaults,
    /// so it creates no sidecar, and both the sidecar and the runtime file lose their authority until a reload.
    @RuntimeActor func testTheFirstPreferencesWriteAfterAnExternalRuntimeEditAddingLegacyKeysCreatesNoSidecar() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences, AppPreferences(), "no legacy keys, so the defaults are the source")
        let edited = try runtimeFile(["showMenuBarIcon": false])
        fixture.access.externalEdit(.replace(edited), at: fixture.plan.config.path)
        fixture.access.clearObservations()

        guard let outcome = await commitPreferences(fixture, decidedPreferences(), token: fixture.store.baselineToken(for: .preferences)) else {
            return
        }
        XCTAssertEqual(outcome, .notAttempted(.sourceChanged))
        XCTAssertEqual(phaseShape(fixture), ["read runtime"], "the source check is the only call, and no sidecar call follows it")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path), "the sidecar is not created over the edited runtime source")
        XCTAssertNil(fixture.store.baselineToken(for: .preferences), "the changed source latches the sidecar")
        XCTAssertNil(fixture.store.baselineToken(for: .runtime), "the changed source latches the runtime file")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), edited, "the edited runtime file is kept")

        // A reload is the way out: it adopts the edited value, and the first write then proceeds.
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, false)
        guard let retried = await commitPreferences(fixture, decidedPreferences(), token: fixture.store.baselineToken(for: .preferences)) else {
            return
        }
        XCTAssertTrue(isPersisted(retried), "after the reload the source holds, got \(retried)")
    }

    /// The same through the coupled commit, for the platform sidecar. The platform file is considered first, so a held platform write holds
    /// the runtime write behind it, and no platform sidecar is created.
    @RuntimeActor func testTheFirstPlatformWriteAfterAnExternalRuntimeEditAddingLegacyKeysCreatesNoSidecar() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.platform, PlatformIntegrationConfig())
        let edited = try runtimeFile(["launchAtLogin": true])
        fixture.access.externalEdit(.replace(edited), at: fixture.plan.config.path)
        fixture.access.clearObservations()

        var decided = PlatformIntegrationConfig()
        decided.manageSystemProxy = true
        guard let result = await commitCoupled(
            fixture, fixture.store.values!.runtime, decided, platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertEqual(result.platform, .notAttempted(.sourceChanged))
        XCTAssertEqual(result.runtime, .notAttempted(.heldBehindPlatform))
        XCTAssertEqual(phaseShape(fixture), ["read runtime"], "the platform's source check is the only call")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), "no platform sidecar is created")
        XCTAssertNil(fixture.store.baselineToken(for: .platform), "the changed source latches the platform sidecar")
        XCTAssertNil(fixture.store.baselineToken(for: .runtime), "the changed source latches the runtime file")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), edited, "the edited runtime file is kept")
    }

    /// No file existed at load, so every value is a default. Someone else then creates the runtime file with legacy values. A first sidecar
    /// write of either kind creates no sidecar over them.
    @RuntimeActor func testTheFirstSidecarWriteAfterAnExternallyCreatedRuntimeFileCreatesNoSidecar() async throws {
        let created = try runtimeFile(["showMenuBarIcon": false, "launchAtLogin": true])

        let preferences = try ConfigurationStoreTests.Fixture()
        defer { preferences.close() }
        guard await adopted(preferences) else { return }
        preferences.access.externalEdit(.replace(created), at: preferences.plan.config.path)
        guard let outcome = await commitPreferences(
            preferences, decidedPreferences(), token: preferences.store.baselineToken(for: .preferences)
        ) else { return }
        XCTAssertEqual(outcome, .notAttempted(.sourceChanged))
        XCTAssertNil(preferences.access.storedBytes(at: preferences.plan.preferences.path))
        XCTAssertNil(preferences.store.baselineToken(for: .runtime), "the created runtime file latches the runtime authority")

        let platform = try ConfigurationStoreTests.Fixture()
        defer { platform.close() }
        guard await adopted(platform) else { return }
        platform.access.externalEdit(.replace(created), at: platform.plan.config.path)
        var decidedPlatform = PlatformIntegrationConfig()
        decidedPlatform.manageSystemProxy = true
        guard let result = await commitCoupled(
            platform, platform.store.values!.runtime, decidedPlatform, platformToken: platform.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertEqual(result.platform, .notAttempted(.sourceChanged))
        XCTAssertEqual(result.runtime, .notAttempted(.heldBehindPlatform))
        XCTAssertNil(platform.access.storedBytes(at: platform.plan.platformConfig.path))
        XCTAssertEqual(platform.access.storedBytes(at: platform.plan.config.path), created, "the created runtime file is kept")
    }

    /// A harmless edit keeps the sidecar's token across a reload, but the check before the first write compares bytes, so before that
    /// reload the write is held. After the reload the store holds the new bytes as the source, and the first write proceeds.
    @RuntimeActor func testAHarmlessRuntimeEditHoldsTheFirstWriteUntilAReloadRefreshesTheSource() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        let token = fixture.store.baselineToken(for: .preferences)
        fixture.access.externalEdit(.replace(try runtimeFile(profileName: "Renamed")), at: fixture.plan.config.path)

        guard let held = await commitPreferences(fixture, decidedPreferences(), token: token) else { return }
        XCTAssertEqual(held, .notAttempted(.sourceChanged), "the bytes changed, whatever the values say")

        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences, AppPreferences(), "the effective value is still the defaults")
        let refreshed = fixture.store.baselineToken(for: .preferences)
        guard let written = await commitPreferences(fixture, decidedPreferences(), token: refreshed) else { return }
        XCTAssertTrue(isPersisted(written), "the reload refreshed the source to the edited bytes, got \(written)")
    }

    // MARK: - An unreadable source

    /// A source read that fails holds the first write with its full typed error, and nothing is latched. The same token then writes once the
    /// read succeeds. No sidecar call is made while the source is not established.
    @RuntimeActor func testAnUnreadableSourceHoldsTheFirstPreferencesWriteWithItsTypedErrorAndKeepsAuthority() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        let tokens = (runtime: fixture.store.baselineToken(for: .runtime), preferences: fixture.store.baselineToken(for: .preferences))
        let readError = ConfigurationFileError.unreadable(.readFailed(EIO), closeErrno: nil)
        fixture.access.scheduleReads([.failed(readError)])
        fixture.access.clearObservations()

        guard let held = await commitPreferences(fixture, decidedPreferences(), token: tokens.preferences) else { return }
        XCTAssertEqual(held, .notAttempted(.sourceUnreadable(readError)))
        XCTAssertEqual(phaseShape(fixture), ["read runtime"])
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path))
        XCTAssertEqual(fixture.store.baselineToken(for: .preferences), tokens.preferences, "an unreadable source latches nothing")
        XCTAssertEqual(fixture.store.baselineToken(for: .runtime), tokens.runtime, "an unreadable source latches nothing")

        guard let retried = await commitPreferences(fixture, decidedPreferences(), token: tokens.preferences) else { return }
        XCTAssertTrue(isPersisted(retried), "the same token writes once the source reads, got \(retried)")
    }

    /// The coupled path: an unreadable platform source holds the platform write with its typed error, and the runtime write behind it. Both
    /// keep their authority, and nothing is written.
    @RuntimeActor func testAnUnreadableSourceHoldsTheCoupledCommitBehindThePlatformAndKeepsAuthority() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        let runtimeToken = fixture.store.baselineToken(for: .runtime)
        let platformToken = fixture.store.baselineToken(for: .platform)
        let readError = ConfigurationFileError.unreadable(.readFailed(EIO), closeErrno: nil)
        fixture.access.scheduleReads([.failed(readError)])
        fixture.access.clearObservations()

        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        guard let result = await commitCoupled(fixture, renamed, PlatformIntegrationConfig(), platformToken: platformToken) else { return }
        XCTAssertEqual(result.platform, .notAttempted(.sourceUnreadable(readError)))
        XCTAssertEqual(result.runtime, .notAttempted(.heldBehindPlatform))
        XCTAssertEqual(phaseShape(fixture), ["read runtime"])
        XCTAssertEqual(fixture.store.baselineToken(for: .runtime), runtimeToken)
        XCTAssertEqual(fixture.store.baselineToken(for: .platform), platformToken)
    }

    // MARK: - The store's own writes move the source

    /// The store's own verified runtime write moves a still-missing sidecar's source to the new bytes, with no version change. The coupled
    /// commit writes the platform first, so its first write is checked against the loaded bytes and the runtime write is not checked. The
    /// preferences sidecar's first write is then checked against the runtime bytes the store wrote, and it proceeds. Once that sidecar
    /// exists, it has no source, so a later write makes no runtime read.
    @RuntimeActor func testTheStoresOwnRuntimeWriteMovesTheSourceAndTheFirstSidecarWriteClearsIt() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        let preferencesToken = fixture.store.baselineToken(for: .preferences)
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        fixture.access.clearObservations()
        guard let coupled = await commitCoupled(
            fixture, renamed, PlatformIntegrationConfig(), platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertTrue(isPersisted(coupled.platform), "got \(coupled.platform)")
        XCTAssertTrue(isPersisted(coupled.runtime), "got \(coupled.runtime)")
        XCTAssertEqual(
            phaseShape(fixture),
            ["read runtime", "read platform", "write platform", "read platform", "read runtime", "write runtime", "read runtime"],
            "only the missing platform sidecar's first write checks the source"
        )
        XCTAssertEqual(fixture.store.baselineToken(for: .preferences), preferencesToken, "the own runtime write moves no sidecar version")
        fixture.access.clearObservations()

        guard let first = await commitPreferences(fixture, AppPreferences(), token: preferencesToken) else { return }
        XCTAssertTrue(isPersisted(first), "the store's own runtime write is not an external source change, got \(first)")
        XCTAssertEqual(phaseShape(fixture), ["read runtime", "read preferences", "write preferences", "read preferences"])
        fixture.access.clearObservations()

        // The sidecar exists now, so a runtime edit is no concern of its next write.
        fixture.access.externalEdit(.replace(try runtimeFile(["showMenuBarIcon": false])), at: fixture.plan.config.path)
        guard let second = await commitPreferences(fixture, decidedPreferences(), token: fixture.store.baselineToken(for: .preferences)) else {
            return
        }
        XCTAssertTrue(isPersisted(second), "got \(second)")
        XCTAssertEqual(phaseShape(fixture), ["read preferences", "write preferences", "read preferences"], "a present sidecar has no source")
    }

    /// A runtime write that is not persisted leaves the source where it was, so the first sidecar write is checked against the old bytes,
    /// which are still on disk, and proceeds.
    @RuntimeActor func testANotPersistedRuntimeWriteLeavesTheSourceOnTheBytesStillOnDisk() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try runtimeFile(),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        fixture.access.scheduleWrites([.init(landing: .failsBeforeLanding(errno: 28))])
        var renamed = GenericDefaults.shared.makeConfig()
        renamed.profileName = "Renamed"
        guard let coupled = await commitCoupled(
            fixture, renamed, PlatformIntegrationConfig(), platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        guard case .notPersisted = coupled.runtime else { return XCTFail("the runtime write did not persist, got \(coupled.runtime)") }

        guard let first = await commitPreferences(fixture, decidedPreferences(), token: fixture.store.baselineToken(for: .preferences)) else {
            return
        }
        XCTAssertTrue(isPersisted(first), "the old bytes are still the source, got \(first)")
    }

    // MARK: - Canonically equivalent but byte-distinct strings

    /// Two spellings of one URL: a precomposed é, and e followed by a combining acute accent. Their UTF-8 bytes differ, and so do the file
    /// bytes a save writes, whatever a value equality says about them.
    private static let composedURL = "https://example.test/caf\u{00E9}"
    private static let decomposedURL = "https://example.test/cafe\u{0301}"

    @RuntimeActor private func utf8(_ string: String?) -> [UInt8]? {
        string.map { Array($0.utf8) }
    }

    /// The missing preferences sidecar takes the runtime file's legacy URL. An outside edit replaces it with the other spelling, and the
    /// reload adopts those exact bytes. The effective value changed bytewise, so the token issued for the old spelling must be retired.
    @RuntimeActor func testAReloadThatRespellsAMissingSidecarsLegacyURLRetiresItsToken() async throws {
        XCTAssertNotEqual(utf8(Self.composedURL), utf8(Self.decomposedURL), "the fixture's two spellings are byte-distinct")
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile(["preferredBrowserTestURL": Self.composedURL]))
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(utf8(fixture.store.values?.preferences.preferredBrowserTestURL), utf8(Self.composedURL))
        let stale = fixture.store.baselineToken(for: .preferences)

        fixture.access.externalEdit(.replace(try runtimeFile(["preferredBrowserTestURL": Self.decomposedURL])), at: fixture.plan.config.path)
        guard await adopted(fixture) else { return }
        XCTAssertEqual(
            utf8(fixture.store.values?.preferences.preferredBrowserTestURL), utf8(Self.decomposedURL),
            "the reload adopts the edited spelling's exact bytes"
        )
        XCTAssertNotEqual(fixture.store.baselineToken(for: .preferences), stale, "the effective value's bytes changed, so the token must change")

        var decided = AppPreferences()
        decided.preferredBrowserTestURL = Self.composedURL
        guard let outcome = await commitPreferences(fixture, decided, token: stale) else { return }
        XCTAssertEqual(outcome, .notAttempted(.baselineMismatch), "the token for the old spelling must be refused")
        XCTAssertNil(fixture.access.storedBytes(at: fixture.plan.preferences.path), "no sidecar is created from the old spelling")
    }

    /// A present sidecar holds one spelling, and the caller saves the other. The request's bytes differ from the file's, so the save must
    /// write them; a verification without a write would report the request as saved while the file keeps the old bytes.
    @RuntimeActor func testAPreferencesSaveOfAByteDistinctEquivalentURLWritesTheRequestedBytes() async throws {
        var stored = AppPreferences()
        stored.preferredBrowserTestURL = Self.composedURL
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try runtimeFile(),
            preferences: try AppPreferencesPersistence.stagedData(for: stored)
        )
        defer { fixture.close() }
        guard await adopted(fixture) else { return }

        var requested = AppPreferences()
        requested.preferredBrowserTestURL = Self.decomposedURL
        guard let outcome = await commitPreferences(fixture, requested, token: fixture.store.baselineToken(for: .preferences)) else { return }
        XCTAssertTrue(isPersisted(outcome), "the requested bytes differ from the file's, so they are written, got \(outcome)")
        let bytes = fixture.access.storedBytes(at: fixture.plan.preferences.path) ?? Data()
        XCTAssertNotNil(bytes.range(of: Data("cafe\u{0301}".utf8)), "the sidecar holds the requested spelling")
        XCTAssertNil(bytes.range(of: Data("caf\u{00E9}".utf8)), "the sidecar no longer holds the old spelling")
        XCTAssertEqual(utf8(fixture.store.values?.preferences.preferredBrowserTestURL), utf8(Self.decomposedURL), "the store's value is the request")
    }

    /// The same for the runtime file through the coupled commit: a profile name saved in the other spelling must be written.
    @RuntimeActor func testARuntimeSaveOfAByteDistinctEquivalentNameWritesTheRequestedBytes() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try runtimeFile(profileName: "Caf\u{00E9}"),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard await adopted(fixture) else { return }

        var requested = GenericDefaults.shared.makeConfig()
        requested.profileName = "Cafe\u{0301}"
        guard let result = await commitCoupled(
            fixture, requested, PlatformIntegrationConfig(), platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertTrue(isPersisted(result.runtime), "the requested bytes differ from the file's, so they are written, got \(result.runtime)")
        let bytes = fixture.access.storedBytes(at: fixture.plan.config.path) ?? Data()
        XCTAssertNotNil(bytes.range(of: Data("Cafe\u{0301}".utf8)), "the runtime file holds the requested spelling")
        XCTAssertEqual(utf8(fixture.store.values?.runtime.profileName), utf8("Cafe\u{0301}"), "the store's value is the request")
    }

    /// The PAC URL is an applied value, so the pair the store hands over must be the persisted one. The runtime file holds one spelling and
    /// the candidate has the other: the save writes the candidate's bytes, the verified pair carries them, and a reload of the file adopts
    /// the same bytes.
    @RuntimeActor func testARuntimeSaveOfAByteDistinctPACURLHandsOverThePersistedBytes() async throws {
        var stored = GenericDefaults.shared.makeConfig()
        stored.pacURL = Self.composedURL
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try ProxyConfigPersistence.stagedFileData(for: stored),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        XCTAssertEqual(utf8(fixture.store.values?.runtime.pacURL), utf8(Self.composedURL))

        var requested = stored
        requested.pacURL = Self.decomposedURL
        guard let result = await commitCoupled(
            fixture, requested, PlatformIntegrationConfig(), platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertTrue(isPersisted(result.runtime), "got \(result.runtime)")
        XCTAssertEqual(utf8(result.verifiedInput?.runtime.pacURL), utf8(Self.decomposedURL), "the handed-over pair carries the persisted bytes")
        let bytes = fixture.access.storedBytes(at: fixture.plan.config.path) ?? Data()
        XCTAssertNotNil(bytes.range(of: Data("cafe\u{0301}".utf8)))
        XCTAssertNil(bytes.range(of: Data("caf\u{00E9}".utf8)))

        guard await adopted(fixture) else { return }
        XCTAssertEqual(utf8(fixture.store.values?.runtime.pacURL), utf8(Self.decomposedURL), "the file holds what was handed over")
    }

    // MARK: - A current value with no canonical encoding

    /// The load adopts a runtime file whose interval is past the runtime's range, so it can be repaired. That value has no canonical
    /// encoding, so the comparison counts it as different: a valid repair is written, not refused, and saving the loaded value itself is
    /// refused by its own staging with the closed reason.
    @RuntimeActor func testAnUnrepresentableLoadedRuntimeValueIsRepairedByAValidCandidate() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(
            runtime: try runtimeFile(["healthCheckIntervalSeconds": 1e300]),
            platform: try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        )
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        let loaded = try XCTUnwrap(fixture.store.values?.runtime)
        XCTAssertThrowsError(try ProxyConfigPersistence.stagedFile(for: loaded), "the loaded value has no canonical encoding")

        guard let unchanged = await commitCoupled(
            fixture, loaded, PlatformIntegrationConfig(), platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        guard case .notAttempted(.stagingRefused(.representability)) = unchanged.runtime else {
            return XCTFail("the loaded value itself is refused by its staging, got \(unchanged.runtime)")
        }

        guard let repaired = await commitCoupled(
            fixture, GenericDefaults.shared.makeConfig(), PlatformIntegrationConfig(),
            platformToken: fixture.store.baselineToken(for: .platform)
        ) else { return }
        XCTAssertTrue(isPersisted(repaired.runtime), "a valid candidate repairs the file, got \(repaired.runtime)")
        XCTAssertEqual(
            fixture.access.storedBytes(at: fixture.plan.config.path),
            try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig())
        )
    }

    // MARK: - The check is not a multi-file claim

    /// The source check reads the runtime file and then replaces the sidecar. A noncooperating editor can change the runtime file in that
    /// window, and the check does not exclude it (decision 0027). This pins the actual loss: the sidecar is created, and the legacy value
    /// added after the check is shadowed by it.
    @RuntimeActor func testARuntimeEditAfterTheSourceCheckIsNotExcluded() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try runtimeFile())
        defer { fixture.close() }
        guard await adopted(fixture) else { return }
        // The next read of the runtime file is the source check, and the edit applies right after it returns.
        fixture.access.scheduleEditAfterNextRead(.replace(try runtimeFile(["showMenuBarIcon": false])), at: fixture.plan.config.path)

        guard let outcome = await commitPreferences(fixture, AppPreferences(), token: fixture.store.baselineToken(for: .preferences)) else {
            return
        }
        XCTAssertTrue(isPersisted(outcome), "the check passed before the edit, so the write proceeded, got \(outcome)")
        guard await adopted(fixture) else { return }
        XCTAssertEqual(fixture.store.values?.preferences.showMenuBarIcon, true, "the edited legacy false is shadowed by the created sidecar")
    }
}
