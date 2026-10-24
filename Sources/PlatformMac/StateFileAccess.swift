// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// A replacement that threw. It keeps a closed code only: never the path, the bytes, the error's domain or the system's
/// description. `writeFailed` is a POSIX code that fits `Int32`. `cocoaFailed` is the Cocoa code of a Cocoa error with no usable
/// POSIX cause. `unclassified` is every other failure, including an unusable POSIX code under a non-Cocoa error.
package enum RuntimeFileWriteError: Error, Equatable, Sendable {
    case writeFailed(errno: Int32)
    case cocoaFailed(code: Int)
    case unclassified
}

/// Byte-level access to one authoritative runtime file (decisions 0017, 0020 and 0021). Every operation names the resolved
/// `StateRootFile`, so a caller cannot reach a path the layout did not resolve. The protocol keeps the verified replacement
/// testable against `FakeStateFileAccess` without touching the disk.
package protocol StateFileAccessing: Sendable {
    /// Reads at most `limit` bytes of the resolved file. A missing file is `.missing`. Every other refusal keeps its step and
    /// errno, as `ConfigurationFileReader` reports it.
    func readRuntimeFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError>

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
    func readRuntimeFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        do throws(ConfigurationFileError) {
            return .success(try ConfigurationFileReader.read(at: URL(fileURLWithPath: file.path), limit: limit))
        } catch {
            return .failure(error)
        }
    }

    func replaceRuntimeFile(_ file: StateRootFile, bytes: Data) -> Result<Void, RuntimeFileWriteError> {
        do {
            try ProxyConfigPersistence.writeStagedRuntimeFile(bytes, to: URL(fileURLWithPath: file.path))
            return .success(())
        } catch {
            return .failure(Self.writeError(for: error))
        }
    }

    /// The number of underlying links the classifier follows. A cyclic chain stops here too, so no chain can loop.
    static let maximumUnderlyingDepth = 4

    /// Classifies a failed atomic write without retaining its description. Foundation wraps the POSIX code of a failed write in
    /// a Cocoa error, so the underlying chain is followed for at most `maximumUnderlyingDepth` links. A POSIX code is kept when it
    /// is positive and fits `Int32`. Otherwise an outer Cocoa error keeps its own code, which is not an errno. Any other failure is
    /// `unclassified`. An unusable POSIX code is never converted and is never reported as `EIO`.
    static func writeError(for error: any Error) -> RuntimeFileWriteError {
        let outer = error as NSError
        var current = outer
        var depth = 0
        while current.domain != NSPOSIXErrorDomain, depth < maximumUnderlyingDepth,
              let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            current = underlying
            depth += 1
        }
        if current.domain == NSPOSIXErrorDomain, let code = Int32(exactly: current.code), code > 0 {
            return .writeFailed(errno: code)
        }
        if outer.domain == NSCocoaErrorDomain { return .cocoaFailed(code: outer.code) }
        return .unclassified
    }
}
