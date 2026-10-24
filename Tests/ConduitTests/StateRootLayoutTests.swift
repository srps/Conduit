// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The root layout over a scripted tree (decision 0020). The real-file-system
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
        let fileSystem = tree()
        let result = try XCTUnwrap(plan(resolve(RuntimeEnvironment(configDirectory: state()), fileSystem: fileSystem)))

        XCTAssertEqual(result.root.path, "/state")
        XCTAssertEqual(result.config.path, "/state/config.json")
        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
        XCTAssertEqual(result.preferences.path, "/state/preferences.json")
        XCTAssertEqual(result.journal.path, "/state/platform-state.json")
        XCTAssertEqual(result.configAccess, .writerOwned)
    }

    func testCustomConfigNameInsideTheRootIsAccepted() throws {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("my-config.json")
        )
        let result = try XCTUnwrap(plan(resolve(environment, fileSystem: fileSystem)))

        XCTAssertEqual(result.config.path, "/state/my-config.json")
        XCTAssertEqual(result.root.path, "/state")
    }

    /// `--config` alone: the file's parent is the root, and the other three
    /// files default beside it. This is the compatibility case that must not
    /// change to a fixed `config.json` basename.
    func testExplicitConfigParentBecomesTheRoot() throws {
        let fileSystem = tree()
        let environment = RuntimeEnvironment.explicit(configFile: state().appendingPathComponent("custom.json"))
        let result = try XCTUnwrap(plan(resolve(environment, fileSystem: fileSystem)))

        XCTAssertEqual(result.root.path, "/state")
        XCTAssertEqual(result.config.path, "/state/custom.json")
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

    func testOverlappingWriterFilesAreRefused() {
        let fileSystem = tree()
        let environment = RuntimeEnvironment(
            configDirectory: state(), preferencesFile: URL(fileURLWithPath: "/state/platform.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)),
                       .overlap(.platformConfig, .preferences))
    }

    func testReservedRuntimeNamesAreRefusedForWriterFiles() {
        let fileSystem = tree()
        let cases: [(RuntimeEnvironment, StateRootFailure)] = [
            (RuntimeEnvironment(configDirectory: state(),
                                platformConfigFile: URL(fileURLWithPath: "/state/state-writer.lock")),
             .reservedName(.platformConfig, .writerLock)),
            (RuntimeEnvironment(configDirectory: state(),
                                platformStateFile: URL(fileURLWithPath: "/state/control.sock")),
             .reservedName(.journal, .controlSocket)),
            (RuntimeEnvironment(configDirectory: state(), configFile: URL(fileURLWithPath: "/state/ready.json")),
             .reservedName(.config, .readyFile)),
        ]
        for (environment, expected) in cases {
            XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), expected)
        }
    }

    /// A reserved name that is a directory cannot hold a writer file beneath it.
    func testWriterFileBeneathAReservedDirectoryIsRefused() {
        let fileSystem = tree()
        fileSystem.addDirectory("/state/daemon-ready.json")
        let environment = RuntimeEnvironment(
            configDirectory: state(),
            platformStateFile: URL(fileURLWithPath: "/state/daemon-ready.json/platform-state.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)),
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

    /// On a case-sensitive volume two spellings are two names, and both may be used.
    func testCaseSensitiveVolumeKeepsCaseDistinctNamesApart() throws {
        let fileSystem = tree(caseSensitive: true)
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("Platform.json")
        )
        let result = try XCTUnwrap(plan(resolve(environment, fileSystem: fileSystem)))

        XCTAssertEqual(result.config.path, "/state/Platform.json")
        XCTAssertEqual(result.platformConfig.path, "/state/platform.json")
    }

    /// Missing names that differ by case alone are one file on a folding volume.
    func testCaseFoldingVolumeFusesMissingCaseAliases() {
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("Platform.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: false))),
                       .overlap(.config, .platformConfig))
    }

    /// An existing case alias is the same object, whatever its spelling.
    func testCaseFoldingVolumeFusesAnExistingCaseAlias() {
        let fileSystem = tree(caseSensitive: false)
        fileSystem.addFile("/state/platform.json")
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("PLATFORM.JSON")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .overlap(.config, .platformConfig))
    }

    /// A volume that answers nil refuses a case-only collision. Distinct names still resolve.
    func testUnknownCaseSemanticsRefusesACaseOnlyCollisionAndNothingElse() throws {
        let collision = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("Platform.json")
        )
        XCTAssertEqual(refusal(resolve(collision, fileSystem: tree(caseSensitive: nil))), .caseSensitivityUnknown)

        let distinct = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("custom.json")
        )
        _ = try XCTUnwrap(plan(resolve(distinct, fileSystem: tree(caseSensitive: nil))))
    }

    /// Missing names that match only after Unicode case folding are one file on a
    /// folding volume: final sigma, micro sign and long s. The `lowercased()`
    /// comparison this replaced missed each of them.
    func testCaseFoldingVolumeFusesMissingFoldedAliases() {
        let cases: [(config: String, platform: String)] = [
            ("\u{03C2}.json", "\u{03A3}.json"),
            ("\u{00B5}.json", "\u{03BC}.json"),
            ("\u{017F}tate.json", "state.json"),
        ]
        for (config, platform) in cases {
            let environment = RuntimeEnvironment(
                configDirectory: state(),
                configFile: state().appendingPathComponent(config),
                platformConfigFile: state().appendingPathComponent(platform)
            )
            XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: false))),
                           .overlap(.config, .platformConfig), "\(config) against \(platform)")
        }
    }

    /// On a case-sensitive volume the folded spellings are four distinct names,
    /// and all four may be used together.
    func testCaseSensitiveVolumeKeepsFoldedSpellingsApart() throws {
        let environment = RuntimeEnvironment(
            configDirectory: state(),
            configFile: state().appendingPathComponent("\u{03C2}.json"),
            platformStateFile: state().appendingPathComponent("\u{00B5}.json"),
            platformConfigFile: state().appendingPathComponent("\u{03A3}.json"),
            preferencesFile: state().appendingPathComponent("\u{03BC}.json")
        )
        let result = try XCTUnwrap(plan(resolve(environment, fileSystem: tree(caseSensitive: true))))

        XCTAssertEqual(result.config.path, "/state/\u{03C2}.json")
        XCTAssertEqual(result.platformConfig.path, "/state/\u{03A3}.json")
        XCTAssertEqual(result.preferences.path, "/state/\u{03BC}.json")
        XCTAssertEqual(result.journal.path, "/state/\u{00B5}.json")
    }

    /// A volume that does not answer refuses a folded collision, and only that.
    func testUnknownCaseSemanticsRefusesAFoldedCollisionOfFinalSigma() {
        let environment = RuntimeEnvironment(
            configDirectory: state(),
            configFile: state().appendingPathComponent("\u{03C2}.json"),
            platformConfigFile: state().appendingPathComponent("\u{03A3}.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: nil))), .caseSensitivityUnknown)
    }

    /// Canonically equivalent spellings (precomposed and decomposed e-acute) are one
    /// name. The volume's normalization behavior is not queryable, so the layout
    /// refuses the pair on either case mode rather than guessing.
    func testCanonicallyEquivalentSpellingsAreOneName() {
        for caseSensitive in [false, true] {
            let environment = RuntimeEnvironment(
                configDirectory: state(),
                configFile: state().appendingPathComponent("caf\u{00E9}.json"),
                platformConfigFile: state().appendingPathComponent("cafe\u{0301}.json")
            )
            XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: caseSensitive))),
                           .overlap(.config, .platformConfig), "caseSensitive: \(caseSensitive)")
        }
    }

    /// A folded and a canonically equivalent spelling of one name are one file on a
    /// folding volume: upper-case `CAFÉ` (precomposed) against `cafe` plus a combining accent.
    func testFoldedAndCanonicallyEquivalentSpellingsAreOneNameOnAFoldingVolume() {
        let environment = RuntimeEnvironment(
            configDirectory: state(),
            configFile: state().appendingPathComponent("CAF\u{00C9}.json"),
            platformConfigFile: state().appendingPathComponent("cafe\u{0301}.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: false))),
                       .overlap(.config, .platformConfig))
    }

    /// An existing file reached through a folded spelling is the same object.
    func testExistingFoldedAliasIsTheSameObjectOnAFoldingVolume() {
        let fileSystem = tree(caseSensitive: false)
        fileSystem.addFile("/state/preferences.json")
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("preference\u{017F}.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)), .overlap(.config, .preferences))
    }

    /// A case query that fails is refused with its errno, not treated as an answer.
    func testCaseQueryFailureIsRefusedWithItsErrno() {
        let fileSystem = tree(caseSensitive: nil)
        fileSystem.failCaseQuery(errno: EIO)
        let environment = RuntimeEnvironment(
            configDirectory: state(), configFile: state().appendingPathComponent("Platform.json")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: fileSystem)),
                       .caseSensitivityUnavailable(errno: EIO))
    }

    /// A reserved name is matched across case only on a folding volume.
    func testReservedCaseAliasIsRefusedOnlyOnAFoldingVolume() {
        let environment = RuntimeEnvironment(
            configDirectory: state(), platformConfigFile: state().appendingPathComponent("State-Writer.LOCK")
        )

        XCTAssertEqual(refusal(resolve(environment, fileSystem: tree(caseSensitive: false))),
                       .reservedName(.platformConfig, .writerLock))
        _ = plan(resolve(environment, fileSystem: tree(caseSensitive: true)))
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
