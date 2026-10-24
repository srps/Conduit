// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation

// Reads one configuration file under its approved physical budget: the runtime file (decision 0021) or a platform or
// preferences sidecar (decision 0026). The budget bounds the bytes the reader actually takes, not the size the file reports.
// A file that grows during the read is refused at the byte that crosses the limit, and the reader never asks for more than
// the bytes still allowed plus one probe byte. The probe byte is read into scratch and refused, so it never reaches the
// returned data. The descriptor is opened nonblocking, and only a regular file is read, so a named pipe or a device cannot
// stall the read. Symbolic links are followed, as they always were. Errors name the failing step and its errno, never the
// path or a byte of the file.

/// One step of a read that refused or failed. Each case is a flat value, so an error never nests another error.
package enum ConfigurationFileReadStep: Error, Sendable, Equatable {
    /// `fstat` failed on the open descriptor. The payload is the errno.
    case statusFailed(Int32)
    /// The descriptor is a directory, a named pipe, a device or a socket. None of these is read.
    case notRegularFile
    /// `read` failed. The payload is the errno.
    case readFailed(Int32)
    /// The file holds more than `limit` bytes. The reader refused it without keeping the probe byte.
    case tooLarge(limit: Int)
}

/// Why a configuration file could not be read. Both a refused read and a failed close are kept, so neither is lost.
package enum ConfigurationFileError: Error, Sendable, Equatable {
    /// The path names nothing, so a caller may treat the file as absent.
    case missing
    /// `open` failed. The payload is the errno.
    case openFailed(Int32)
    /// The read stopped at `step`. `closeErrno` is set when the descriptor's close also failed after it.
    case unreadable(ConfigurationFileReadStep, closeErrno: Int32?)
    /// The read succeeded and `close` failed. The payload is the errno.
    case closeFailed(Int32)
}

/// A fixed errno description: the code and the system's text for it. It never carries a path, a byte or a value.
private func errnoSummary(_ code: Int32) -> String {
    "errno \(code) (\(String(cString: strerror(code))))"
}

extension ConfigurationFileReadStep {
    /// The step that refused or failed the read, in fixed words and the errno. Both failures of one read are reported by
    /// `ConfigurationFileError.summary`, so neither is dropped.
    package var summary: String {
        switch self {
        case .statusFailed(let code):
            "status check failed, \(errnoSummary(code))"
        case .notRegularFile:
            "not a regular file"
        case .readFailed(let code):
            "read failed, \(errnoSummary(code))"
        case .tooLarge(let limit):
            "exceeds the size limit of \(limit) bytes"
        }
    }
}

extension ConfigurationFileError {
    /// The read's failures in fixed words: the refused or failed step, then a close that failed after it, when one did. A
    /// close failure after a good read is reported alone. The text names no path, input byte or value.
    package var summary: String {
        switch self {
        case .missing:
            "the file does not exist"
        case .openFailed(let code):
            "open failed, \(errnoSummary(code))"
        case .closeFailed(let code):
            "close failed, \(errnoSummary(code))"
        case .unreadable(let step, let closeErrno):
            if let closeErrno {
                "\(step.summary), and close also failed, \(errnoSummary(closeErrno))"
            } else {
                step.summary
            }
        }
    }
}

/// The read loop, separated from the descriptor so a test can drive it with fixed chunks and with growth. The scratch
/// buffer is one fixed chunk for every read. Only the allowed bytes are appended, so a refused file never grows the
/// returned data.
package enum ConfigurationFileCollector {
    package static let chunkBytes = 64 * 1024

    /// Collects the bytes `read` delivers, up to `limit`. `read` fills the buffer it is given and returns how many bytes
    /// it wrote, where 0 means the end. It is never asked for more than the bytes still allowed plus one probe byte. A
    /// probe byte that arrives is refused before it is appended.
    package static func collect(
        limit: Int,
        read: (UnsafeMutableRawBufferPointer) throws(ConfigurationFileReadStep) -> Int
    ) throws(ConfigurationFileReadStep) -> Data {
        precondition(limit >= 0 && limit < Int.max, "a collector limit is a byte count that leaves room for the probe byte")
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 1)
        defer { scratch.deallocate() }
        var data = Data()
        while true {
            let want = min(chunkBytes, limit + 1 - data.count)
            let count = try read(UnsafeMutableRawBufferPointer(rebasing: scratch.prefix(want)))
            if count == 0 {
                return data
            }
            guard count > 0, count <= want else {
                throw .readFailed(EIO)
            }
            // `data.count` never exceeds `limit`, so the remaining allowance is never negative.
            guard count <= limit - data.count else {
                throw .tooLarge(limit: limit)
            }
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: scratch.prefix(count)))
        }
    }
}

/// Reads one configuration file. The file is the only input: no state directory, no journal and no other sidecar is read or
/// capped here. The caller passes the budget of its file kind (`ConfigurationFileRoot.maximumBytes`).
package enum ConfigurationFileReader {
    /// The approved physical budget for one runtime configuration file. The ordinary runtime entry point always uses it.
    package static let maximumBytes = DomainResourceLimits.runtimeConfigurationFileBytes

    /// Reads the file at `url` under the approved runtime budget.
    package static func read(at url: URL) throws(ConfigurationFileError) -> Data {
        try read(at: url, limit: maximumBytes, closeDescriptor: { Darwin.close($0) })
    }

    /// Reads the file at `url` under `limit`, which may only lower the approved runtime budget. A caller that has already
    /// bounded its own read (the verified replacement's read-back) uses this instead of a second read loop, and a sidecar
    /// uses it with its own smaller budget.
    package static func read(at url: URL, limit: Int) throws(ConfigurationFileError) -> Data {
        try read(at: url, limit: limit, closeDescriptor: { Darwin.close($0) })
    }

    /// The read with a limit and a close that the tests choose. The limit can only be lowered from the approved budget,
    /// so this path cannot widen it. `closeDescriptor` is the descriptor's close. A test uses it to observe every release
    /// and to force a failed close.
    static func read(
        at url: URL,
        limit: Int,
        closeDescriptor: (Int32) -> Int32
    ) throws(ConfigurationFileError) -> Data {
        precondition((0...maximumBytes).contains(limit), "a configuration file limit can only be lowered from the approved budget")
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw .missing
            }
            throw .openFailed(errno)
        }
        var data = Data()
        var readStep: ConfigurationFileReadStep?
        do throws(ConfigurationFileReadStep) {
            data = try collectRegularFile(descriptor, limit: limit)
        } catch {
            readStep = error
        }
        // The descriptor is released on every path. A close that fails after a refused read is kept beside that read.
        let closed = closeDescriptor(descriptor)
        let closeErrno: Int32? = closed == 0 ? nil : errno
        if let readStep {
            throw .unreadable(readStep, closeErrno: closeErrno)
        }
        if let closeErrno {
            throw .closeFailed(closeErrno)
        }
        return data
    }

    private static func collectRegularFile(
        _ descriptor: Int32,
        limit: Int
    ) throws(ConfigurationFileReadStep) -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .statusFailed(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw .notRegularFile
        }
        return try ConfigurationFileCollector.collect(limit: limit) { buffer throws(ConfigurationFileReadStep) -> Int in
            while true {
                let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                if count >= 0 {
                    return count
                }
                guard errno == EINTR else {
                    throw .readFailed(errno)
                }
            }
        }
    }
}
