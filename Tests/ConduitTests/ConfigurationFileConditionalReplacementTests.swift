// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The conditional replacement, the observation and the verify-only check over the fake file access (decisions 0021, 0026 and 0027).
/// The fake stands in for the physical reads and writes, so these tests show what the classifier does with each reported result. They
/// do not show what a nonparticipating editor does in a race: the after-check case below documents that such an edit is overwritten.
final class ConfigurationFileConditionalReplacementTests: XCTestCase {
    private static let staged = Data("staged-config".utf8)
    private static let prior = Data("prior-config".utf8)
    private static let sidecarLimit = 128 * 1024

    /// A lease on a real, empty canonical root. The fake never touches the disk, but the lease is what the replacement checks.
    private func withLease(_ body: (StateWriterLease, CanonicalStateRoot) throws -> Void) throws {
        let directory = try StateRootScratch.make("conditional-replacement")
        let root = try StateRootScratch.canonicalRoot(directory)
        guard case .acquired(let lease) = OSStateWriterLeasing().acquire(root: root, onReleaseFailure: { failure in
            XCTFail("the destructor could not confirm a close: \(failure)")
        }) else {
            XCTFail("the scratch root was not acquired, so its directory is kept")
            return
        }
        defer {
            switch lease.release() {
            case .released, .alreadyReleased: StateRootScratch.remove(directory)
            case .releaseUnknown(let errno): XCTFail("the writer lease close was not confirmed (errno \(errno)); the directory was kept")
            }
        }
        try body(lease, root)
    }

    private func file(_ root: CanonicalStateRoot, _ name: String = "config.json", role: StateRootRole = .config) -> StateRootFile {
        StateRootFile(role: role, path: root.path + "/" + name)
    }

    private func replace(
        _ bytes: Data,
        _ target: StateRootFile,
        _ lease: StateWriterLease,
        _ fake: FakeStateFileAccess,
        expecting baseline: ConfigurationFileBaseline
    ) -> ConfigurationFileReplacementOutcome {
        VerifiedConfigurationFileReplacement.replace(bytes, at: target, under: lease, access: fake, expecting: baseline)
    }

    // MARK: - Conditional replacement

    func testAnUnchangedFileIsReplacedAndReadBack() throws {
        try withLease { lease, root in
            let target = file(root)
            let fake = FakeStateFileAccess(files: [target.path: Self.prior])
            let outcome = replace(Self.staged, target, lease, fake, expecting: ConfigurationFileBaseline(observing: .present(Self.prior)))
            XCTAssertEqual(outcome, .verifiedPersisted(writeError: nil))
            XCTAssertEqual(fake.storedBytes(at: target.path), Self.staged)
            XCTAssertEqual(fake.observations, [
                .read(path: target.path, limit: ConfigurationFileReader.maximumBytes),
                .write(path: target.path, count: Self.staged.count),
                .read(path: target.path, limit: max(Self.staged.count, Self.prior.count)),
            ])
        }
    }

    func testAMissingFileIsCreatedWhenTheBaselineIsAbsent() throws {
        try withLease { lease, root in
            let target = file(root)
            let fake = FakeStateFileAccess()
            XCTAssertEqual(replace(Self.staged, target, lease, fake, expecting: ConfigurationFileBaseline(observing: .missing)),
                           .verifiedPersisted(writeError: nil))
            XCTAssertEqual(fake.storedBytes(at: target.path), Self.staged)
        }
    }

    /// Every changed observation is a conflict before any write. The observed file is kept, and the fake records the one read only.
    func testEveryChangedObservationIsAConflictBeforeAnyWrite() throws {
        let changes: [(label: String, stored: Data?)] = [
            ("changed bytes", Data("other-writer".utf8)),
            ("formatting only", Self.prior + Data("\n".utf8)),
            ("same length, other bytes", Data("prior-conFig".utf8)),
            ("external bytes equal the proposed save", Self.staged),
            ("external deletion", nil),
            ("external creation", Self.staged),
        ]
        try withLease { lease, root in
            for change in changes {
                let target = file(root)
                let fake = FakeStateFileAccess(files: change.stored.map { [target.path: $0] } ?? [:])
                let baseline = change.label == "external creation"
                    ? ConfigurationFileBaseline(observing: .missing)
                    : ConfigurationFileBaseline(observing: .present(Self.prior))
                XCTAssertEqual(replace(Self.staged, target, lease, fake, expecting: baseline), .conflict, change.label)
                XCTAssertEqual(fake.observations, [.read(path: target.path, limit: ConfigurationFileReader.maximumBytes)], change.label)
                XCTAssertEqual(fake.storedBytes(at: target.path), change.stored, change.label)
            }
        }
    }

    /// A failed pre-read authorizes nothing: the replacement is not started and nothing is written.
    func testAFailedPreReadNeverAuthorizesAWrite() throws {
        try withLease { lease, root in
            let target = file(root)
            let fake = FakeStateFileAccess(files: [target.path: Self.prior])
            fake.scheduleReads([.failed(.unreadable(.readFailed(EIO), closeErrno: nil))])
            XCTAssertEqual(replace(Self.staged, target, lease, fake, expecting: ConfigurationFileBaseline(observing: .present(Self.prior))),
                           .notStarted(.unreadable(.readFailed(EIO), closeErrno: nil)))
            XCTAssertEqual(fake.storedBytes(at: target.path), Self.prior)
            XCTAssertEqual(fake.observations.count, 1)
        }
    }

    /// A pre-read that reports a missing file, while the baseline is a present file, is a conflict, not a creation.
    func testAMissingReportWhileThePriorWasPresentIsAConflict() throws {
        try withLease { lease, root in
            let target = file(root)
            let fake = FakeStateFileAccess(files: [target.path: Self.prior])
            fake.scheduleReads([.missing])
            XCTAssertEqual(replace(Self.staged, target, lease, fake, expecting: ConfigurationFileBaseline(observing: .present(Self.prior))), .conflict)
            XCTAssertEqual(fake.observations.count, 1)
        }
    }

    /// The check is not a race exclusion. An edit made after the check and before the write is overwritten, and the result says so.
    func testAnEditAfterTheCheckIsOverwrittenAndIsNotExcluded() throws {
        try withLease { lease, root in
            let target = file(root)
            let fake = FakeStateFileAccess(files: [target.path: Self.prior])
            fake.scheduleWrites([.init(landing: .lands, editBeforeWrite: .replace(Data("late-editor".utf8)))])
            let outcome = replace(Self.staged, target, lease, fake, expecting: ConfigurationFileBaseline(observing: .present(Self.prior)))
            XCTAssertEqual(outcome, .verifiedPersisted(writeError: nil))
            XCTAssertEqual(fake.storedBytes(at: target.path), Self.staged)
        }
    }

    // MARK: - Roles and budgets

    func testEachRoleTakesItsApprovedBudgetAndTheJournalTakesNone() {
        XCTAssertEqual(ConfigurationFileBudget.limit(for: .config), ConfigurationFileReader.maximumBytes)
        XCTAssertEqual(ConfigurationFileBudget.limit(for: .platformConfig), Self.sidecarLimit)
        XCTAssertEqual(ConfigurationFileBudget.limit(for: .preferences), Self.sidecarLimit)
        XCTAssertNil(ConfigurationFileBudget.limit(for: .journal))
    }

    /// The sidecar budget is written whole at 128 KiB, and one byte over it is refused before any I/O.
    func testASidecarAtItsBudgetIsWrittenAndOneOverItIsRefused() throws {
        try withLease { lease, root in
            for role in [StateRootRole.platformConfig, .preferences] {
                let target = file(root, "sidecar-\(role).json", role: role)
                let fake = FakeStateFileAccess()
                let baseline = ConfigurationFileBaseline(observing: .missing)
                XCTAssertEqual(replace(Data(count: Self.sidecarLimit + 1), target, lease, fake, expecting: baseline),
                               .refused(.stagedTooLarge(limit: Self.sidecarLimit)), "\(role)")
                XCTAssertTrue(fake.observations.isEmpty, "\(role)")
                XCTAssertEqual(replace(Data(count: Self.sidecarLimit), target, lease, fake, expecting: baseline), .verifiedPersisted(writeError: nil),
                               "\(role)")
            }
        }
    }

    func testTheJournalIsRefusedForEveryOperationBeforeAnyIO() throws {
        try withLease { lease, root in
            let journal = file(root, "platform-state.json", role: .journal)
            let fake = FakeStateFileAccess(files: [journal.path: Self.prior])
            XCTAssertEqual(replace(Self.staged, journal, lease, fake, expecting: ConfigurationFileBaseline(observing: .present(Self.prior))),
                           .refused(.wrongRole(.journal)))
            XCTAssertEqual(VerifiedConfigurationFileReplacement.observe(journal, access: fake), .refused(.wrongRole(.journal)))
            XCTAssertEqual(VerifiedConfigurationFileReplacement.verifyUnchanged(journal, expecting: ConfigurationFileBaseline(observing: .missing),
                                                                               access: fake),
                           .refused(.wrongRole(.journal)))
            XCTAssertTrue(fake.observations.isEmpty)
        }
    }

    // MARK: - Observation, verify-only and baselines

    func testVerifyOnlyReadsOnceAndReportsWithoutWriting() throws {
        try withLease { _, root in
            let target = file(root)
            let fake = FakeStateFileAccess(files: [target.path: Self.prior])
            let baseline = ConfigurationFileBaseline(observing: .present(Self.prior))
            XCTAssertEqual(VerifiedConfigurationFileReplacement.verifyUnchanged(target, expecting: baseline, access: fake), .unchanged)
            fake.externalEdit(.replace(Self.staged), at: target.path)
            XCTAssertEqual(VerifiedConfigurationFileReplacement.verifyUnchanged(target, expecting: baseline, access: fake), .changed)
            fake.scheduleReads([.failed(.unreadable(.readFailed(EIO), closeErrno: nil))])
            XCTAssertEqual(VerifiedConfigurationFileReplacement.verifyUnchanged(target, expecting: baseline, access: fake),
                           .notVerified(.unreadable(.readFailed(EIO), closeErrno: nil)))
            XCTAssertFalse(fake.observations.contains { if case .write = $0 { true } else { false } })
        }
    }

    func testABaselineMatchesByBytesAndIsRedacted() {
        let baseline = ConfigurationFileBaseline(observing: .present(Self.prior))
        XCTAssertEqual(baseline, ConfigurationFileBaseline(observing: .present(Self.prior)))
        XCTAssertNotEqual(baseline, ConfigurationFileBaseline(observing: .present(Self.staged)))
        XCTAssertNotEqual(baseline, ConfigurationFileBaseline(observing: .present(Self.prior + Data("x".utf8))))
        XCTAssertNotEqual(baseline, ConfigurationFileBaseline(observing: .missing))
        XCTAssertEqual(String(describing: baseline), "ConfigurationFileBaseline(redacted)")
    }

    func testAFailedReadEstablishesNoBaseline() {
        XCTAssertNil(ConfigurationFileBaseline(observing: .failure(.missing)))
        XCTAssertNil(ConfigurationFileBaseline(observing: .failure(.unreadable(.readFailed(EIO), closeErrno: nil))))
        XCTAssertNotNil(ConfigurationFileBaseline(observing: .success(.missing)))
    }
}
