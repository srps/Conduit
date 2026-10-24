// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// A replacement that threw. It keeps the POSIX code only: never the path, the bytes or the system's description. A failure
/// that reports no POSIX code is `EIO`.
package enum RuntimeFileWriteError: Error, Equatable, Sendable {
    case writeFailed(errno: Int32)
}

/// Byte-level access to one authoritative runtime file (decisions 0017, 0020 and 0021). Every operation names the resolved
/// `StateRootFile`, so a caller cannot reach a path the layout did not resolve. The protocol keeps the verified replacement
/// testable against `FakeStateFileAccess` without touching the disk.
package protocol StateFileAccessing: Sendable {
    /// Reads at most `limit` bytes of the resolved file. A missing file is `.missing`. Every other refusal keeps its step and
    /// errno, as `RuntimeConfigurationFileReader` reports it.
    func readRuntimeFile(_ file: StateRootFile, limit: Int) -> Result<Data, RuntimeConfigurationFileError>

    /// Replaces the resolved file with `bytes` through the shared atomic write. The caller has staged and checked the bytes.
    /// A failure does not say whether the file was replaced, so the caller must read back.
    func replaceRuntimeFile(_ file: StateRootFile, bytes: Data) -> Result<Void, RuntimeFileWriteError>
}

/// The package entry point. It returns the protocol, so the OS adapter is never named outside this file.
package enum StateFileAccess {
    package static func operatingSystem() -> any StateFileAccessing {
        OSStateFileAccess()
    }
}

/// The OS adapter. It reads through the bounded runtime reader and writes through the one shared atomic write.
struct OSStateFileAccess: StateFileAccessing {
    func readRuntimeFile(_ file: StateRootFile, limit: Int) -> Result<Data, RuntimeConfigurationFileError> {
        do throws(RuntimeConfigurationFileError) {
            return .success(try RuntimeConfigurationFileReader.read(at: URL(fileURLWithPath: file.path), limit: limit))
        } catch {
            return .failure(error)
        }
    }

    func replaceRuntimeFile(_ file: StateRootFile, bytes: Data) -> Result<Void, RuntimeFileWriteError> {
        do {
            try ProxyConfigPersistence.writeStagedRuntimeFile(bytes, to: URL(fileURLWithPath: file.path))
            return .success(())
        } catch {
            return .failure(.writeFailed(errno: posixCode(of: error)))
        }
    }

    /// Foundation wraps a failed atomic write in a Cocoa error whose underlying error holds the POSIX code. The chain is
    /// followed for a bounded depth. A failure with no POSIX code, or a code that does not fit `Int32`, is reported as `EIO`
    /// rather than converted with a trap.
    private func posixCode(of error: any Error) -> Int32 {
        var current = error as NSError
        var depth = 0
        while current.domain != NSPOSIXErrorDomain, depth < 4, let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            current = underlying
            depth += 1
        }
        guard current.domain == NSPOSIXErrorDomain else { return EIO }
        return Int32(exactly: current.code) ?? EIO
    }
}
