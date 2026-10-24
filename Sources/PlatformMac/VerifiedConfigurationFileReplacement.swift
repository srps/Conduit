// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import ProxyKernel

/// Why a replacement was refused before any I/O.
package enum ConfigurationFileReplacementRefusal: Error, Equatable, Sendable {
    /// Only the authoritative configuration files are replaced here: the runtime file and the two sidecars. The journal has its
    /// own role.
    case wrongRole(StateRootRole)
    /// The file does not resolve inside the root whose writer lease the caller holds.
    case outsideLeasedRoot
    /// The staged bytes exceed the file's role budget, so nothing is written.
    case stagedTooLarge(limit: Int)
}

/// Why a replacement cannot be classified as persisted or not persisted. None of these is a rollback claim.
package enum ConfigurationFileUnknownReason: Error, Equatable, Sendable {
    /// Read-back returned bytes that are not the staged bytes, and that do not classify as a failed replacement holding the
    /// observed prior. This covers bytes that are neither staged nor prior, and the observed prior after a replacement that
    /// reported success: the file does not show the staged bytes, so neither persisted nor not persisted is established.
    case readbackDiffers
    /// Read-back found no file where a prior was observed, or after a replacement that reported success with no prior.
    case readbackMissing
    /// Read-back failed, and the failure is not a missing file.
    case readbackFailed(ConfigurationFileError)
}

/// The physical outcome of one verified replacement (decision 0015). It carries no bytes and no path. `writeError` is what the
/// replacement reported. It stays beside the read-back result, because a replacement that reported an error may have landed.
package enum ConfigurationFileReplacementOutcome: Equatable, Sendable {
    /// Refused before any I/O.
    case refused(ConfigurationFileReplacementRefusal)
    /// The pre-read could not read the file, so nothing was written. A failed pre-read never authorizes a replacement (decision 0027).
    case notStarted(ConfigurationFileError)
    /// The pre-read observed bytes that differ from the expected baseline (decision 0027). Nothing was written, and the observed
    /// file is left as it is. Equal bytes under a different baseline are a conflict too, because the baseline changed.
    case conflict
    /// Read-back equals the staged bytes. This holds even when the replacement reported an error, because the staged bytes are
    /// what the file holds. It does not say that this call wrote them.
    case verifiedPersisted(writeError: ConfigurationFileWriteError?)
    /// The replacement reported an error, and read-back shows the prior that was observed, or no file when none was.
    case verifiedNotPersisted(writeError: ConfigurationFileWriteError)
    /// Read-back cannot establish which state the file is in.
    case unknown(ConfigurationFileUnknownReason, writeError: ConfigurationFileWriteError?)
}

/// The result of observing one configuration file through the bounded reader. Absence is an outcome, not a failure.
package enum ConfigurationFileObservationOutcome: Equatable, Sendable {
    case observed(ConfigurationFileInput)
    case refused(ConfigurationFileReplacementRefusal)
    case notObserved(ConfigurationFileError)
}

/// The result of checking one file against an expected baseline without writing it.
package enum ConfigurationFileVerification: Equatable, Sendable {
    case unchanged
    case changed
    case refused(ConfigurationFileReplacementRefusal)
    case notVerified(ConfigurationFileError)
}

/// The identity of one configuration file's bytes at the moment they were observed (decision 0027): its absence, or the length and
/// SHA-256 of its bytes. The bytes themselves are not kept, and the identity is private, redacted and not Codable. Equal identities
/// mean the observed bytes matched. They do not mean the file is the same object, and they are not a race exclusion.
package struct ConfigurationFileBaseline: Sendable, Equatable, CustomStringConvertible {
    private enum Identity: Sendable, Equatable {
        case absent
        case present(length: Int, digest: SHA256.Digest)
    }

    private let identity: Identity

    /// The baseline of bytes one read observed. The bytes are hashed here and nowhere else.
    package init(observing input: ConfigurationFileInput) {
        switch input {
        case .missing:
            identity = .absent
        case .present(let bytes):
            identity = .present(length: bytes.count, digest: SHA256.hash(data: bytes))
        }
    }

    /// The baseline of a read, or nil when the read failed. A failed read never establishes a baseline.
    package init?(observing read: Result<ConfigurationFileInput, ConfigurationFileError>) {
        guard case .success(let input) = read else { return nil }
        self.init(observing: input)
    }

    package var description: String {
        "ConfigurationFileBaseline(redacted)"
    }
}

/// The verified replacement of one authoritative configuration file (decisions 0015, 0017, 0020, 0021, 0026 and 0027).
///
/// `replace` is conditional: one bounded pre-read compares the file with the caller's baseline, and a changed file is refused
/// before any write. The write and read-back classification are the ones the runtime file always used, now shared by the runtime
/// file and both sidecars. This is a physical building block, not a store. It mints no receipt and takes no intent generation,
/// and the caller owns the baseline it supplies. The caller must hold the root's writer lease for the whole call and must prove that
/// no other writer of the root is running. Holding the lease reference is not that proof.
///
/// This is not a compare-and-swap. The pre-read cannot exclude a nonparticipating editor that changes the file after the check and
/// before the write: such an edit is overwritten, and read-back reports the staged bytes as persisted. Verification compares
/// identity. It is not power-loss durability and not a caller authority check.
package enum VerifiedConfigurationFileReplacement {
    package static func replace(
        _ staged: Data,
        at file: StateRootFile,
        under lease: StateWriterLease,
        access: any StateFileAccessing,
        expecting baseline: ConfigurationFileBaseline
    ) -> ConfigurationFileReplacementOutcome {
        // Every refusal comes before the first I/O, so a bad input leaves the root untouched.
        guard let budget = ConfigurationFileBudget.limit(for: file.role) else { return .refused(.wrongRole(file.role)) }
        guard file.path.hasPrefix(lease.root.path + "/") else { return .refused(.outsideLeasedRoot) }
        guard staged.count <= budget else { return .refused(.stagedTooLarge(limit: budget)) }

        // The one pre-read. Its bound is the approved budget, and it is the only read before the write.
        let prior: ObservedPrior
        switch access.readConfigurationFile(file, limit: budget) {
        case .success(let bytes): prior = .present(bytes)
        case .failure(.missing): prior = .absent
        case .failure(let error): return .notStarted(error)
        }
        guard ConfigurationFileBaseline(observing: prior.input) == baseline else { return .conflict }

        var writeError: ConfigurationFileWriteError?
        if case .failure(let error) = access.replaceConfigurationFile(file, bytes: staged) {
            writeError = error
        }

        // The reader adds its own single probe byte, so the bound is the larger of the two byte counts and no more.
        let readback = access.readConfigurationFile(file, limit: max(staged.count, prior.count))
        switch readback {
        case .success(let bytes) where bytes == staged:
            return .verifiedPersisted(writeError: writeError)
        case .success(let bytes):
            if let writeError, prior.holds(bytes) { return .verifiedNotPersisted(writeError: writeError) }
            return .unknown(.readbackDiffers, writeError: writeError)
        case .failure(.missing):
            if let writeError, prior.isAbsent { return .verifiedNotPersisted(writeError: writeError) }
            return .unknown(.readbackMissing, writeError: writeError)
        case .failure(let error):
            return .unknown(.readbackFailed(error), writeError: writeError)
        }
    }

    /// Observes one configuration file through the same bounded reader the replacement's pre-read uses. A missing file is
    /// `.observed(.missing)`. A foreign role is refused before any I/O.
    package static func observe(_ file: StateRootFile, access: any StateFileAccessing) -> ConfigurationFileObservationOutcome {
        guard let budget = ConfigurationFileBudget.limit(for: file.role) else { return .refused(.wrongRole(file.role)) }
        switch access.readConfigurationFile(file, limit: budget) {
        case .success(let bytes): return .observed(.present(bytes))
        case .failure(.missing): return .observed(.missing)
        case .failure(let error): return .notObserved(error)
        }
    }

    /// Checks one configuration file against an expected baseline without writing it. It reads through `observe`, so it is the
    /// same reader, and it reports `.changed` rather than adopting the observed bytes.
    package static func verifyUnchanged(
        _ file: StateRootFile,
        expecting baseline: ConfigurationFileBaseline,
        access: any StateFileAccessing
    ) -> ConfigurationFileVerification {
        switch observe(file, access: access) {
        case .observed(let input):
            return ConfigurationFileBaseline(observing: input) == baseline ? .unchanged : .changed
        case .refused(let refusal):
            return .refused(refusal)
        case .notObserved(let error):
            return .notVerified(error)
        }
    }
}

/// What the pre-read reported. Absence is an outcome, not a failure. The verdict uses this observation, not the stored file,
/// so a read that reports a missing file counts as absent even when the file exists.
private enum ObservedPrior {
    case absent
    case present(Data)

    var input: ConfigurationFileInput {
        switch self {
        case .absent: .missing
        case .present(let bytes): .present(bytes)
        }
    }

    var count: Int {
        switch self {
        case .absent: 0
        case .present(let bytes): bytes.count
        }
    }

    var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }

    func holds(_ bytes: Data) -> Bool {
        if case .present(let prior) = self { return prior == bytes }
        return false
    }
}
