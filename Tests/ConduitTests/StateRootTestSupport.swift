// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
import ProxyKernel

/// A scratch state root's writer authority, taken through the production bootstrap over the real lease and
/// the real file system (decisions 0017 and 0028). A scratch test takes its session before it seeds anything
/// under the root, and releases it with `releaseScratchStateRoot` only after its owned work has quiesced.
/// Nothing here is a production route to a session: production takes one only in its entry point.
func acquireScratchStateRoot(_ environment: RuntimeEnvironment) throws -> StateRootSession {
    let outcome = StateRootBootstrap.acquire(
        environment,
        createRootIfMissing: true,
        fileSystem: OSStateRootFileSystem(),
        leasing: OSStateWriterLeasing(),
        onReleaseFailure: { failure in
            XCTFail("a scratch state-root lease could not be closed: errno \(failure.errno)")
        }
    )
    switch outcome {
    case .success(let session):
        return session
    case .failure(let failure):
        throw ScratchStateRootRefusal(failure: failure)
    }
}

/// A scratch root that the bootstrap refused, so the test can say which refusal it saw.
struct ScratchStateRootRefusal: Error, Equatable {
    let failure: StateRootAcquisitionFailure
}

/// Removes the scratch directories a test created. A directory that was never created is skipped. A removal that
/// fails is reported as a failed test, so leftover fixtures are never silent.
func removeScratch(_ urls: [URL], file: StaticString = #filePath, line: UInt = #line) {
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("owned scratch cleanup failed for \(url.lastPathComponent): \(error)", file: file, line: line)
        }
    }
}

/// Ends a scratch session's authority and checks that its close was confirmed.
func releaseScratchStateRoot(_ session: StateRootSession, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(session.releaseForTesting(), .released, "the scratch state-root lease closed", file: file, line: line)
}

/// An absolute path of exactly `byteCount` UTF-8 bytes, built from names under the 255-byte NAME_MAX limit.
func absolutePath(byteCount: Int) -> String {
    var path = ""
    while path.utf8.count < byteCount {
        let room = byteCount - path.utf8.count
        path += "/" + String(repeating: "x", count: min(200, room - 1))
    }
    return path
}

/// One effect a recording wrapper saw: its operation (`kind`, `identity`, `canonical`, `caseQuery`, `mkdir`
/// or `lease`) and the path it named.
struct StateRootEffect: Equatable, Sendable {
    let operation: String
    let path: String
}

/// The ordered effects of one test, shared by every recording wrapper in it, so a test can say what came first
/// across the file system and the lease. An effect is logged before it is forwarded, so an attempt that fails is
/// still in the log.
final class StateRootEffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StateRootEffect] = []

    func record(_ operation: String, _ path: String) {
        lock.withLock { recorded.append(StateRootEffect(operation: operation, path: path)) }
    }

    var effects: [StateRootEffect] { lock.withLock { recorded } }
}

/// Forwards every file-system effect to `inner` and records it in `log`. A refusal that must touch nothing is
/// shown by an empty log.
final class RecordingStateRootFileSystem: StateRootFileSystem, @unchecked Sendable {
    private let inner: any StateRootFileSystem
    private let log: StateRootEffectLog

    init(_ inner: any StateRootFileSystem, log: StateRootEffectLog) {
        self.inner = inner
        self.log = log
    }

    func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind {
        log.record("kind", path)
        return try inner.entryKind(at: path)
    }

    func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity? {
        log.record("identity", path)
        return try inner.identity(at: path)
    }

    func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String {
        log.record("canonical", path)
        return try inner.canonicalPath(of: path)
    }

    func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool? {
        log.record("caseQuery", directory)
        return try inner.volumeSupportsCaseSensitiveNames(at: directory)
    }

    func createDirectory(at path: String) throws(StateRootFileSystemError) {
        log.record("mkdir", path)
        try inner.createDirectory(at: path)
    }
}

/// Forwards the lease to `inner` and records each attempt in `log`.
final class RecordingStateWriterLeasing: StateWriterLeasing, @unchecked Sendable {
    private let inner: any StateWriterLeasing
    private let log: StateRootEffectLog

    init(_ inner: any StateWriterLeasing, log: StateRootEffectLog) {
        self.inner = inner
        self.log = log
    }

    func acquire(
        root: CanonicalStateRoot,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void
    ) -> StateWriterAcquisition {
        log.record("lease", root.path)
        return inner.acquire(root: root, onReleaseFailure: onReleaseFailure)
    }
}
