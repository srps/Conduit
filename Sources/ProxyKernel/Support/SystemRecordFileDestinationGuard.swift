// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The machine's answer to `RecordFileDestinationGuarding`, from read-only metadata calls
/// (`realpath`, `lstat`, `stat`, `fstat`) and one volume-capability read. It writes nothing
/// and changes no machine state.
///
/// Canonical paths resolve symlinks through the deepest existing ancestor, so a destination
/// under a missing directory still compares correctly. A destination is refused before anything
/// is created when its path names a protected file, lies beneath one, or is an ancestor of one.
/// Those relations compare whole path components with Swift string equality, which is canonical
/// equivalence, so a canonically equivalent spelling is refused on every volume. Identity is
/// device and inode, which catches hardlinks. A name that differs from a protected path only by
/// case or folding is refused when the volume is case-insensitive or does not say, because there
/// it may name the protected file. A case-sensitive volume admits it as the distinct file it is.
/// Any metadata failure refuses the write rather than guessing.
///
/// This does not stop an outside process from retargeting a path between the check and the
/// write. The descriptor check after open narrows that window and does not close it.
///
/// The concrete type is internal. Callers take `any RecordFileDestinationGuarding` from
/// `systemRecordFileDestinationGuard(protected:)`.
struct SystemRecordFileDestinationGuard: RecordFileDestinationGuarding {
    /// Whether the volume holding a directory is case-sensitive. nil means the volume does not say.
    typealias CaseSensitivityProbe = @Sendable (URL) throws -> Bool?

    /// The two reads the canonical climb makes. They are one value so a test can order a real
    /// creation between them while the real calls still answer. Production uses `system`.
    struct PathReads: Sendable {
        /// The `errno` a read failed with.
        struct Failure: Error, Equatable {
            let code: Int32

            /// Nothing is at the name, or an ancestor of it is not a directory.
            var isMissingName: Bool { code == ENOENT || code == ENOTDIR }
        }

        /// `realpath(3)`: the resolved path, or the failure that stopped it.
        let resolve: @Sendable (String) -> Result<String, Failure>
        /// `lstat(2)`, which does not follow a final symlink: nil when an entry is there.
        let entryFailure: @Sendable (String) -> Failure?

        static let system = PathReads(
            resolve: { path in
                guard let resolved = realpath(path, nil) else { return .failure(Failure(code: errno)) }
                defer { free(resolved) }
                return .success(String(cString: resolved))
            },
            entryFailure: { path in
                var info = stat()
                return lstat(path, &info) == 0 ? nil : Failure(code: errno)
            })
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct CanonicalPath {
        /// Symlinks resolved through the deepest existing ancestor, then the missing components.
        let path: String
        /// `path` in canonical caseless form (see `fold`). Equal here but not in `path` is a
        /// case-equivalent name, and the volume decides whether it is the same file.
        let folded: String
        /// The deepest existing ancestor, resolved. Its volume answers for `path`.
        let volumeDirectory: String
        /// `path` split on "/", so a relation is judged on whole components.
        let components: [String]
        /// `folded` split on "/", for the same relation under case and folding.
        let foldedComponents: [String]
    }

    private let protected: [ProtectedRecordFile]
    private let caseSensitivity: CaseSensitivityProbe
    private let reads: PathReads

    /// `protected` holds at most one entry per resource code, so its capacity is fixed by
    /// `ProtectedRecordResource` at construction. A composer cannot grow it by passing more paths.
    init(
        protected: [ProtectedRecordFile],
        caseSensitivity: @escaping CaseSensitivityProbe = SystemRecordFileDestinationGuard.volumeCaseSensitivity,
        reads: PathReads = .system
    ) {
        precondition(protected.count <= ProtectedRecordResource.allCases.count,
                     "more protected files than resource codes")
        precondition(Set(protected.map(\.resource)).count == protected.count,
                     "a protected resource is listed twice")
        self.protected = protected
        self.caseSensitivity = caseSensitivity
        self.reads = reads
    }

    func admit(destination: URL) throws {
        let target = try canonicalPath(destination, resource: nil)
        for entry in protected {
            let other = try canonicalPath(entry.url, resource: entry.resource)
            // Beneath a protected file, the destination's parents would have to be created
            // as directories where that file is. An ancestor of one would become a file where
            // the protected file's directory is. Both are refused before any creation.
            if Self.overlaps(target.components, other.components) {
                throw RecordFileDestinationRefusal(reason: .protectedPath, resource: entry.resource)
            }
            guard Self.overlaps(target.foldedComponents, other.foldedComponents) else { continue }
            if try caseAliasRefuses(target, resource: entry.resource) {
                throw RecordFileDestinationRefusal(reason: .protectedPath, resource: entry.resource)
            }
        }
        guard let identity = try Self.identity(of: destination, resource: nil) else { return }
        try refuseIfProtected(identity)
    }

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: nil)
        }
        try refuseIfProtected(FileIdentity(device: info.st_dev, inode: info.st_ino))
    }

    private func refuseIfProtected(_ identity: FileIdentity) throws {
        for entry in protected {
            if try Self.identity(of: entry.url, resource: entry.resource) == identity {
                throw RecordFileDestinationRefusal(reason: .protectedIdentity, resource: entry.resource)
            }
        }
    }

    /// A case-equivalent name, or a case-equivalent ancestor or descendant of a protected path, is
    /// refused on a case-insensitive volume. An unknown answer is refused too, since admitting could
    /// create the protected file under another name. The probe is asked about the destination's volume
    /// only, the one the two names are compared on. Each call gets a fresh URL, so no cached volume
    /// value answers.
    private func caseAliasRefuses(_ target: CanonicalPath, resource: ProtectedRecordResource) throws -> Bool {
        let answer: Bool?
        do {
            answer = try caseSensitivity(URL(fileURLWithPath: target.volumeDirectory, isDirectory: true))
        } catch {
            throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
        }
        guard let answer else {
            throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
        }
        return !answer
    }

    /// The canonical path of the deepest existing ancestor, then the missing components appended.
    /// A dangling symlink is refused: creating its target would write a file the guard never judged.
    ///
    /// The climb is bounded by the input. Every missing component is a component of `url`, so the
    /// list holds at most `PATH_MAX / 2` entries (a slash and a name byte each). Only ENOENT and
    /// ENOTDIR let the climb continue; any other failure refuses, because it is not a missing name.
    ///
    /// An entry that `lstat` finds where `realpath` found nothing gets one fresh resolution and then
    /// either resolves or is refused, so it adds at most one read and never continues the climb.
    private func canonicalPath(_ url: URL, resource: ProtectedRecordResource?) throws -> CanonicalPath {
        var existing = url.standardizedFileURL
        guard existing.path.utf8.count < Int(PATH_MAX) else {
            throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
        }
        var missing: [String] = []
        while true {
            switch reads.resolve(existing.path) {
            case .success(let base):
                return Self.canonicalPath(resolved: base, missing: missing)
            case .failure(let failure) where failure.isMissingName:
                break
            case .failure:
                throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
            }
            guard let entryFailure = reads.entryFailure(existing.path) else {
                // Either the entry is a dangling symlink, or the object was created between the two
                // reads, as a protected file's first atomic write is. A fresh resolution tells them
                // apart: a created object resolves now and is judged like any other, and a link that
                // still does not resolve is refused.
                guard case .success(let base) = reads.resolve(existing.path) else {
                    throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
                }
                return Self.canonicalPath(resolved: base, missing: missing)
            }
            guard entryFailure.isMissingName else {
                throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
            }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
            }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    /// `resolved` with the missing components, collected deepest first, appended in path order.
    private static func canonicalPath(resolved base: String, missing: [String]) -> CanonicalPath {
        let path = missing.reversed()
            .reduce(URL(fileURLWithPath: base, isDirectory: true)) { $0.appendingPathComponent($1) }
            .path
        let folded = fold(path)
        return CanonicalPath(path: path, folded: folded, volumeDirectory: base,
                             components: components(of: path),
                             foldedComponents: components(of: folded))
    }

    /// Whether one component list is a prefix of the other: one path names the other, or an ancestor
    /// of it. Components compare with String equality, so a boundary is always a whole component and
    /// `config.json-other` is not beneath `config.json`.
    private static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        let shared = min(lhs.count, rhs.count)
        return lhs.prefix(shared).elementsEqual(rhs.prefix(shared))
    }

    /// The path split on "/" at the scalar level. A Character split would fuse a combining mark that
    /// follows a slash with that slash, and the component boundary would disappear.
    private static func components(of path: String) -> [String] {
        path.unicodeScalars
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The canonical caseless form of a path (Unicode D145): NFD, case-folded, NFD again. Folding maps
    /// long s, final sigma and micro sign onto the letters they match, which `lowercased()` does not.
    /// The locale is pinned so a system locale cannot change the mapping. Diacritics are kept, so `café`
    /// and `cafe` stay distinct. This is a conservative approximation of APFS's own table, not a copy of
    /// it. A fold match only asks the volume, and a case-sensitive answer admits the name. The fold is
    /// not APFS's table: it can refuse a name APFS keeps distinct, and it can miss a name APFS aliases.
    private static func fold(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: foldingLocale)
            .decomposedStringWithCanonicalMapping
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// The identity a path resolves to, or nil when nothing exists there.
    private static func identity(of url: URL, resource: ProtectedRecordResource?) throws -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw RecordFileDestinationRefusal(reason: .inspectionFailed, resource: resource)
        }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Read-only volume capability. nil when the volume does not report it.
    private static func volumeCaseSensitivity(_ directory: URL) throws -> Bool? {
        try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
    }
}

/// The production guard, typed as the protocol so no caller names the backend.
package func systemRecordFileDestinationGuard(
    protected: [ProtectedRecordFile]
) -> any RecordFileDestinationGuarding {
    SystemRecordFileDestinationGuard(protected: protected)
}
