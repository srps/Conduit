// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Why a replacement was refused before any I/O.
package enum RuntimeFileReplacementRefusal: Error, Equatable, Sendable {
    /// Only the authoritative runtime configuration file is replaced here. Sidecars and the journal have their own roles.
    case wrongRole(StateRootRole)
    /// The file does not resolve inside the root whose writer lease the caller holds.
    case outsideLeasedRoot
    /// The staged bytes exceed the runtime file budget, so nothing is written.
    case stagedTooLarge(limit: Int)
}

/// Why a replacement cannot be classified as persisted or not persisted. None of these is a rollback claim.
package enum RuntimeFileUnknownReason: Error, Equatable, Sendable {
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
package enum RuntimeFileReplacementOutcome: Equatable, Sendable {
    /// Refused before any I/O.
    case refused(RuntimeFileReplacementRefusal)
    /// The prior could not be read, so nothing was written.
    case notStarted(ConfigurationFileError)
    /// Read-back equals the staged bytes. This holds even when the replacement reported an error, because the staged bytes are
    /// what the file holds. It does not say that this call wrote them.
    case verifiedPersisted(writeError: RuntimeFileWriteError?)
    /// The replacement reported an error, and read-back shows the prior that was observed, or no file when none was.
    case verifiedNotPersisted(writeError: RuntimeFileWriteError)
    /// Read-back cannot establish which state the file is in.
    case unknown(RuntimeFileUnknownReason, writeError: RuntimeFileWriteError?)
}

/// The verified replacement of the authoritative runtime configuration file (decisions 0015, 0017, 0020 and 0021).
///
/// This is a physical building block, not a store. It takes no intent generation, mints no receipt and does not check that the
/// prior is still the one the caller expected: expected-prior freshness belongs to the future store. The caller must hold the
/// root's writer lease for the whole call and must prove that no other writer of the root is running. Holding the lease reference
/// is not that proof, and nothing here excludes a nonparticipating external editor. Verification compares identity; it is not
/// power-loss durability and not a caller authority check.
package enum VerifiedRuntimeFileReplacement {
    package static func replace(
        _ staged: Data,
        at file: StateRootFile,
        under lease: StateWriterLease,
        access: any StateFileAccessing
    ) -> RuntimeFileReplacementOutcome {
        // Every refusal comes before the first I/O, so a bad input leaves the root untouched.
        guard file.role == .config else { return .refused(.wrongRole(file.role)) }
        guard file.path.hasPrefix(lease.root.path + "/") else { return .refused(.outsideLeasedRoot) }
        let budget = ConfigurationFileReader.maximumBytes
        guard staged.count <= budget else { return .refused(.stagedTooLarge(limit: budget)) }

        let prior: ObservedPrior
        switch access.readRuntimeFile(file, limit: budget) {
        case .success(let bytes): prior = .present(bytes)
        case .failure(.missing): prior = .absent
        case .failure(let error): return .notStarted(error)
        }

        var writeError: RuntimeFileWriteError?
        if case .failure(let error) = access.replaceRuntimeFile(file, bytes: staged) {
            writeError = error
        }

        // The reader adds its own single probe byte, so the bound is the larger of the two byte counts and no more.
        let readback = access.readRuntimeFile(file, limit: max(staged.count, prior.count))
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
}

/// What the pre-read reported. Absence is an outcome, not a failure. The verdict uses this observation, not the stored file,
/// so a read that reports a missing file counts as absent even when the file exists.
private enum ObservedPrior {
    case absent
    case present(Data)

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
