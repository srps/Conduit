// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation
import ProxyKernel

/// A replacement that threw. It keeps a closed code only: never the path, the bytes, the error's domain or the system's
/// description. `writeFailed` is a POSIX code that fits `Int32`. `cocoaFailed` is the Cocoa code of a Cocoa error with no usable
/// POSIX cause. `unclassified` is every other failure, including an unusable POSIX code under a non-Cocoa error.
package enum ConfigurationFileWriteError: Error, Equatable, Sendable {
    case writeFailed(errno: Int32)
    case cocoaFailed(code: Int)
    case unclassified
}

/// The approved physical budget of each authoritative configuration file, derived from the resolved role (decisions 0021 and
/// 0026). A caller never chooses it. The runtime file takes the runtime budget; the platform and preferences sidecars take the
/// sidecar budget. The journal has no configuration budget, so every operation refuses it before any I/O.
package enum ConfigurationFileBudget {
    package static func limit(for role: StateRootRole) -> Int? {
        switch role {
        case .config: ConfigurationFileReader.maximumBytes
        case .platformConfig, .preferences: DomainResourceLimits.sidecarFileBytes
        case .journal: nil
        }
    }
}

/// Why an entry's presence could not be checked. The payload is the `stat` errno, and no path is kept. An unknown presence is never
/// reported as absent.
package enum ConfigurationPresenceError: Error, Equatable, Sendable {
    case statusFailed(errno: Int32)
}

/// Byte-level access to one authoritative configuration file (decisions 0017, 0020 and 0021). Every operation names the resolved
/// `StateRootFile`, so a caller cannot reach a path the layout did not resolve. The protocol keeps the verified replacement
/// testable against `FakeStateFileAccess` without touching the disk.
package protocol StateFileAccessing: Sendable {
    /// Reads at most `limit` bytes of the resolved file. `limit` must not exceed the file's role budget (`ConfigurationFileBudget`).
    /// A missing file is `.missing`. Every other refusal keeps its step and errno, as `ConfigurationFileReader` reports it.
    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError>

    /// Replaces the resolved file with `bytes` through the shared atomic write. The caller has staged and checked the bytes.
    /// A failure does not say whether the file was replaced, so the caller must read back.
    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError>

    /// Whether the resolved entry exists, from its metadata alone: it reads no content and applies no budget. `ENOENT` is absent, and
    /// every other `stat` failure is kept as its errno, so an unknown presence is never reported as absent. The store uses it only for
    /// the journal, whose presence decides whether a missing runtime file may be defaults (as the loader).
    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError>
}

/// The package entry point. It returns the protocol, so the OS adapter is never named outside this file.
package enum StateFileAccess {
    package static func operatingSystem() -> any StateFileAccessing {
        OSStateFileAccess()
    }
}

/// The OS adapter. It reads through the bounded configuration reader and writes through the one shared atomic write. The
/// verified replacement refuses a foreign role before it calls either operation, so a role without a budget is a caller bug.
struct OSStateFileAccess: StateFileAccessing {
    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        guard let budget = ConfigurationFileBudget.limit(for: file.role), limit <= budget else {
            preconditionFailure("a configuration read names a configuration role and no more than its budget")
        }
        do throws(ConfigurationFileError) {
            return .success(try ConfigurationFileReader.read(at: URL(fileURLWithPath: file.path), limit: limit))
        } catch {
            return .failure(error)
        }
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        guard ConfigurationFileBudget.limit(for: file.role) != nil else {
            preconditionFailure("a configuration write names a configuration role")
        }
        do {
            try ProxyConfigPersistence.writeStagedConfigurationFile(bytes, to: URL(fileURLWithPath: file.path))
            return .success(())
        } catch {
            return .failure(Self.writeError(for: error))
        }
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        var status = stat()
        if stat(file.path, &status) == 0 { return .success(true) }
        let code = errno
        return code == ENOENT ? .success(false) : .failure(.statusFailed(errno: code))
    }

    /// The number of underlying links the classifier follows. A cyclic chain stops here too, so no chain can loop.
    static let maximumUnderlyingDepth = 4

    /// Classifies a failed atomic write without retaining its description. Foundation wraps the POSIX code of a failed write in
    /// a Cocoa error, so the underlying chain is followed for at most `maximumUnderlyingDepth` links. A POSIX code is kept when it
    /// is positive and fits `Int32`. Otherwise an outer Cocoa error keeps its own code, which is not an errno. Any other failure is
    /// `unclassified`. An unusable POSIX code is never converted and is never reported as `EIO`.
    static func writeError(for error: any Error) -> ConfigurationFileWriteError {
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
