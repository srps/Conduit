// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class StateWriterReviewRegressionTests: XCTestCase {
    func testReleaseUnknownRemainsUnknownOnRepeat() {
        let lease = StateWriterLease(
            root: CanonicalStateRoot(canonicalPath: "/owned-fixture"),
            onReleaseFailure: { _ in XCTFail("explicit release must return its failure") },
            close: { .releaseUnknown(errno: EINTR) }
        )
        XCTAssertEqual(lease.release(), .releaseUnknown(errno: EINTR))
        XCTAssertEqual(lease.release(), .releaseUnknown(errno: EINTR),
                       "a repeat must not turn an uncertain release into alreadyReleased")
    }

    /// A link to an existing case alias of the platform file is that file, so the two roles overlap.
    func testExistingCaseAliasesCannotNameTwoComponents() throws {
        try withRoot { root in
            try Data("fixture".utf8).write(to: root.appendingPathComponent("platform.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("preferences.json"),
                withDestinationURL: root.appendingPathComponent("PLATFORM.JSON"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .overlap(.platformConfig, .preferences))
            }
        }
    }

    /// A missing case alias of a fixed slot is the slot, so it names the fixed file and cannot be a second one.
    func testMissingCaseAliasOfAFixedSlotResolvesToTheSlot() throws {
        try withRoot { root in
            let plan = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root,
                configFile: root.appendingPathComponent("CONFIG.json")),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())
            XCTAssertEqual(plan.config.path, try OSStateRootFileSystem().canonicalPath(of: root.path) + "/config.json")
        }
    }

    // MARK: Release outcomes under concurrency and drop

    /// Concurrent releases of one unconfirmed close run that close once, and every
    /// caller gets its outcome. None reports `alreadyReleased` while it is unresolved.
    func testConcurrentReleasesShareOneUnconfirmedCloseAndNeverReportAlreadyReleased() {
        let closes = Recorder<Void>()
        let lease = StateWriterLease(
            root: CanonicalStateRoot(canonicalPath: "/owned-fixture"),
            onReleaseFailure: { _ in XCTFail("explicit release must return its failure") },
            close: {
                closes.record(())
                return .releaseUnknown(errno: EINTR)
            }
        )
        let outcomes = Recorder<StateWriterRelease>()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            outcomes.record(lease.release())
        }

        XCTAssertEqual(closes.values.count, 1)
        XCTAssertEqual(outcomes.values, Array(repeating: StateWriterRelease.releaseUnknown(errno: EINTR), count: 8))
    }

    /// A confirmed close is reported once as `released`. Every other caller is a
    /// repeat, so it gets `alreadyReleased`.
    func testConcurrentReleasesOfAConfirmedCloseReturnReleasedOnce() {
        let closes = Recorder<Void>()
        let lease = StateWriterLease(
            root: CanonicalStateRoot(canonicalPath: "/owned-fixture"),
            onReleaseFailure: { _ in XCTFail("a confirmed close reports no failure") },
            close: {
                closes.record(())
                return .released
            }
        )
        let outcomes = Recorder<StateWriterRelease>()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            outcomes.record(lease.release())
        }

        XCTAssertEqual(closes.values.count, 1)
        XCTAssertEqual(outcomes.values.filter { $0 == .released }.count, 1)
        XCTAssertEqual(outcomes.values.filter { $0 == .alreadyReleased }.count, 7)
    }

    /// An unconfirmed explicit release goes to its caller. Dropping that lease
    /// afterward neither reports it again nor closes it again.
    func testUnconfirmedExplicitReleaseIsNotReportedAgainWhenDropped() {
        let closes = Recorder<Void>()
        let reports = Recorder<StateWriterReleaseFailure>()
        releaseUnconfirmedThenDrop(closes: closes, reports: reports)

        XCTAssertEqual(closes.values.count, 1)
        XCTAssertEqual(reports.values, [])
    }

    /// A lease dropped without a release closes once, and its unconfirmed close is
    /// reported once, through the callback, with the root and errno.
    func testDroppedLeaseWithAnUnconfirmedCloseReportsOnce() {
        let root = CanonicalStateRoot(canonicalPath: "/owned-fixture")
        let reports = Recorder<StateWriterReleaseFailure>()
        _ = StateWriterLease(root: root, onReleaseFailure: { reports.record($0) }, close: { .releaseUnknown(errno: EIO) })

        XCTAssertEqual(reports.values, [StateWriterReleaseFailure(root: root, errno: EIO)])
    }

    private func releaseUnconfirmedThenDrop(closes: Recorder<Void>, reports: Recorder<StateWriterReleaseFailure>) {
        let lease = StateWriterLease(
            root: CanonicalStateRoot(canonicalPath: "/owned-fixture"),
            onReleaseFailure: { reports.record($0) },
            close: {
                closes.record(())
                return .releaseUnknown(errno: EINTR)
            }
        )
        XCTAssertEqual(lease.release(), .releaseUnknown(errno: EINTR))
    }

    // MARK: Real file-system identity, aliases and links

    /// On a case-insensitive volume `STATE-WRITER.LOCK` is the lock file, so it is
    /// refused as the platform file before the lock exists.
    func testReservedCaseAliasIsRefusedOnACaseInsensitiveVolume() throws {
        try withRoot { root in
            try Data().write(to: root.appendingPathComponent("state-writer.lock"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("platform.json"),
                withDestinationURL: root.appendingPathComponent("STATE-WRITER.LOCK"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .reservedName(.platformConfig, .writerLock))
            }
        }
    }

    /// An existing reserved file is matched by its object, so a link to `READY.JSON` is `ready.json`.
    func testExistingReservedCaseAliasIsRefusedOnACaseInsensitiveVolume() throws {
        try withRoot { root in
            try Data("ready".utf8).write(to: root.appendingPathComponent("ready.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                withDestinationURL: root.appendingPathComponent("READY.JSON"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .reservedName(.config, .readyFile))
            }
        }
    }

    /// A symbolic link to another role's file is that file. Their roles overlap.
    func testSymbolicLinkToAnotherRoleIsAnOverlap() throws {
        let directory = try StateRootScratch.make("review-link")
        defer { StateRootScratch.remove(directory) }
        try Data("one".utf8).write(to: directory.appendingPathComponent("platform.json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("preferences.json"),
            withDestinationURL: directory.appendingPathComponent("platform.json")
        )

        XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: directory),
            configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
            XCTAssertEqual($0 as? StateRootFailure, .overlap(.platformConfig, .preferences))
        }
    }

    /// Two roles that are hard links of one object overlap. The root has no blanket
    /// hard-link ban: a link to a name no role uses is not refused.
    func testHardLinkBetweenTwoRolesIsAnOverlapAndAnUnclaimedHardLinkIsNot() throws {
        let directory = try StateRootScratch.make("review-hardlink")
        defer { StateRootScratch.remove(directory) }
        let platform = directory.appendingPathComponent("platform.json")
        try Data("one".utf8).write(to: platform)

        XCTAssertEqual(Darwin.link(platform.path, directory.appendingPathComponent("unclaimed.json").path), 0)
        let plan = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: directory),
            configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())
        XCTAssertEqual(plan.platformConfig.path, try StateRootScratch.canonicalRoot(directory).path + "/platform.json")

        XCTAssertEqual(Darwin.link(platform.path, directory.appendingPathComponent("preferences.json").path), 0)
        XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: directory),
            configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
            XCTAssertEqual($0 as? StateRootFailure, .overlap(.platformConfig, .preferences))
        }
    }

    /// An unused sidecar directory does not refuse a headless host. It resolves the
    /// root and its external config, takes the root's lease, and leaves the sidecar alone.
    func testUnusedSidecarDirectoryDoesNotBlockAHeadlessLease() throws {
        let directory = try StateRootScratch.make("review-headless")
        defer { StateRootScratch.remove(directory) }
        let state = directory.appendingPathComponent("state", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sidecar = state.appendingPathComponent("preferences.json", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let config = outside.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)

        let plan = try StateRootLayout.resolveReadOnlyInput(
            RuntimeEnvironment(configDirectory: state, configFile: config), fileSystem: OSStateRootFileSystem()
        )
        let outcome = OSStateWriterLeasing().acquire(root: plan.root, onReleaseFailure: { _ in
            XCTFail("the headless lease reported a close failure")
        })
        guard case .acquired(let lease) = outcome else {
            XCTFail("expected the headless root to be acquired, got \(outcome)")
            return
        }
        XCTAssertEqual(lease.release(), .released)
        XCTAssertEqual(plan.config.path, try OSStateRootFileSystem().canonicalPath(of: config.path))
        XCTAssertEqual(try OSStateRootFileSystem().entryKind(at: sidecar.path), .directory)
    }

    /// A config link whose target is a long-s alias of the lock file is the lock: it is refused as a reserved name.
    func testMissingUnicodeCaseAliasCannotReplaceTheWriterLock() throws {
        try withRoot { root in
            try Data().write(to: root.appendingPathComponent("state-writer.lock"))
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ſtate-writer.lock").path) else {
                throw XCTSkip("fixture volume does not fold long s")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                withDestinationURL: root.appendingPathComponent("ſtate-writer.lock"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .reservedName(.config, .writerLock))
            }
        }
    }

    /// A config link whose target is a long-s alias of the preferences file is that file, so the roles overlap.
    func testMissingUnicodeCaseAliasCannotOverlapPreferences() throws {
        try withRoot { root in
            try Data().write(to: root.appendingPathComponent("preferences.json"))
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("preferenceſ.json").path) else {
                throw XCTSkip("fixture volume does not fold long s")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                withDestinationURL: root.appendingPathComponent("preferenceſ.json"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .overlap(.config, .preferences))
            }
        }
    }

    /// Final sigma (U+03C2) is the platform file's sigma (U+03A3) on APFS, so the
    /// missing config name is refused as the same file. Lowercasing kept them apart.
    func testMissingFinalSigmaAliasCannotOverlapThePlatformFile() throws {
        try withRoot { root in
            try Data().write(to: root.appendingPathComponent("\u{03A3}.json"))
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("\u{03C2}.json").path) else {
                throw XCTSkip("fixture volume does not fold final sigma")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                withDestinationURL: root.appendingPathComponent("\u{03A3}.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("platform.json"),
                withDestinationURL: root.appendingPathComponent("\u{03C2}.json"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .overlap(.config, .platformConfig))
            }
        }
    }

    /// Micro sign (U+00B5) is the Greek small mu (U+03BC) on APFS, so the two missing
    /// names are one file.
    func testMissingMicroSignAliasCannotOverlapTheGreekMu() throws {
        try withRoot { root in
            try Data().write(to: root.appendingPathComponent("\u{03BC}.json"))
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("\u{00B5}.json").path) else {
                throw XCTSkip("fixture volume does not fold micro sign")
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.json"),
                withDestinationURL: root.appendingPathComponent("\u{00B5}.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("platform.json"),
                withDestinationURL: root.appendingPathComponent("\u{03BC}.json"))
            XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: root),
                configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())) {
                XCTAssertEqual($0 as? StateRootFailure, .overlap(.config, .platformConfig))
            }
        }
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("owned fixture cleanup failed: \(error)") }
        }
        let flags = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard flags.volumeSupportsCaseSensitiveNames == false else {
            throw XCTSkip("case-alias checks require a case-insensitive fixture volume")
        }
        try body(root)
    }
}

/// Collects values from concurrent calls. The test reads them after the calls return.
private final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var values: [Element] { lock.withLock { items } }

    func record(_ item: Element) {
        lock.withLock { items.append(item) }
    }
}
