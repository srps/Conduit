// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The root layout over a scripted tree (decisions 0020 and 0028). A writer-owned
/// role names its fixed slot, so identity, reserved-name and case checks reach the
/// slots through links and hard links of the fixed names. The real-file-system
/// counterparts are in `StateRootOSProbeTests`.
final class StateRootLayoutTests: XCTestCase {
    private func tree(caseSensitive: Bool? = true) -> FakeStateRootFileSystem {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: caseSensitive)
        fileSystem.addDirectory("/state")
        fileSystem.addDirectory("/elsewhere")
        return fileSystem
    }

    private func resolve(
        _ environment: RuntimeEnvironment,
        _ access: StateRootConfigAccess = .writerOwned,
        fileSystem: FakeStateRootFileSystem,
        createRoot: Bool = false
    ) -> Result<StateRootPlan, StateRootFailure> {
        do {
            return .success(try StateRootLayout.resolve(
                environment, configAccess: access, createRootIfMissing: createRoot, fileSystem: fileSystem
            ))
        } catch {
            return .failure(error)
        }
    }

    private func plan(
        _ result: Result<StateRootPlan, StateRootFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StateRootPlan? {
        switch result {
        case .success(let plan): return plan
        case .failure(let failure):
            XCTFail("unexpected refusal: \(failure)", file: file, line: line)
            return nil
        }
    }

    private func refusal(
        _ result: Result<StateRootPlan, StateRootFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StateRootFailure? {
        switch result {
        case .success(let plan):
            XCTFail("expected a refusal, resolved \(plan)", file: file, line: line)
            return nil
        case .failure(let failure): return failure
        }
    }

    private func state(_ path: String = "/state") -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    func testDefaultLayoutKeepsEveryAuthoritativeFileInsideTheRoot() throws {
        let fileSystem = FakeStateRootFileSystem()
        fileSystem.addDirectory("/state")
        let result = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)))

        XCTAssertEqual(result.root.path, "/state")
        XCTAssertEqual(result.config.path, "/state/config.json")
        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
        XCTAssertEqual(result.preferences.path, "/state/preferences.json")
        XCTAssertEqual(result.journal.path, "/state/platform-state.json")
        XCTAssertEqual(result.configAccess, .writerOwned)
    }

    /// A custom in-root name is not a writable slot (decision 0028). It is refused before it is read.
    func testCustomConfigNameInsideTheRootIsRefusedBeforeItIsRead() {
        let fileSystem = tree()
        fileSystem.addFile("/state/my-config.json")
        let environment = RuntimeEnvironment(configDirectory: state(), configFile: state().appendingPathComponent("my-config.json"))

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .unsupportedFileName(.config))
    }

    /// `--config /state/config.json` derives its root from the parent, as the daemon always did.
    func testExplicitFixedConfigParentBecomesTheRoot() throws {
        let fileSystem = tree()
        let result = try XCTUnwrap(plan(resolve(
            RuntimeEnvironment.explicit(configFile: state().appendingPathComponent("config.json")), fileSystem: fileSystem
        )))

        XCTAssertEqual(result.root.path, "/state")
        XCTAssertEqual(result.config.path, "/state/config.json")
        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
    }

    func testWriterRefusesAConfigOutsideItsRoot() {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: URL(fileURLWithPath: "/elsewhere/config.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .outsideRoot(.config))
    }

    func testReadOnlyInputMayReadAConfigOutsideTheRootWithoutOwningIt() throws {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: URL(fileURLWithPath: "/elsewhere/config.json")
        )
        let result = try XCTUnwrap(plan(resolve(environment, .readOnlyInput, fileSystem: fileSystem)))

        XCTAssertEqual(result.configAccess, .readOnlyInput)
        XCTAssertEqual(result.config.path, "/elsewhere/config.json")
        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
    }

    func testReadOnlyInputDoesNotExcuseAnOutsideWritableFile() {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), preferencesFile: URL(fileURLWithPath: "/elsewhere/prefs.json")
        )

        XCTAssertEqual(refusal(resolve(environment, .readOnlyInput, fileSystem: fileSystem)), .outsideRoot(.preferences))
    }

    func testSymbolicLinkLeafThatEscapesTheRootIsRefused() {
        let fileSystem = tree()
        fileSystem.addFile("/elsewhere/prefs.json")
        fileSystem.addSymbolicLink("/state/preferences.json", to: "/elsewhere/prefs.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .outsideRoot(.preferences))
    }

    /// A link inside the root is an alias for a file inside the root. The
    /// identity is the target, so two authoritative names cannot share one file.
    func testSymbolicLinkLeafInsideTheRootResolvesToItsTarget() throws {
        let fileSystem = tree()
        fileSystem.addFile("/state/real-prefs.json")
        fileSystem.addSymbolicLink("/state/preferences.json", to: "/state/real-prefs.json")
        let result = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)))

        XCTAssertEqual(result.preferences.path, "/state/real-prefs.json")
    }

    func testSymbolicLinkedParentThatEscapesTheRootIsRefused() {
        let fileSystem = tree()
        fileSystem.addSymbolicLink("/state/nested", to: "/elsewhere")
        let environment = RuntimeEnvironment(
            configDirectory: state(), platformConfigFile: URL(fileURLWithPath: "/state/nested/platform.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .outsideRoot(.platformConfig))
    }

    func testSymbolicLinkedRootAliasResolvesToTheCanonicalRoot() throws {
        let fileSystem = tree()
        fileSystem.addSymbolicLink("/alias", to: "/state")
        let result = try XCTUnwrap(plan(resolve(
            RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/alias", isDirectory: true)),
            fileSystem: fileSystem
        )))

        XCTAssertEqual(result.root.path, "/state")
        XCTAssertEqual(result.journal.path, "/state/platform-state.json")
    }

    func testMissingRootIsRefusedAndNotCreated() throws {
        let fileSystem = FakeStateRootFileSystem()

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)), .rootMissing)
        XCTAssertEqual(try fileSystem.entryKind(at: "/state"), .missing)
    }

    func testMissingRootIsCreatedOnlyWhenTheCallerAsks() throws {
        let fileSystem = FakeStateRootFileSystem()
        _ = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem, createRoot: true)))

        XCTAssertEqual(try fileSystem.entryKind(at: "/state"), .directory)
    }

    func testMissingParentOfAConfigIsRefused() {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: URL(fileURLWithPath: "/state/nested/config.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)),
                       .parentUnavailable(.config, errno: ENOENT))
    }

    /// `/state/a` is a file, so `/state/a/b` names nothing. It is not a missing
    /// file that a later write would create.
    func testFileBeneathARegularFileIsRefusedAsAParentProblem() {
        let fileSystem = tree()
        fileSystem.addFile("/state/a")
        let environment = RuntimeEnvironment(
            configDirectory: state(), platformStateFile: URL(fileURLWithPath: "/state/a/journal.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)),
                       .parentUnavailable(.journal, errno: ENOTDIR))
    }

    /// Two writer roles that name one file: `preferences.json` links to the platform file.
    func testOverlappingWriterFilesAreRefused() {
        let fileSystem = tree()
        fileSystem.addFile("/state/platform.json")
        fileSystem.addSymbolicLink("/state/preferences.json", to: "/state/platform.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.platformConfig, .preferences))
    }

    /// Each fixed slot that links to a runtime resource is refused for that resource.
    func testReservedRuntimeNamesAreRefusedForWriterFiles() {
        let cases: [(slot: String, target: String, role: StateRootRole, resource: StateRootReservedName)] = [
            ("platform.json", "state-writer.lock", .platformConfig, .writerLock),
            ("platform-state.json", "control.sock", .journal, .controlSocket),
            ("config.json", "ready.json", .config, .readyFile),
        ]
        for testCase in cases {
            let fileSystem = tree()
            fileSystem.addFile("/state/\(testCase.target)")
            fileSystem.addSymbolicLink("/state/\(testCase.slot)", to: "/state/\(testCase.target)")
            XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                           .reservedName(testCase.role, testCase.resource), testCase.slot)
        }
    }

    /// A reserved name that is a directory cannot hold a writer file beneath it.
    func testWriterFileBeneathAReservedDirectoryIsRefused() {
        let fileSystem = tree()
        fileSystem.addDirectory("/state/daemon-ready.json")
        fileSystem.addFile("/state/daemon-ready.json/platform-state.json")
        fileSystem.addSymbolicLink("/state/platform-state.json", to: "/state/daemon-ready.json/platform-state.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .reservedName(.journal, .daemonReadyFile))
    }

    func testFilesystemRootIsRefusedAsAStateRoot() {
        let fileSystem = FakeStateRootFileSystem()
        fileSystem.addDirectory("/")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/")), fileSystem: fileSystem)),
                       .rootIsFilesystemRoot)
    }

    func testRootThatIsAFileIsRefused() {
        let fileSystem = FakeStateRootFileSystem()
        fileSystem.addFile("/state")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .rootNotDirectory)
    }

    // MARK: Case, object identity and hard links

    /// A case variant of a fixed slot is refused on a case-sensitive volume: it is a different name, not the slot.
    func testCaseSensitiveVolumeRefusesACaseVariantOfAFixedSlot() {
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("CONFIG.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: true))), .unsupportedFileName(.config))
    }

    /// A case alias of the fixed config leaf is the slot on a folding volume, and it resolves to the fixed spelling.
    func testCaseFoldingVolumeResolvesACaseAliasOfTheFixedSlot() throws {
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("CONFIG.json")
        )
        let result = try XCTUnwrap(plan(resolve(environment, fileSystem: tree(caseSensitive: false))))

        XCTAssertEqual(result.config.path, "/state/config.json")
    }

    /// An existing object reached through a case alias is the same object: a link to the folded config name overlaps it.
    func testCaseFoldingVolumeFusesAnExistingCaseAliasAsAnOverlap() {
        let fileSystem = tree(caseSensitive: false)
        fileSystem.addFile("/state/config.json")
        fileSystem.addSymbolicLink("/state/platform.json", to: "/state/CONFIG.JSON")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.config, .platformConfig))
    }

    /// A volume that answers nil refuses a case-only collision with the fixed slot. The fixed names alone still resolve.
    func testUnknownCaseSemanticsRefusesACaseOnlyCollisionAndNothingElse() throws {
        let collision = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("CONFIG.json")
        )
        XCTAssertEqual(refusal(resolve(collision, fileSystem: tree(caseSensitive: nil))), .caseSensitivityUnknown)

        _ = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: tree(caseSensitive: nil))))
    }

    /// Custom names that differ from the fixed slots only by Unicode case folding (final sigma, micro sign, long s) are
    /// not writable slots, on either case mode. They are refused before any file is read.
    func testCustomFoldedNamesAreRefusedBeforeAnyWritableAccess() {
        let names = ["\u{03C2}.json", "\u{00B5}.json", "\u{017F}tate.json"]
        for caseSensitive in [false, true] {
            for name in names {
                let environment = RuntimeEnvironment(
                    configDirectory: state(), platformConfigFile: state().appendingPathComponent(name)
                )
                XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: caseSensitive))),
                               .unsupportedFileName(.platformConfig), "\(name), caseSensitive: \(caseSensitive)")
            }
        }
    }

    /// Canonically equivalent spellings (precomposed and decomposed e-acute) are one name. A config link and a platform
    /// link to the two spellings overlap. The volume's normalization behavior is not queryable, so the layout refuses
    /// the pair on either case mode rather than guessing.
    func testCanonicallyEquivalentSpellingsAreOneName() {
        for caseSensitive in [false, true] {
            let fileSystem = tree(caseSensitive: caseSensitive)
            fileSystem.addFile("/state/caf\u{00E9}.json")
            fileSystem.addSymbolicLink("/state/config.json", to: "/state/caf\u{00E9}.json")
            fileSystem.addSymbolicLink("/state/platform.json", to: "/state/cafe\u{0301}.json")
            XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                           .overlap(.config, .platformConfig), "caseSensitive: \(caseSensitive)")
        }
    }

    /// A custom name that is a folded and canonically equivalent spelling of a slot is refused as a writable name.
    func testCustomFoldedAndCanonicalSpellingsAreRefusedAsWritableNames() {
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("CAF\u{00C9}.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: false))), .unsupportedFileName(.config))
    }

    /// An existing file reached through a folded link target is the same object.
    func testExistingFoldedAliasIsTheSameObjectOnAFoldingVolume() {
        let fileSystem = tree(caseSensitive: false)
        fileSystem.addFile("/state/preferences.json")
        fileSystem.addSymbolicLink("/state/config.json", to: "/state/PREFERENCES.JSON")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.config, .preferences))
    }

    /// A case query that fails is refused with its errno, not treated as an answer.
    func testCaseQueryFailureIsRefusedWithItsErrno() {
        let fileSystem = tree(caseSensitive: nil)
        fileSystem.failCaseQuery(errno: EIO)
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("CONFIG.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .caseSensitivityUnavailable(errno: EIO))
    }

    /// A reserved name is matched across case only on a folding volume: a link to the lock by its upper-case
    /// spelling is the lock there. On a case-sensitive volume that spelling names nothing, so the link dangles.
    func testReservedCaseAliasIsRefusedOnlyOnAFoldingVolume() {
        let folding = tree(caseSensitive: false)
        folding.addFile("/state/state-writer.lock")
        folding.addSymbolicLink("/state/platform.json", to: "/state/STATE-WRITER.LOCK")
        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: folding)),
                       .reservedName(.platformConfig, .writerLock))

        let sensitive = tree(caseSensitive: true)
        sensitive.addFile("/state/state-writer.lock")
        sensitive.addSymbolicLink("/state/platform.json", to: "/state/STATE-WRITER.LOCK")
        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: sensitive)),
                       .pathUnavailable(.platformConfig, errno: ENOENT))
    }

    /// A dangling link at a fixed slot does not resolve, as realpath(3) reports it: `pathUnavailable` with ENOENT,
    /// not a regular-file refusal. The missing target is not created.
    func testDanglingFixedSlotLinkIsRefusedAsAnUnresolvedPath() throws {
        let fileSystem = tree()
        fileSystem.addSymbolicLink("/state/config.json", to: "/state/absent.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .pathUnavailable(.config, errno: ENOENT))
        XCTAssertEqual(try fileSystem.entryKind(at: "/state/absent.json"), .missing)
    }

    /// The preflight is a pure check of the names, with no file system to call. It accepts the slot and a fold alias
    /// (the volume decides that later), and it refuses any other name for each writer role.
    func testPreflightAcceptsSlotSpellingsAndRefusesAnyOtherNameForEachRole() {
        let root = state()
        XCTAssertNoThrow(try StateRootLayout.preflightWritableNames(RuntimeEnvironment(configDirectory: root)))
        let folded = RuntimeEnvironment(
            configDirectory: root,
            configFile: root.appendingPathComponent("CONFIG.json"),
            platformStateFile: root.appendingPathComponent("Platform-State.JSON"),
            platformConfigFile: root.appendingPathComponent("Platform.JSON"),
            preferencesFile: root.appendingPathComponent("PREFERENCES.json")
        )
        XCTAssertNoThrow(try StateRootLayout.preflightWritableNames(folded))

        let custom = root.appendingPathComponent("alias.json")
        let cases: [(StateRootRole, RuntimeEnvironment)] = [
            (.config, RuntimeEnvironment(configDirectory: root, configFile: custom)),
            (.platformConfig, RuntimeEnvironment(configDirectory: root, platformConfigFile: custom)),
            (.preferences, RuntimeEnvironment(configDirectory: root, preferencesFile: custom)),
            (.journal, RuntimeEnvironment(configDirectory: root, platformStateFile: custom)),
        ]
        for (role, environment) in cases {
            XCTAssertThrowsError(try StateRootLayout.preflightWritableNames(environment)) { error in
                XCTAssertEqual(error as? StateRootFailure, .unsupportedFileName(role), "\(role)")
            }
        }
    }

    /// The root bound is PATH_MAX bytes with the terminator. A root of PATH_MAX - 1 bytes is accepted, and one of PATH_MAX
    /// is refused as ENAMETOOLONG before any effect, even when the file system would accept it.
    func testRootPathBoundIsPathMaxIncludingTheTerminator() throws {
        let longest = absolutePath(byteCount: Int(PATH_MAX) - 1)
        let fileSystem = FakeStateRootFileSystem()
        fileSystem.addDirectory(longest)
        XCTAssertEqual(try StateRootLayout.prepareRoot(longest, createIfMissing: false, fileSystem: fileSystem).path, longest)

        let tooLong = absolutePath(byteCount: Int(PATH_MAX))
        let log = StateRootEffectLog()
        let recording = RecordingStateRootFileSystem(FakeStateRootFileSystem(), log: log)
        XCTAssertThrowsError(try StateRootLayout.prepareRoot(tooLong, createIfMissing: true, fileSystem: recording)) { error in
            XCTAssertEqual(error as? StateRootFailure, .rootUnavailable(errno: ENAMETOOLONG))
        }
        XCTAssertEqual(log.effects, [], "an overlong root touches nothing")
    }

    /// A missing nested root is created with each missing ancestor, outermost first, on the fake too.
    func testMissingNestedRootCreatesItsAncestorsOnTheFake() throws {
        let fileSystem = FakeStateRootFileSystem()
        let nested = URL(fileURLWithPath: "/state/a/b", isDirectory: true)
        _ = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: nested), fileSystem: fileSystem, createRoot: true)))

        XCTAssertEqual(try fileSystem.entryKind(at: "/state"), .directory)
        XCTAssertEqual(try fileSystem.entryKind(at: "/state/a"), .directory)
        XCTAssertEqual(try fileSystem.entryKind(at: "/state/a/b"), .directory)
    }

    /// A file where an ancestor of a missing root belongs is refused, and nothing beneath it is created.
    func testNonDirectoryAncestorOfAMissingRootIsRefusedOnTheFake() throws {
        let fileSystem = tree()
        fileSystem.addFile("/state/a")
        let nested = URL(fileURLWithPath: "/state/a/b/c", isDirectory: true)

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: nested), fileSystem: fileSystem, createRoot: true)), .rootNotDirectory)
        XCTAssertEqual(try fileSystem.entryKind(at: "/state/a/b"), .missing)
    }

    /// An ancestor that cannot be examined is refused with its errno, not treated as missing.
    func testUnavailableAncestorOfAMissingRootIsRefusedWithItsErrno() {
        let fileSystem = tree()
        fileSystem.failPath("/state/a", errno: EACCES)
        let nested = URL(fileURLWithPath: "/state/a/b", isDirectory: true)

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: nested), fileSystem: fileSystem, createRoot: true)),
                       .rootUnavailable(errno: EACCES))
    }

    /// A link is refused when its target is another role's file: the target is the identity.
    func testSymbolicLinkToAnotherRoleIsAnOverlap() {
        let fileSystem = tree()
        fileSystem.addFile("/state/platform.json")
        fileSystem.addSymbolicLink("/state/preferences.json", to: "/state/platform.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.platformConfig, .preferences))
    }

    /// A link whose target is another case of the same file is still that file.
    func testSymbolicLinkToACaseAliasIsAnOverlapOnAFoldingVolume() {
        let fileSystem = tree(caseSensitive: false)
        fileSystem.addFile("/state/platform.json")
        fileSystem.addSymbolicLink("/state/preferences.json", to: "/state/PLATFORM.JSON")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.platformConfig, .preferences))
    }

    /// Two roles that are hard links of one object overlap.
    func testHardLinkBetweenTwoRolesIsAnOverlap() {
        let fileSystem = tree()
        fileSystem.addFile("/state/platform.json")
        fileSystem.addHardLink("/state/preferences.json", to: "/state/platform.json")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .overlap(.platformConfig, .preferences))
    }

    /// A hard link to a name that no role uses is not refused.
    func testHardLinkToAnUnclaimedNameIsNotRefused() throws {
        let fileSystem = tree()
        fileSystem.addFile("/state/platform.json")
        fileSystem.addHardLink("/state/unclaimed.json", to: "/state/platform.json")
        let result = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)))

        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
    }

    /// A writer file that is a hard link of the lock file is the lock.
    func testHardLinkToTheLockFileIsAReservedName() {
        let fileSystem = tree()
        fileSystem.addFile("/state/state-writer.lock")
        fileSystem.addHardLink("/state/platform.json", to: "/state/state-writer.lock")

        XCTAssertEqual(refusal(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)),
                       .reservedName(.platformConfig, .writerLock))
    }

    // MARK: Read-only input

    /// The input-only host resolves the root and its input, and no sidecar.
    func testUnusedSidecarDoesNotRefuseReadOnlyInput() throws {
        let fileSystem = tree()
        fileSystem.addDirectory("/state/preferences.json")
        fileSystem.addFile("/elsewhere/config.json")
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: URL(fileURLWithPath: "/elsewhere/config.json")
        )

        XCTAssertEqual(refusal(resolve(environment, .readOnlyInput, fileSystem: fileSystem)),
                       .notRegularFile(.preferences))
        let input = try StateRootLayout.resolveReadOnlyInput(environment, fileSystem: fileSystem)
        XCTAssertEqual(input.root.path, "/state")
        XCTAssertEqual(input.config.path, "/elsewhere/config.json")
    }

    /// The input is never a runtime resource: a name in the root, or an outside
    /// file that is hard-linked to one, would be overwritten by the runtime.
    func testReadOnlyInputThatIsAReservedResourceIsRefused() {
        let inside = RuntimeEnvironment(configDirectory: state(), configFile: state().appendingPathComponent("ready.json"))
        XCTAssertEqual(inputRefusal(inside, fileSystem: tree()), .reservedName(.config, .readyFile))

        let linked = tree()
        linked.addFile("/elsewhere/config.json")
        linked.addHardLink("/state/ready.json", to: "/elsewhere/config.json")
        let outside = RuntimeEnvironment(
            configDirectory: state(), configFile: URL(fileURLWithPath: "/elsewhere/config.json")
        )
        XCTAssertEqual(inputRefusal(outside, fileSystem: linked), .reservedName(.config, .readyFile))
    }

    private func inputRefusal(_ environment: RuntimeEnvironment, fileSystem: FakeStateRootFileSystem) -> StateRootFailure? {
        do {
            _ = try StateRootLayout.resolveReadOnlyInput(environment, fileSystem: fileSystem)
        } catch {
            return error
        }
        XCTFail("expected a refusal")
        return nil
    }
}
