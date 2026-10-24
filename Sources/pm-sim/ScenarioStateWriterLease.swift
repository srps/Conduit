// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

/// `state-writer-lease` (decisions 0017 and 0020): the real flock adapter and
/// the real root layout over an owned scratch directory. It checks the claims a
/// store will rely on. A second holder is busy. An alias of the same root is the
/// same root. Atomically replacing a data file does not move the lock. A config
/// outside the root is refused for writing and accepted as read-only input. A
/// released root can be acquired again. Nothing here migrates, reconciles or
/// touches a production root, and no child process is started.
enum StateWriterLeaseScenario {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-state-writer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { fputs("state-writer-lease cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let state = scratch.appendingPathComponent("state", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        let alias = scratch.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state)

        let fileSystem = OSStateRootFileSystem()
        let leasing = OSStateWriterLeasing()
        let reportedCloseFailures = NIOLockedValueBox<[StateWriterReleaseFailure]>([])
        let report: @Sendable (StateWriterReleaseFailure) -> Void = { failure in
            reportedCloseFailures.withLockedValue { $0.append(failure) }
        }
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }

        let canonicalState = try fileSystem.canonicalPath(of: state.path)
        let canonicalOutside = try fileSystem.canonicalPath(of: outside.path)
        let lockPath = canonicalState + "/" + OSStateWriterLeasing.lockFileName
        let platformFile = state.appendingPathComponent("platform.json")
        try Data("one".utf8).write(to: platformFile)

        // Custom config name, root named through a symbolic link.
        let aliased = resolve(
            RuntimeEnvironment(configDirectory: alias, configFile: alias.appendingPathComponent("custom-config.json")),
            access: .writerOwned, fileSystem: fileSystem
        )
        check("alias of the state directory resolves to the canonical root",
              value(aliased)?.root.path == canonicalState)
        check("custom config name inside the root is accepted",
              value(aliased)?.config.path == canonicalState + "/custom-config.json")

        guard let plan = value(aliased) else {
            notes.append("layout refused the alias: \(String(describing: failure(aliased)))")
            return finish(began, assertions, notes)
        }
        guard case .acquired(let first) = leasing.acquire(root: plan.root, onReleaseFailure: report) else {
            notes.append("first acquisition did not take the root")
            return finish(began, assertions, notes)
        }
        check("first acquisition takes the root", true)

        let realRoot = value(resolve(RuntimeEnvironment(configDirectory: state), access: .writerOwned, fileSystem: fileSystem))
        if let realRoot {
            let second = leasing.acquire(root: realRoot.root, onReleaseFailure: report)
            switch second {
            case .busy: check("the real path of a held root is busy, not a second lease", true)
            case .acquired(let extra):
                check("the real path of a held root is busy, not a second lease", false)
                _ = extra.release()
            case .failed(let failure):
                check("the real path of a held root is busy, not a second lease", false)
                notes.append("second attempt failed: \(failure)")
            }
        } else {
            check("the real state directory resolves while held", false)
        }

        // Atomic data replacement moves the data file's inode, not the lock's.
        let dataBefore = identity(platformFile.path)
        let lockBefore = identity(lockPath)
        try Data("two".utf8).write(to: platformFile, options: .atomic)
        check("atomic replacement moved the data file to a new inode",
              dataBefore != nil && dataBefore != identity(platformFile.path))
        check("the lock file keeps its inode through the replacement",
              lockBefore != nil && lockBefore == identity(lockPath))
        if case .acquired(let extra) = leasing.acquire(root: plan.root, onReleaseFailure: report) {
            check("the root is still busy after an atomic data replacement", false)
            _ = extra.release()
        } else {
            check("the root is still busy after an atomic data replacement", true)
        }

        // A config outside the root: writer refusal, read-only acceptance.
        let splitEnvironment = RuntimeEnvironment(
            configDirectory: state, configFile: outside.appendingPathComponent("config.json")
        )
        check("writer refuses a config outside its root",
              failure(resolve(splitEnvironment, access: .writerOwned, fileSystem: fileSystem)) == .outsideRoot(.config))
        check("read-only input accepts the same outside config",
              value(resolve(splitEnvironment, access: .readOnlyInput, fileSystem: fileSystem))?.config.path
                  == canonicalOutside + "/config.json")

        // Overlapping authoritative files, and a root that does not exist.
        let overlapping = RuntimeEnvironment(
            configDirectory: state, preferencesFile: platformFile
        )
        check("preferences sharing the platform file is an overlap",
              failure(resolve(overlapping, access: .writerOwned, fileSystem: fileSystem))
                  == .overlap(.platformConfig, .preferences))
        check("a missing root is refused, not created",
              failure(resolve(RuntimeEnvironment(configDirectory: scratch.appendingPathComponent("missing")),
                              access: .writerOwned, fileSystem: fileSystem)) == .rootMissing)

        check("release reports released", first.release() == .released)
        check("a repeated release is alreadyReleased", first.release() == .alreadyReleased)
        if case .acquired(let again) = leasing.acquire(root: plan.root, onReleaseFailure: report) {
            check("the released root can be acquired again", true)
            check("the second lease releases cleanly", again.release() == .released)
        } else {
            check("the released root can be acquired again", false)
        }
        check("the lock file survives release on the same inode", identity(lockPath) == lockBefore)
        let closeFailures = reportedCloseFailures.withLockedValue { $0.count }
        check("no close failure was reported to the destructor sink", closeFailures == 0)
        return finish(began, assertions, notes)
    }

    private static func finish(_ began: Date, _ assertions: [ScenarioAssertion], _ notes: [String]) -> ScenarioResult {
        ScenarioResult(
            name: "state-writer-lease", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions.isEmpty ? [.init("scenario produced assertions", false)] : assertions,
            notes: notes
        )
    }

    private static func resolve(
        _ environment: RuntimeEnvironment,
        access: StateRootConfigAccess,
        fileSystem: any StateRootFileSystem
    ) -> Result<StateRootPlan, StateRootFailure> {
        do { return .success(try StateRootLayout.resolve(environment, configAccess: access, fileSystem: fileSystem)) }
        catch { return .failure(error) }
    }

    private static func value(_ result: Result<StateRootPlan, StateRootFailure>) -> StateRootPlan? {
        if case .success(let plan) = result { return plan }
        return nil
    }

    private static func failure(_ result: Result<StateRootPlan, StateRootFailure>) -> StateRootFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}
