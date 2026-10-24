// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

/// `config-file-conditional-replacement` (decisions 0021, 0026 and 0027): the conditional replacement of a configuration file through
/// the real OS adapter in a scratch root, and through the fake for the reads and writes a volume cannot produce on demand. Each external
/// change observed after the baseline is a conflict before any write, and the observed file stays as it was. A failed pre-read authorizes
/// nothing, and the sidecar budget is exact. The last case documents that an edit made after the check is overwritten: the check is not a
/// race exclusion. Nothing outside the scratch root is touched, and no socket is opened. This runs through PlatformMac only.
enum ConfigFileConditionalReplacementScenario {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-config-conditional-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let verdict = ConditionalVerdict()
        let leases = ConditionalLeaseBox()
        do {
            try exercise(scratch: scratch, leases: leases, verdict: verdict)
        } catch {
            verdict.check("the scenario ran to completion", false)
            verdict.note("the scenario stopped: \(error.localizedDescription)")
        }
        cleanUp(scratch: scratch, leases: leases, verdict: verdict)
        return ScenarioResult(
            name: "config-file-conditional-replacement", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: verdict.assertions.isEmpty ? [.init("scenario produced assertions", false)] : verdict.assertions,
            notes: verdict.notes
        )
    }

    private static func exercise(scratch: URL, leases: ConditionalLeaseBox, verdict: ConditionalVerdict) throws {
        let state = scratch.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let plan = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("config.json")),
            configAccess: .writerOwned,
            fileSystem: OSStateRootFileSystem()
        )

        leases.attempted = true
        let outcome = OSStateWriterLeasing().acquire(root: plan.root, onReleaseFailure: { failure in
            fputs("config-file-conditional-replacement close unconfirmed: errno \(failure.errno)\n", stderr)
        })
        guard case .acquired(let held) = outcome else {
            verdict.check("the scratch root is acquired for the conditional replacement", false)
            return
        }
        // Recorded before any check, so cleanup releases it whatever step below fails.
        leases.lease = held

        let os = StateFileAccess.operatingSystem()
        let config = plan.config
        let prior = Data("prior-config".utf8)
        let staged = Data("staged-config".utf8)

        func baseline(_ bytes: Data?) -> ConfigurationFileBaseline {
            ConfigurationFileBaseline(observing: bytes.map { ConfigurationFileInput.present($0) } ?? .missing)
        }
        func replaceOnDisk(_ bytes: Data, _ file: StateRootFile, expecting expected: ConfigurationFileBaseline) -> ConfigurationFileReplacementOutcome {
            VerifiedConfigurationFileReplacement.replace(bytes, at: file, under: held, access: os, expecting: expected)
        }
        func setOnDisk(_ bytes: Data?) throws {
            if let bytes {
                try bytes.write(to: URL(fileURLWithPath: config.path))
            } else if FileManager.default.fileExists(atPath: config.path) {
                try FileManager.default.removeItem(atPath: config.path)
            }
        }
        func onDisk() throws -> Data? {
            guard FileManager.default.fileExists(atPath: config.path) else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: config.path))
        }

        let created = replaceOnDisk(staged, config, expecting: baseline(nil))
        let createdBytes = try onDisk()
        verdict.check("an absent file with an absent baseline is created", created == .verifiedPersisted(writeError: nil) && createdBytes == staged)

        // Each external change after the baseline is observed is a conflict. The change stays on disk, and nothing is written over it.
        let changes: [(name: String, prior: Data, external: Data?)] = [
            ("changed bytes", prior, Data("other-writer".utf8)),
            ("a formatting-only edit", prior, prior + Data("\n".utf8)),
            ("an unknown-field edit", Data("{\"known\":1}".utf8), Data("{\"known\":1,\"unknown\":2}".utf8)),
            ("a same-length edit", prior, Data("prior-conFig".utf8)),
            ("external bytes equal to the proposed save", prior, staged),
            ("an external deletion", prior, nil),
        ]
        for change in changes {
            try setOnDisk(change.prior)
            let expected = baseline(change.prior)
            try setOnDisk(change.external)
            let result = replaceOnDisk(staged, config, expecting: expected)
            let kept = try onDisk()
            verdict.check("\(change.name) is a conflict and the observed file is kept", result == .conflict && kept == change.external)
        }

        // A pre-read that cannot read authorizes nothing: the fake records the read and no write.
        let failing = FakeStateFileAccess(files: [config.path: prior])
        failing.scheduleReads([.failed(.unreadable(.readFailed(EIO), closeErrno: nil))])
        let notStarted = VerifiedConfigurationFileReplacement.replace(
            staged, at: config, under: held, access: failing, expecting: baseline(prior)
        )
        verdict.check("a failed pre-read authorizes no write",
                      notStarted == .notStarted(.unreadable(.readFailed(EIO), closeErrno: nil))
                          && failing.observations.count == 1)

        // The platform sidecar's budget is exact: 128 KiB is written, and one byte over is refused before I/O.
        let sidecarLimit = 128 * 1024
        verdict.check("a platform sidecar at exactly its 128 KiB budget is written",
                      replaceOnDisk(Data(count: sidecarLimit), plan.platformConfig, expecting: baseline(nil)) == .verifiedPersisted(writeError: nil))
        verdict.check("a platform sidecar one byte over its budget is refused before any I/O",
                      replaceOnDisk(Data(count: sidecarLimit + 1), plan.preferences, expecting: baseline(nil))
                          == .refused(.stagedTooLarge(limit: sidecarLimit)))

        // The journal is not a configuration file, so it is refused before any read or write.
        verdict.check("the journal is refused as a configuration file and not created",
                      replaceOnDisk(staged, plan.journal, expecting: baseline(nil)) == .refused(.wrongRole(.journal))
                          && !FileManager.default.fileExists(atPath: plan.journal.path))

        // Verify-only uses the same reader: it reports unchanged, then changed, and it writes nothing.
        try setOnDisk(prior)
        let unchangedCheck = VerifiedConfigurationFileReplacement.verifyUnchanged(config, expecting: baseline(prior), access: os)
        verdict.check("verify-only reports an unchanged file as unchanged", unchangedCheck == .unchanged)
        try setOnDisk(Data("other-writer".utf8))
        let editedCheck = VerifiedConfigurationFileReplacement.verifyUnchanged(config, expecting: baseline(prior), access: os)
        let edited = try onDisk()
        verdict.check("verify-only reports an edited file as changed and keeps it", editedCheck == .changed && edited == Data("other-writer".utf8))

        // An edit after the check and before the write is overwritten. The check does not exclude it, and the result says so.
        let racing = FakeStateFileAccess(files: [config.path: prior])
        racing.scheduleWrites([.init(landing: .lands, editBeforeWrite: .replace(Data("late-editor".utf8)))])
        let raced = VerifiedConfigurationFileReplacement.replace(staged, at: config, under: held, access: racing, expecting: baseline(prior))
        verdict.check("an edit after the check is overwritten: the check does not exclude it",
                      raced == .verifiedPersisted(writeError: nil) && racing.storedBytes(at: config.path) == staged)
    }

    /// Releases the lease first, then removes the scratch root only when the release was confirmed. An unconfirmed release keeps the root
    /// on disk, since its lock may still be held, and fails the verdict. A busy or failed attempt also keeps the root, because no
    /// authority was confirmed. A removal that fails also fails the verdict.
    private static func cleanUp(scratch: URL, leases: ConditionalLeaseBox, verdict: ConditionalVerdict) {
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

/// The assertions and notes of one run. Both lists have a fixed capacity: a run past it is a scenario bug, so recording traps.
private final class ConditionalVerdict {
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

/// The lease the run takes, kept where cleanup can reach it whichever step failed.
private final class ConditionalLeaseBox {
    var attempted = false
    var lease: StateWriterLease?
}
