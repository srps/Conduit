// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// What an entry is, read without following a symbolic link.
package enum StateRootEntryKind: Sendable, Equatable {
    case missing
    case regularFile
    case directory
    case symbolicLink
    case other
}

/// The device and inode of an existing entry, read without following a link.
/// Two names with equal identities are one object at the moment of resolution.
/// The identity is not a stable key: an atomic save replaces a data file's inode,
/// so nothing may compare a recorded identity after the file has been written.
package struct StateRootFileIdentity: Sendable, Equatable {
    package let device: UInt64
    package let inode: UInt64
}

package struct StateRootFileSystemError: Error, Equatable, Sendable {
    package let errno: Int32
}

/// The file-system questions the state-root layout asks. Each is an effect, so
/// the layout is tested against `FakeStateRootFileSystem` and the real APFS
/// behavior is covered separately by probes in scratch directories.
package protocol StateRootFileSystem: Sendable {
    /// lstat(2). An absent entry, or one behind a non-directory, is `.missing`.
    func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind
    /// lstat(2)'s identity. Nil when the entry is absent, as `entryKind` reports it.
    func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity?
    /// realpath(3). The path must exist; every link and `.`/`..` is resolved.
    func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String
    /// Whether the volume holding an existing directory distinguishes names by
    /// case. Nil when the volume does not say. The answer is asked only when two
    /// missing names match after case folding, and nil is refused, not assumed.
    func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool?
    /// mkdir(2) with mode 0700. Only for a root that is missing. An existing
    /// directory is never chmod'ed or otherwise changed.
    func createDirectory(at path: String) throws(StateRootFileSystemError)
}

package struct OSStateRootFileSystem: StateRootFileSystem {
    package init() {}

    package func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw StateRootFileSystemError(errno: code)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    package func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw StateRootFileSystemError(errno: code)
        }
        return StateRootFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    package func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String {
        guard let resolved = realpath(path, nil) else {
            throw StateRootFileSystemError(errno: errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    package func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool? {
        // A fresh URL each call: resource values are cached on the URL object.
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            return try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        } catch {
            // A failed query is not an answer. Only a POSIX error keeps its code;
            // anything else is reported as EIO, and the layout refuses either way.
            let nsError = error as NSError
            let code = nsError.domain == NSPOSIXErrorDomain ? Int32(nsError.code) : EIO
            throw StateRootFileSystemError(errno: code)
        }
    }

    package func createDirectory(at path: String) throws(StateRootFileSystemError) {
        guard mkdir(path, 0o700) == 0 else {
            throw StateRootFileSystemError(errno: errno)
        }
    }
}
