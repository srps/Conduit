// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

/// `runtime-file-replacement` (decisions 0015, 0017, 0020 and 0021): the verified replacement of the runtime configuration
/// file over the real OS adapter in a scratch directory, and over the fake file access for the read-back results a volume
/// cannot produce on demand. It checks the refusals that come before any I/O, a symbolic-link target, a directory prior, the
/// approved budget, a write that threw after landing, an unchanged larger prior and an ambiguous read-back. Every file comes
/// from `StateRootLayout`, because `StateRootFile` has no initializer outside PlatformMac. Cleanup releases the lease first.
/// The scratch root is removed only after a confirmed release, and a cleanup failure fails the verdict. Nothing outside the
/// scratch directory is touched, and no socket is opened.
enum RuntimeFileReplacementScenario {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-runtime-replace-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let verdict = Verdict()
        let leases = LeaseBox()
        do {
            try exercise(scratch: scratch, leases: leases, verdict: verdict)
        } catch {
            verdict.check("the scenario ran to completion", false)
            verdict.note("the scenario stopped: \(error.localizedDescription)")
        }
        cleanUp(scratch: scratch, leases: leases, verdict: verdict)
        return ScenarioResult(
            name: "runtime-file-replacement", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: verdict.assertions.isEmpty ? [.init("scenario produced assertions", false)] : verdict.assertions,
            notes: verdict.notes
        )
    }

    private static func exercise(scratch: URL, leases: LeaseBox, verdict: Verdict) throws {
        let state = scratch.appendingPathComponent("state", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)

        let fileSystem = OSStateRootFileSystem()
        let plan = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("config.json")),
            configAccess: .writerOwned,
            fileSystem: fileSystem
        )
        let root = plan.root
        func contents(_ path: String) -> Data? {
            do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
            catch {
                verdict.note("read of a scratch file failed: \(error.localizedDescription)")
                return nil
            }
        }
        func kind(_ path: String) -> StateRootEntryKind? {
            do { return try fileSystem.entryKind(at: path) }
            catch {
                verdict.note("status of a scratch entry failed: errno \(error.errno)")
                return nil
            }
        }

        leases.attempted = true
        let outcome = OSStateWriterLeasing().acquire(root: root, onReleaseFailure: { failure in
            fputs("runtime-file-replacement close unconfirmed: errno \(failure.errno)\n", stderr)
        })
        guard case .acquired(let held) = outcome else {
            verdict.check("the scratch root is acquired for the replacement", false)
            return
        }
        // Recorded before any check, so cleanup releases it whatever step below fails.
        leases.lease = held

        let staged = Data("staged-config".utf8)
        let budget = ConfigurationFileReader.maximumBytes
        // Every file the scenario replaces comes from the layout, so each path is the one a writer would resolve.
        let config = plan.config
        let fakeFile = plan.config
        let osAccess = StateFileAccess.operatingSystem()
        // The baseline is observed through the same reader the replacement's pre-read uses. A file that cannot be observed has no
        // baseline; the sentinel is not a claim, because the pre-read repeats the read and reports its failure before any compare.
        func observedBaseline(_ file: StateRootFile) -> ConfigurationFileBaseline {
            switch VerifiedConfigurationFileReplacement.observe(file, access: osAccess) {
            case .observed(let input): return ConfigurationFileBaseline(observing: input)
            case .refused, .notObserved: return ConfigurationFileBaseline(observing: .present(Data()))
            }
        }
        func replaceOnDisk(_ bytes: Data, _ file: StateRootFile) -> ConfigurationFileReplacementOutcome {
            VerifiedConfigurationFileReplacement.replace(bytes, at: file, under: held, access: osAccess, expecting: observedBaseline(file))
        }
        func classify(_ fake: FakeStateFileAccess, expecting baseline: ConfigurationFileBaseline) -> ConfigurationFileReplacementOutcome {
            VerifiedConfigurationFileReplacement.replace(staged, at: fakeFile, under: held, access: fake, expecting: baseline)
        }

        // Real OS: create, overwrite with a larger prior, and the refusal before any I/O for an oversize staged value.
        verdict.check("a missing config is created and read back as the staged bytes",
                      replaceOnDisk(staged, config) == .verifiedPersisted(writeError: nil) && contents(config.path) == staged)
        try Data(repeating: 0x4C, count: 64).write(to: URL(fileURLWithPath: config.path))
        verdict.check("a larger prior is replaced by the staged bytes",
                      replaceOnDisk(staged, config) == .verifiedPersisted(writeError: nil) && contents(config.path) == staged)
        // The refusals below pass a fixed baseline and a counting fake, so no read runs before the refusal. The fake records every read and
        // write, so an empty log proves that no I/O reached the root.
        let fixedBaseline = ConfigurationFileBaseline(observing: .missing)
        let oversizeAccess = FakeStateFileAccess(files: [:])
        verdict.check("staged bytes one over the budget are refused before any I/O",
                      VerifiedConfigurationFileReplacement.replace(Data(count: budget + 1), at: config, under: held, access: oversizeAccess, expecting: fixedBaseline)
                          == .refused(.stagedTooLarge(limit: budget))
                          && oversizeAccess.observations.isEmpty && contents(config.path) == staged)

        // Real OS: a symbolic-link config is written at its resolved target, and the link is kept.
        let realTarget = state.appendingPathComponent("real-config.json")
        try Data("old".utf8).write(to: realTarget)
        let link = state.appendingPathComponent("linked-config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realTarget)
        let linked = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: state, configFile: link),
            configAccess: .writerOwned,
            fileSystem: fileSystem
        )
        verdict.check("a symbolic-link config resolves to its target inside the root",
                      linked.config.path == root.path + "/real-config.json")
        verdict.check("the write lands on the resolved target",
                      replaceOnDisk(staged, linked.config) == .verifiedPersisted(writeError: nil) && contents(realTarget.path) == staged)
        verdict.check("the symbolic link is kept", kind(link.path) == .symbolicLink)

        // Real OS: a config from outside the root is refused, a journal role is refused, and a directory prior is not started.
        let outsideInput = try StateRootLayout.resolveReadOnlyInput(
            RuntimeEnvironment(configDirectory: state, configFile: outside.appendingPathComponent("config.json")),
            fileSystem: fileSystem
        )
        let foreign = outsideInput.config
        let foreignAccess = FakeStateFileAccess(files: [:])
        verdict.check("a config outside the leased root is refused before any I/O",
                      VerifiedConfigurationFileReplacement.replace(staged, at: foreign, under: held, access: foreignAccess, expecting: fixedBaseline)
                          == .refused(.outsideLeasedRoot)
                          && foreignAccess.observations.isEmpty && !FileManager.default.fileExists(atPath: foreign.path))
        let journalAccess = FakeStateFileAccess(files: [:])
        verdict.check("a journal role is refused as the runtime configuration before any I/O",
                      VerifiedConfigurationFileReplacement.replace(staged, at: plan.journal, under: held, access: journalAccess, expecting: fixedBaseline)
                          == .refused(.wrongRole(.journal))
                          && journalAccess.observations.isEmpty)
        let directoryPlan = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("directory-config.json")),
            configAccess: .writerOwned,
            fileSystem: fileSystem
        )
        let directoryPrior = directoryPlan.config
        try FileManager.default.createDirectory(atPath: directoryPrior.path, withIntermediateDirectories: false)
        verdict.check("a directory prior is not started and is not written over",
                      replaceOnDisk(staged, directoryPrior) == .notStarted(.unreadable(.notRegularFile, closeErrno: nil))
                          && kind(directoryPrior.path) == .directory)

        // Fake file access: the read-back results that a real volume cannot produce on demand. Each one is classified from the
        // reads it observed, and its calls are checked for order and budget.
        let fakePath = fakeFile.path

        let landed = FakeStateFileAccess(files: [:])
        landed.scheduleReads([.actual, .actual])
        landed.scheduleWrites([.init(landing: .landsThenFails(errno: ENOSPC))])
        verdict.check("a write that threw after landing is verified persisted, and its error is kept",
                      classify(landed, expecting: ConfigurationFileBaseline(observing: .missing))
                          == .verifiedPersisted(writeError: .writeFailed(errno: ENOSPC)))
        verdict.check("the read-back is bounded by the staged length, the larger of the two counts",
                      landed.observations == [
                          .read(path: fakePath, limit: budget),
                          .write(path: fakePath, count: staged.count),
                          .read(path: fakePath, limit: staged.count),
                      ])

        let unchanged = FakeStateFileAccess(files: [fakePath: Data(repeating: 0x4C, count: 64)])
        unchanged.scheduleReads([.actual, .actual])
        unchanged.scheduleWrites([.init(landing: .failsBeforeLanding(errno: ENOSPC))])
        verdict.check("an unchanged larger prior after a failed write is verified not persisted",
                      classify(unchanged, expecting: ConfigurationFileBaseline(observing: .present(Data(repeating: 0x4C, count: 64))))
                          == .verifiedNotPersisted(writeError: .writeFailed(errno: ENOSPC)))
        verdict.check("the read-back covers the 64-byte prior in full",
                      unchanged.observations.last == .read(path: fakePath, limit: 64))

        let ambiguous = FakeStateFileAccess(files: [fakePath: Data("old".utf8)])
        ambiguous.scheduleReads([.actual, .actual])
        ambiguous.scheduleWrites([.init(landing: .lands, editAfterWrite: .replace(Data("other-writer".utf8)))])
        verdict.check("a successful write followed by other bytes is unknown, not persisted",
                      classify(ambiguous, expecting: ConfigurationFileBaseline(observing: .present(Data("old".utf8))))
                          == .unknown(.readbackDiffers, writeError: nil))

        let unreadable = FakeStateFileAccess(files: [fakePath: Data("old".utf8)])
        unreadable.scheduleReads([.failed(.unreadable(.readFailed(EIO), closeErrno: nil))])
        verdict.check("an unreadable prior is not started, and no write is made",
                      classify(unreadable, expecting: ConfigurationFileBaseline(observing: .present(Data("old".utf8))))
                          == .notStarted(.unreadable(.readFailed(EIO), closeErrno: nil))
                          && unreadable.observations == [.read(path: fakePath, limit: budget)])
    }

    /// Releases the lease first, then removes the scratch root only when the release was confirmed. An unconfirmed release keeps
    /// the root on disk, since its lock may still be held, and fails the verdict. An attempt that returned busy or failed also
    /// keeps the root, because no authority was confirmed. Only a run that never attempted the lease removes its root directly.
    /// A removal that fails also fails the verdict.
    private static func cleanUp(scratch: URL, leases: LeaseBox, verdict: Verdict) {
        if let lease = leases.lease {
            switch lease.release() {
            case .released, .alreadyReleased:
                verdict.check("the writer lease is released with a confirmed close", true)
            case .releaseUnknown(let errno):
                verdict.check("the writer lease is released with a confirmed close", false)
                verdict.note("the writer lease close was not confirmed (errno \(errno)); the scratch root was kept")
                return
            }
        } else if leases.attempted {
            verdict.note("the writer lease was not acquired, so the scratch root was kept")
            return
        }
        do {
            try FileManager.default.removeItem(at: scratch)
            verdict.check("the scratch directory is removed", true)
        } catch {
            verdict.check("the scratch directory is removed", false)
            verdict.note("scratch cleanup failed: \(error.localizedDescription)")
        }
    }
}

/// The assertions and notes of one run. A class, so the helpers that run the checks record into the same verdict. Both lists have
/// a fixed capacity: this scenario records 17 assertions, and a run past the capacity is a scenario bug, so recording traps.
private final class Verdict {
    static let assertionCapacity = 32
    static let noteCapacity = 8

    private(set) var assertions: [ScenarioAssertion] = []
    private(set) var notes: [String] = []

    func check(_ name: String, _ passed: Bool) {
        precondition(assertions.count < Self.assertionCapacity, "a scenario records a bounded number of assertions")
        assertions.append(.init(name, passed))
    }

    func note(_ text: String) {
        precondition(notes.count < Self.noteCapacity, "a scenario records a bounded number of notes")
        notes.append(text)
    }
}

/// The lease the run takes, kept where cleanup can reach it whichever step failed. `attempted` is set before the acquisition, so
/// a busy or failed attempt, which confirms no authority, keeps the root instead of deleting a directory that might be owned.
private final class LeaseBox {
    var attempted = false
    var lease: StateWriterLease?
}
