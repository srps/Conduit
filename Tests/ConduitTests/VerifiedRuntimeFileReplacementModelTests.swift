// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The verified replacement driven through the low-level fake (decisions 0015 and 0021). The expected results come from a model
/// of what the observer knows, written from the decision rules. The model never calls the production classifier. It enumerates
/// every combination of the stored prior, the pre-read, the write, an external edit after the write and the read-back. The
/// witnesses are written by hand, so the cases the rules must not bend on are pinned independently of the model. Test-only
/// adapters break one rule each, so the oracle is shown to notice a broken adapter.
final class VerifiedRuntimeFileReplacementModelTests: XCTestCase {
    private static let root = "/fixture/state"
    private static let path = root + "/config.json"
    private static let staged = Data("staged-config".utf8)
    private static let other = Data("other-writer".utf8)
    private static let smallPrior = Data("old".utf8)
    private static let largerPrior = Data(repeating: 0x4C, count: 64)
    private static let longEdit = Data(repeating: 0x58, count: 128)
    private static let writeErrno: Int32 = ENOSPC
    private static let ioFailure = RuntimeConfigurationFileError.unreadable(.readFailed(EIO), closeErrno: nil)
    private static let budget = RuntimeConfigurationFileReader.maximumBytes

    private enum PriorKind: CaseIterable {
        case absent, same, small, larger

        /// The stored bytes before the call. `same` holds exactly the staged bytes.
        var stored: Data? {
            switch self {
            case .absent: nil
            case .same: VerifiedRuntimeFileReplacementModelTests.staged
            case .small: VerifiedRuntimeFileReplacementModelTests.smallPrior
            case .larger: VerifiedRuntimeFileReplacementModelTests.largerPrior
            }
        }
    }

    /// How a read reports: the stored file, a missing file, or a failure.
    private enum ReadMode: CaseIterable { case actual, missing, failed }

    private enum WriteMode: CaseIterable { case lands, failsBefore, landsThenFails }

    private enum AfterWriteEdit: CaseIterable { case none, other, remove, long }

    private struct Case: CustomStringConvertible {
        let prior: PriorKind
        let preRead: ReadMode
        let write: WriteMode
        let edit: AfterWriteEdit
        let readBack: ReadMode

        var description: String {
            "prior=\(prior) preRead=\(preRead) write=\(write) edit=\(edit) readBack=\(readBack)"
        }
    }

    /// Everything a case determines: the outcome, every call with its budget or byte count, and the stored bytes afterwards.
    private struct Expectation: Equatable {
        let outcome: RuntimeFileReplacementOutcome
        let observations: [FakeStateFileAccess.Observation]
        let stored: Data?
    }

    /// What the observer saw from one read. A missing file and an absent prior are the same observation.
    private enum Seen: Equatable {
        case bytes(Data)
        case missing
        case failed(RuntimeConfigurationFileError)
    }

    private struct LeaseUnavailable: Error {}

    // MARK: - The independent model

    /// The model. Two things are kept apart. The disk (`stored`) is what the file actually holds after the call, and the model
    /// uses it only to decide what the read-back returns. The verdict uses the observer's knowledge: `prePrior`, what the
    /// pre-read reported before the write, and `readSeen`, what the read-back reported after it. A pre-read that reports
    /// missing makes the prior absent even when a file is stored, and a read-back that reports missing is not checked against
    /// the disk. So the verdict can be right about the observer and wrong about the disk, which is the point of the model.
    private static func model(_ c: Case) -> Expectation {
        let storedBefore = c.prior.stored
        var observations: [FakeStateFileAccess.Observation] = [.read(path: path, limit: budget)]

        let prePrior: Seen
        switch c.preRead {
        case .actual: prePrior = storedBefore.map { Seen.bytes($0) } ?? .missing
        case .missing: prePrior = .missing
        case .failed: prePrior = .failed(ioFailure)
        }
        if case .failed(let error) = prePrior {
            return Expectation(outcome: .notStarted(error), observations: observations, stored: storedBefore)
        }

        let priorCount: Int
        if case .bytes(let bytes) = prePrior { priorCount = bytes.count } else { priorCount = 0 }
        observations.append(.write(path: path, count: staged.count))

        let writeError: RuntimeFileWriteError? = c.write == .lands ? nil : .writeFailed(errno: writeErrno)
        // A failed write leaves the stored file alone. A landed write puts the staged bytes there. The edit comes after.
        var stored: Data? = c.write == .failsBefore ? storedBefore : staged
        switch c.edit {
        case .none: break
        case .other: stored = other
        case .remove: stored = nil
        case .long: stored = longEdit
        }

        let limit = max(staged.count, priorCount)
        observations.append(.read(path: path, limit: limit))
        let readSeen: Seen
        switch c.readBack {
        case .missing:
            readSeen = .missing
        case .failed:
            readSeen = .failed(ioFailure)
        case .actual:
            if let bytes = stored {
                readSeen = bytes.count > limit ? .failed(.unreadable(.tooLarge(limit: limit), closeErrno: nil)) : .bytes(bytes)
            } else {
                readSeen = .missing
            }
        }

        let outcome: RuntimeFileReplacementOutcome
        switch readSeen {
        case .bytes(let bytes) where bytes == staged:
            outcome = .verifiedPersisted(writeError: writeError)
        case .bytes(let bytes):
            if let writeError, prePrior == .bytes(bytes) {
                outcome = .verifiedNotPersisted(writeError: writeError)
            } else {
                outcome = .unknown(.readbackDiffers, writeError: writeError)
            }
        case .missing:
            if let writeError, prePrior == .missing {
                outcome = .verifiedNotPersisted(writeError: writeError)
            } else {
                outcome = .unknown(.readbackMissing, writeError: writeError)
            }
        case .failed(let error):
            outcome = .unknown(.readbackFailed(error), writeError: writeError)
        }
        return Expectation(outcome: outcome, observations: observations, stored: stored)
    }

    // MARK: - Driving the production replacement

    private static func makeFake(for c: Case) -> FakeStateFileAccess {
        let initial: [String: Data] = c.prior.stored.map { [path: $0] } ?? [:]
        let fake = FakeStateFileAccess(files: initial)
        fake.scheduleReads([script(c.preRead), script(c.readBack)])
        let landing: FakeStateFileAccess.Landing
        switch c.write {
        case .lands: landing = .lands
        case .failsBefore: landing = .failsBeforeLanding(errno: writeErrno)
        case .landsThenFails: landing = .landsThenFails(errno: writeErrno)
        }
        let edit: FakeStateFileAccess.ExternalEdit?
        switch c.edit {
        case .none: edit = nil
        case .other: edit = .replace(other)
        case .remove: edit = .remove
        case .long: edit = .replace(longEdit)
        }
        fake.scheduleWrites([FakeStateFileAccess.WriteScript(landing: landing, editAfterWrite: edit)])
        return fake
    }

    private static func script(_ mode: ReadMode) -> FakeStateFileAccess.ReadScript {
        switch mode {
        case .actual: .actual
        case .missing: .missing
        case .failed: .failed(ioFailure)
        }
    }

    /// Runs the production replacement over the fake. `wrap` puts a test-only adapter in front of the same fake.
    private static func run(
        _ c: Case,
        lease: StateWriterLease,
        wrap: ((FakeStateFileAccess) -> any StateFileAccessing)? = nil
    ) -> Expectation {
        let fake = makeFake(for: c)
        let access: any StateFileAccessing
        if let wrap { access = wrap(fake) } else { access = fake }
        let outcome = VerifiedRuntimeFileReplacement.replace(
            staged, at: StateRootFile(role: .config, path: path), under: lease, access: access
        )
        return Expectation(outcome: outcome, observations: fake.observations, stored: fake.storedBytes(at: path))
    }

    /// Runs one replacement that a refusal must stop before any I/O.
    private static func refuse(role: StateRootRole, path: String, staged: Data, stored: Data?) -> Expectation {
        let fake = FakeStateFileAccess(files: stored.map { [path: $0] } ?? [:])
        let outcome = VerifiedRuntimeFileReplacement.replace(
            staged, at: StateRootFile(role: role, path: path), under: leaseForRefusals, access: fake
        )
        return Expectation(outcome: outcome, observations: fake.observations, stored: fake.storedBytes(at: path))
    }

    /// A lease for the refusal cases. It is only read for its root, so the path a refusal names is the one under test.
    private static var leaseForRefusals: StateWriterLease {
        guard case .acquired(let lease) = FakeStateWriterLeasing().acquire(
            root: CanonicalStateRoot(canonicalPath: root), onReleaseFailure: { _ in }
        ) else {
            preconditionFailure("the fake lease acquires a fresh root")
        }
        return lease
    }

    private func acquireLease() throws -> StateWriterLease {
        let outcome = FakeStateWriterLeasing().acquire(
            root: CanonicalStateRoot(canonicalPath: Self.root), onReleaseFailure: { _ in XCTFail("a close could not be confirmed") }
        )
        guard case .acquired(let lease) = outcome else {
            XCTFail("the fake lease did not acquire")
            throw LeaseUnavailable()
        }
        return lease
    }

    private static func allCases() -> [Case] {
        var cases: [Case] = []
        for prior in PriorKind.allCases {
            for preRead in ReadMode.allCases {
                for write in WriteMode.allCases {
                    for edit in AfterWriteEdit.allCases {
                        for readBack in ReadMode.allCases {
                            cases.append(Case(prior: prior, preRead: preRead, write: write, edit: edit, readBack: readBack))
                        }
                    }
                }
            }
        }
        return cases
    }

    private static func label(_ outcome: RuntimeFileReplacementOutcome) -> String {
        switch outcome {
        case .refused: "refused"
        case .notStarted: "notStarted"
        case .verifiedPersisted: "verifiedPersisted"
        case .verifiedNotPersisted: "verifiedNotPersisted"
        case .unknown: "unknown"
        }
    }

    // MARK: - Tests

    /// Every combination of stored prior (4), pre-read (3), write (3), external edit after the write (4) and read-back (3). The
    /// production outcome, its calls with budgets, and the stored bytes must equal the model's in every case.
    func testEveryCombinationMatchesTheIndependentModel() throws {
        let lease = try acquireLease()
        defer { XCTAssertEqual(lease.release(), .released) }

        var reachedWrite = 0
        var tally: [String: Int] = [:]
        var mismatches: [String] = []
        let cases = Self.allCases()
        for c in cases {
            let expected = Self.model(c)
            let actual = Self.run(c, lease: lease)
            if c.preRead != .failed { reachedWrite += 1 }
            tally[Self.label(actual.outcome), default: 0] += 1
            if actual != expected {
                mismatches.append("\(c)\n  model: \(expected)\n  production: \(actual)")
            }
        }
        print("runtime-file-replacement model: \(cases.count) cases, \(reachedWrite) reach the write, outcomes \(tally.sorted { $0.key < $1.key })")
        XCTAssertEqual(cases.count, 432)
        XCTAssertEqual(Set(tally.keys), ["notStarted", "verifiedPersisted", "verifiedNotPersisted", "unknown"])
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(2).joined(separator: "\n"))")
    }

    /// Hand-written expectations for the rules the model must not bend on. None of these is generated.
    func testHandWrittenWitnessesStayFixed() throws {
        let lease = try acquireLease()
        defer { XCTAssertEqual(lease.release(), .released) }
        let writeError = RuntimeFileWriteError.writeFailed(errno: Self.writeErrno)
        let budget = Self.budget
        let staged = Self.staged
        let path = Self.path
        let staged13 = FakeStateFileAccess.Observation.write(path: path, count: staged.count)
        let fullRead = FakeStateFileAccess.Observation.read(path: path, limit: budget)

        // A write that threw after the rename is still persisted, because the staged bytes are what the file holds.
        XCTAssertEqual(Self.run(Case(prior: .absent, preRead: .actual, write: .landsThenFails, edit: .none, readBack: .actual), lease: lease),
                       Expectation(outcome: .verifiedPersisted(writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: staged))

        // A larger prior left unchanged by a failed write is not persisted. The read-back is bounded by the prior's size.
        XCTAssertEqual(Self.run(Case(prior: .larger, preRead: .actual, write: .failsBefore, edit: .none, readBack: .actual), lease: lease),
                       Expectation(outcome: .verifiedNotPersisted(writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: Self.largerPrior.count)],
                                   stored: Self.largerPrior))

        // A successful write followed by other bytes is unknown, not persisted.
        XCTAssertEqual(Self.run(Case(prior: .small, preRead: .actual, write: .lands, edit: .other, readBack: .actual), lease: lease),
                       Expectation(outcome: .unknown(.readbackDiffers, writeError: nil),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: Self.other))

        // The observer saw no file, so the verdict is not taken from the stored staged bytes. The model follows the observation.
        XCTAssertEqual(Self.run(Case(prior: .absent, preRead: .actual, write: .landsThenFails, edit: .none, readBack: .missing), lease: lease),
                       Expectation(outcome: .verifiedNotPersisted(writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: staged))

        // A failed read-back after a landed write is unknown, and keeps the write's own error.
        XCTAssertEqual(Self.run(Case(prior: .small, preRead: .actual, write: .landsThenFails, edit: .none, readBack: .failed), lease: lease),
                       Expectation(outcome: .unknown(.readbackFailed(Self.ioFailure), writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: staged))

        // A failed pre-read refuses the write. Nothing is written, and the unreadable prior stays as it was.
        XCTAssertEqual(Self.run(Case(prior: .larger, preRead: .failed, write: .lands, edit: .none, readBack: .actual), lease: lease),
                       Expectation(outcome: .notStarted(Self.ioFailure),
                                   observations: [fullRead],
                                   stored: Self.largerPrior))

        // A pre-read that reports missing makes the prior absent, so the read-back is bounded by the staged bytes alone. The
        // stored 64-byte file is then past that bound and reads as too large.
        XCTAssertEqual(Self.run(Case(prior: .larger, preRead: .missing, write: .failsBefore, edit: .none, readBack: .actual), lease: lease),
                       Expectation(outcome: .unknown(.readbackFailed(.unreadable(.tooLarge(limit: staged.count), closeErrno: nil)),
                                                     writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: Self.largerPrior))

        // A successful write whose file then reads back missing is unknown.
        XCTAssertEqual(Self.run(Case(prior: .absent, preRead: .actual, write: .lands, edit: .remove, readBack: .actual), lease: lease),
                       Expectation(outcome: .unknown(.readbackMissing, writeError: nil),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: nil))

        // Another writer changes the prior after the pre-read and before a failed write. The read-back shows that other content,
        // which is neither the staged bytes nor the prior the observer saw, so the result is unknown. Expected freshness is not
        // checked by this operation, so nothing here decides which writer should win.
        let racing = FakeStateFileAccess(files: [path: Self.smallPrior])
        racing.scheduleReads([.actual, .actual])
        racing.scheduleWrites([.init(landing: .failsBeforeLanding(errno: Self.writeErrno), editBeforeWrite: .replace(Self.other))])
        XCTAssertEqual(
            VerifiedRuntimeFileReplacement.replace(staged, at: StateRootFile(role: .config, path: path), under: lease, access: racing),
            .unknown(.readbackDiffers, writeError: writeError)
        )
        XCTAssertEqual(racing.storedBytes(at: path), Self.other)

        // Identical bytes already on disk: the content is persisted even though the write failed without landing.
        XCTAssertEqual(Self.run(Case(prior: .same, preRead: .actual, write: .failsBefore, edit: .none, readBack: .actual), lease: lease),
                       Expectation(outcome: .verifiedPersisted(writeError: writeError),
                                   observations: [fullRead, staged13, .read(path: path, limit: staged.count)],
                                   stored: staged))
    }

    /// Refusals stop before any call. Each one names no file it did not resolve, and leaves the stored bytes alone.
    func testRefusalsPerformNoIO() {
        let staged = Self.staged
        let oldBytes = Self.smallPrior

        let wrongRole = Self.refuse(role: .journal, path: Self.path, staged: staged, stored: oldBytes)
        XCTAssertEqual(wrongRole, Expectation(outcome: .refused(.wrongRole(.journal)), observations: [], stored: oldBytes))

        // The foreign file is seeded with the old bytes, so the expected stored bytes are those bytes, unchanged.
        let foreign = Self.refuse(role: .config, path: "/elsewhere/config.json", staged: staged, stored: oldBytes)
        XCTAssertEqual(foreign, Expectation(outcome: .refused(.outsideLeasedRoot), observations: [], stored: oldBytes))

        let oversize = Data(count: Self.budget + 1)
        let tooLarge = Self.refuse(role: .config, path: Self.path, staged: oversize, stored: oldBytes)
        XCTAssertEqual(tooLarge, Expectation(outcome: .refused(.stagedTooLarge(limit: Self.budget)), observations: [], stored: oldBytes))
    }

    /// Test-only adapter that breaks one rule of the access contract over the fake. The production code is unchanged.
    private enum Mutant: CaseIterable {
        /// A thrown write is reported as a success.
        case hideWriteFailure
        /// A failed read is reported as a missing file.
        case readFailureAsMissing
        /// The read-back is bounded by the approved budget, not by the bytes it needs.
        case unboundedReadBack
        /// The second read returns the staged bytes without reading the file.
        case echoStagedOnReadBack
    }

    private final class MutantAccess: StateFileAccessing, @unchecked Sendable {
        private let mutant: Mutant
        private let fake: FakeStateFileAccess
        private let staged: Data
        private let lock = NSLock()
        private var reads = 0

        init(_ mutant: Mutant, over fake: FakeStateFileAccess, staged: Data) {
            self.mutant = mutant
            self.fake = fake
            self.staged = staged
        }

        func readRuntimeFile(_ file: StateRootFile, limit: Int) -> Result<Data, RuntimeConfigurationFileError> {
            let index = lock.withLock { () -> Int in
                reads += 1
                return reads
            }
            switch mutant {
            case .echoStagedOnReadBack where index == 2:
                return .success(staged)
            case .unboundedReadBack:
                return fake.readRuntimeFile(file, limit: RuntimeConfigurationFileReader.maximumBytes)
            case .readFailureAsMissing:
                let result = fake.readRuntimeFile(file, limit: limit)
                if case .failure = result { return .failure(.missing) }
                return result
            case .hideWriteFailure, .echoStagedOnReadBack:
                return fake.readRuntimeFile(file, limit: limit)
            }
        }

        func replaceRuntimeFile(_ file: StateRootFile, bytes: Data) -> Result<Void, RuntimeFileWriteError> {
            let result = fake.replaceRuntimeFile(file, bytes: bytes)
            if mutant == .hideWriteFailure { return .success(()) }
            return result
        }
    }

    /// The oracle must notice every injected adapter bug. Each mutant needs at least one mismatching case, and the first one is
    /// printed as its witness.
    func testInjectedAdapterBugsAreCaughtWithWitnesses() throws {
        let lease = try acquireLease()
        defer { XCTAssertEqual(lease.release(), .released) }
        let cases = Self.allCases()
        for mutant in Mutant.allCases {
            var witnesses: [String] = []
            for c in cases where Self.run(c, lease: lease, wrap: { fake in MutantAccess(mutant, over: fake, staged: Self.staged) }) != Self.model(c) {
                witnesses.append("\(c)")
            }
            print("runtime-file-replacement mutant \(mutant): \(witnesses.count) of \(cases.count) cases caught; first witness \(witnesses.first ?? "none")")
            XCTAssertFalse(witnesses.isEmpty, "the oracle missed \(mutant)")
        }
    }
}
