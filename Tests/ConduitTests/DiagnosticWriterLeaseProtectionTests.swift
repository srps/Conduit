// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The writer lease's neutral URL, passed by an adopting composer to the diagnostic guard. An alias of the lock is
/// refused, and the lock keeps its bytes and the session keeps its authority. Only the URL is exposed; the lease
/// object stays private, so holding the URL grants no write authority.
///
/// The guard tests here take the URL directly. The composition witnesses in `AppStateHarnessTests` and
/// `DaemonRuntimeHostTests` use `writerLeaseFingerprint` and `assertSecondWriterIsBusy` to show that the composed
/// writers pass the URL, and that the lock keeps its bytes, its inode and its holder.
final class DiagnosticWriterLeaseProtectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-writer-lease-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        removeScratch([root])
    }

    func testAnAliasOfTheWriterLeaseIsRefusedByAnAdoptedGuardAndTheLeaseKeepsItsAuthority() throws {
        let environment = RuntimeEnvironment.isolated(stateDirectory: root)
        let session = try acquireScratchStateRoot(environment)
        let lease = session.writerLeaseFile
        XCTAssertEqual(lease.lastPathComponent, StateRootReservedName.writerLock.fileName)
        let before = try writerLeaseFingerprint(lease)

        let alias = root.appendingPathComponent("events.ndjson")
        XCTAssertEqual(link(lease.path, alias.path), 0)
        let adopted = diagnosticDestinationGuard(for: .runtimeEvents, in: session.environment, writerLeaseFile: lease)
        XCTAssertThrowsError(try adopted.admit(destination: alias)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .writerLease))
        }

        XCTAssertEqual(try writerLeaseFingerprint(lease), before, "the refused alias did not write the lock")
        releaseScratchStateRoot(session)
    }

    /// Every sink that adopts the lease refuses an alias of it, so the protection does not depend on which writer is wired.
    func testEveryAdoptingSinkRefusesAnAliasOfTheWriterLease() throws {
        let environment = RuntimeEnvironment.isolated(stateDirectory: root)
        let session = try acquireScratchStateRoot(environment)
        let lease = session.writerLeaseFile
        let before = try writerLeaseFingerprint(lease)
        let alias = root.appendingPathComponent("alias.ndjson")
        XCTAssertEqual(link(lease.path, alias.path), 0)

        for sink in [RecordFileDiagnosticSink.appLog, .connectionAudit, .runtimeEvents, .snapshot] {
            let adopted = diagnosticDestinationGuard(for: sink, in: session.environment, writerLeaseFile: lease)
            XCTAssertThrowsError(try adopted.admit(destination: alias), "\(sink)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .writerLease),
                               "\(sink)")
            }
        }

        XCTAssertEqual(try writerLeaseFingerprint(lease), before)
        releaseScratchStateRoot(session)
    }
}

/// The lock's bytes and inode. A refused write leaves both as they were, and a changed inode would mean the lock
/// was replaced rather than kept.
struct WriterLeaseFingerprint: Equatable {
    let bytes: Data
    let inode: UInt64
}

func writerLeaseFingerprint(_ url: URL) throws -> WriterLeaseFingerprint {
    var info = stat()
    guard stat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    return WriterLeaseFingerprint(bytes: try Data(contentsOf: url), inode: UInt64(info.st_ino))
}

/// A second writer over the same root must be refused as busy while the first holds the lease. A refusal that succeeds
/// is released at once, so the probe never keeps the lock it was checking.
func assertSecondWriterIsBusy(_ environment: RuntimeEnvironment, file: StaticString = #filePath, line: UInt = #line) {
    do {
        let second = try acquireScratchStateRoot(environment)
        releaseScratchStateRoot(second, file: file, line: line)
        XCTFail("a second writer took a root whose lease is held", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ScratchStateRootRefusal, ScratchStateRootRefusal(failure: .busy),
                       "the held lease makes a second writer busy", file: file, line: line)
    }
}
