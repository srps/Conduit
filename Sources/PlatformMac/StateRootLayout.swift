// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitShared
import ProxyKernel

/// The four authoritative files of a runtime environment (decision 0020).
/// Diagnostic destinations, updater metadata and the legacy import are not
/// roles: they have no write authority over the root.
package enum StateRootRole: Sendable, Equatable {
    case config
    case platformConfig
    case preferences
    case journal
}

/// Whether the configuration file is this writer's authority. `readOnlyInput` is
/// an outside file that is read and migrated in memory, never written, and it
/// takes no part in the root's ownership. In `resolve` the other three files
/// stay writer-owned. A host that never writes them, pm-proxy and headless
/// `--config`, uses `resolveReadOnlyInput`, which does not resolve them at all.
package enum StateRootConfigAccess: Sendable, Equatable {
    case writerOwned
    case readOnlyInput
}

/// A runtime resource that shares the root with the authoritative files.
/// A file that is, or lives beneath, one of these names is refused.
package enum StateRootReservedName: Sendable, Equatable, CaseIterable {
    case writerLock
    case controlSocket
    case readyFile
    case daemonReadyFile

    package var fileName: String {
        switch self {
        case .writerLock: OSStateWriterLeasing.lockFileName
        case .controlSocket: ControlSocket.fileName
        case .readyFile: "ready.json"
        case .daemonReadyFile: "daemon-ready.json"
        }
    }
}

/// A state root whose path is canonical (realpath) and names a directory. Only
/// `StateRootLayout` makes one, so a caller cannot pass an unresolved path to
/// the lease.
package struct CanonicalStateRoot: Sendable, Equatable {
    package let path: String

    init(canonicalPath: String) {
        path = canonicalPath
    }
}

/// One authoritative file. `path` is the logical path: the canonical parent plus
/// the leaf, or the canonical target when the leaf is a symbolic link. Two roles
/// are one file when they name one object (see `StateRootLayout`), however the
/// paths are spelled. Two equal spellings are not the test.
///
/// A store must write `path`, never the link name. An atomic write through a
/// link leaf replaced the link with a regular file in the probe. A store must
/// also keep the lock on the root's lock file, not on the data file, because
/// an atomic save replaces the data file's inode.
package struct StateRootFile: Sendable, Equatable {
    package let role: StateRootRole
    package let path: String
}

package struct StateRootPlan: Sendable, Equatable {
    package let root: CanonicalStateRoot
    package let configAccess: StateRootConfigAccess
    package let config: StateRootFile
    package let platformConfig: StateRootFile
    package let preferences: StateRootFile
    package let journal: StateRootFile
}

/// What a host that only reads its configuration needs: the root, and the
/// configuration as read-only input. The input may lie outside the root and is
/// never written. The other three files are not resolved, parsed or written.
package struct StateRootInputPlan: Sendable, Equatable {
    package let root: CanonicalStateRoot
    package let config: StateRootFile
}

/// Why a runtime environment cannot name a single writable state root. Each
/// case is an explicit startup refusal, not a fallback.
package enum StateRootFailure: Error, Equatable, Sendable {
    case rootMissing
    case rootUnavailable(errno: Int32)
    case rootNotDirectory
    case rootIsFilesystemRoot
    case invalidName(StateRootRole)
    case parentUnavailable(StateRootRole, errno: Int32)
    case pathUnavailable(StateRootRole, errno: Int32)
    case notRegularFile(StateRootRole)
    /// A writer-owned file resolves outside the root. Migrate it into the root
    /// or pass it as read-only input; the daemon never imports it silently.
    case outsideRoot(StateRootRole)
    case reservedName(StateRootRole, StateRootReservedName)
    case overlap(StateRootRole, StateRootRole)
    /// The volume could not say whether it distinguishes case. It was asked only
    /// because two missing names match after case folding.
    case caseSensitivityUnavailable(errno: Int32)
    /// The volume answered neither way, and two missing names match after case
    /// folding. The layout refuses rather than guessing either answer.
    case caseSensitivityUnknown
}

/// Resolves a runtime environment into one canonical root and checked file
/// identities. This is a pure check over the file-system effects: it opens and
/// locks nothing, and creates nothing except a missing root when the caller asks.
///
/// Sameness of two names is decided by the object they name, not their spelling
/// (`sameEntry`). An existing name is compared by device and inode, so a case
/// alias, a symbolic link or a hard link of another role is one file. A name that
/// does not exist yet is compared by its parent directory and its leaf. Canonically
/// equivalent leaves (NFC and NFD spellings) are one name. Leaves that match only
/// after Unicode case folding are one name on a volume that folds case, and two
/// names on a case-sensitive volume. The folding comparison is conservative, not
/// APFS's own table, so the layout does not claim exact APFS equivalence.
package enum StateRootLayout {
    /// Resolves the writer layout: all four files, containment, reserved names and
    /// disjointness.
    /// - Parameter createRootIfMissing: creates a root that does not exist yet,
    ///   with mode 0700. An existing root is never changed.
    package static func resolve(
        _ environment: RuntimeEnvironment,
        configAccess: StateRootConfigAccess,
        createRootIfMissing: Bool = false,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> StateRootPlan {
        let root = try canonicalRoot(environment.configDirectory.path, createIfMissing: createRootIfMissing, fileSystem: fileSystem)
        let config = try resolveFile(.config, environment.configFile.path, fileSystem: fileSystem)
        let platformConfig = try resolveFile(.platformConfig, environment.platformConfigFile.path, fileSystem: fileSystem)
        let preferences = try resolveFile(.preferences, environment.preferencesFile.path, fileSystem: fileSystem)
        let journal = try resolveFile(.journal, environment.platformStateFile.path, fileSystem: fileSystem)

        var writers = [platformConfig, preferences, journal]
        if configAccess == .writerOwned {
            writers.insert(config, at: 0)
        }
        for file in writers {
            try checkContainment(file, root: root.path)
        }
        // Read-only input is not a writer, but a runtime resource at its name
        // would overwrite it, so every role is checked for reserved names.
        for file in [config, platformConfig, preferences, journal] {
            try checkReserved(file, root: root.path, fileSystem: fileSystem)
        }
        try checkDisjoint(writers, fileSystem: fileSystem)

        return StateRootPlan(
            root: root,
            configAccess: configAccess,
            config: config,
            platformConfig: platformConfig,
            preferences: preferences,
            journal: journal
        )
    }

    /// Resolves what a read-only configuration host needs: the root, and its
    /// configuration as read-only input. The other three files are not resolved,
    /// so an unused sidecar cannot refuse startup, and nothing else is read or
    /// written. The input may lie outside the root. It is refused only where a
    /// runtime resource in the root would overwrite it.
    /// - Parameter createRootIfMissing: as in `resolve`.
    package static func resolveReadOnlyInput(
        _ environment: RuntimeEnvironment,
        createRootIfMissing: Bool = false,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> StateRootInputPlan {
        let root = try canonicalRoot(environment.configDirectory.path, createIfMissing: createRootIfMissing, fileSystem: fileSystem)
        let config = try resolveFile(.config, environment.configFile.path, fileSystem: fileSystem)
        try checkReserved(config, root: root.path, fileSystem: fileSystem)
        return StateRootInputPlan(root: root, config: config)
    }

    private static func canonicalRoot(
        _ path: String,
        createIfMissing: Bool,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> CanonicalStateRoot {
        let kind: StateRootEntryKind
        do { kind = try fileSystem.entryKind(at: path) } catch { throw .rootUnavailable(errno: error.errno) }
        if kind == .missing {
            guard createIfMissing else { throw .rootMissing }
            do { try fileSystem.createDirectory(at: path) } catch { throw .rootUnavailable(errno: error.errno) }
        }
        let canonical: String
        do { canonical = try fileSystem.canonicalPath(of: path) } catch { throw .rootUnavailable(errno: error.errno) }
        guard canonical != "/" else { throw .rootIsFilesystemRoot }
        let canonicalKind: StateRootEntryKind
        do { canonicalKind = try fileSystem.entryKind(at: canonical) } catch { throw .rootUnavailable(errno: error.errno) }
        guard canonicalKind == .directory else { throw .rootNotDirectory }
        return CanonicalStateRoot(canonicalPath: canonical)
    }

    /// Resolves a file's identity without requiring that it exists. The parent
    /// must exist. A missing parent is refused as `parentUnavailable(ENOENT)`.
    /// That is a preflight result of this layout, which creates nothing and
    /// resolves no missing directory tail. It does not claim that a store cannot
    /// create the directory: the existing save paths do create parents. A store
    /// that does so must take the lease first, and must resolve the created path
    /// with this function again before it writes.
    private static func resolveFile(
        _ role: StateRootRole,
        _ path: String,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> StateRootFile {
        let url = URL(fileURLWithPath: path)
        let leaf = url.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            throw .invalidName(role)
        }
        let parentPath = url.deletingLastPathComponent().path
        let parent: String
        do { parent = try fileSystem.canonicalPath(of: parentPath) } catch { throw .parentUnavailable(role, errno: error.errno) }
        // A file beneath a regular file is not a missing file: it names nothing.
        let parentKind: StateRootEntryKind
        do { parentKind = try fileSystem.entryKind(at: parent) } catch { throw .parentUnavailable(role, errno: error.errno) }
        guard parentKind == .directory else { throw .parentUnavailable(role, errno: ENOTDIR) }
        let candidate = parent == "/" ? "/" + leaf : parent + "/" + leaf

        let kind: StateRootEntryKind
        do { kind = try fileSystem.entryKind(at: candidate) } catch { throw .pathUnavailable(role, errno: error.errno) }
        switch kind {
        case .missing, .regularFile:
            return StateRootFile(role: role, path: candidate)
        case .symbolicLink:
            let target: String
            do { target = try fileSystem.canonicalPath(of: candidate) } catch { throw .pathUnavailable(role, errno: error.errno) }
            let targetKind: StateRootEntryKind
            do { targetKind = try fileSystem.entryKind(at: target) } catch { throw .pathUnavailable(role, errno: error.errno) }
            guard targetKind == .regularFile else { throw .notRegularFile(role) }
            return StateRootFile(role: role, path: target)
        case .directory, .other:
            throw .notRegularFile(role)
        }
    }

    /// A writer-owned file must resolve inside the root. This compares canonical
    /// path strings, so a file reached through a case-variant spelling of an
    /// in-root directory is refused as outside. That is conservative, not a claim
    /// that it is inside.
    private static func checkContainment(_ file: StateRootFile, root: String) throws(StateRootFailure) {
        guard file.path.hasPrefix(root + "/") else { throw .outsideRoot(file.role) }
    }

    /// A file is refused when it is, or lives beneath, a runtime resource name in
    /// the root. The comparison is by object (`sameEntry`), so a case alias or a
    /// hard link of a reserved name is refused too.
    private static func checkReserved(
        _ file: StateRootFile,
        root: String,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) {
        let top = try namedEntry(at: topLevelPath(file.path, root: root), role: file.role, fileSystem: fileSystem)
        for reserved in StateRootReservedName.allCases {
            let name = try namedEntry(at: root + "/" + reserved.fileName, role: file.role, fileSystem: fileSystem)
            if try sameEntry(top, name, fileSystem: fileSystem) {
                throw .reservedName(file.role, reserved)
            }
        }
    }

    /// The entry that decides a path's place under the root: the root's child
    /// that holds the path, or the path itself when it is that child. A path
    /// outside the root is its own entry.
    private static func topLevelPath(_ path: String, root: String) -> String {
        let prefix = root + "/"
        guard path.hasPrefix(prefix) else { return path }
        let relative = path.dropFirst(prefix.count)
        guard let slash = relative.firstIndex(of: "/") else { return path }
        return prefix + String(relative[..<slash])
    }

    /// What a path names on disk, for the comparisons. The parent directory and
    /// the leaf are what the name would be if it does not exist yet. The identity
    /// is what it is if it does.
    private struct NamedEntry {
        let directory: String
        let parent: StateRootFileIdentity
        let leaf: String
        let identity: StateRootFileIdentity?
    }

    private static func namedEntry(
        at path: String,
        role: StateRootRole,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> NamedEntry {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        let parentIdentity: StateRootFileIdentity?
        let identity: StateRootFileIdentity?
        do {
            parentIdentity = try fileSystem.identity(at: directory)
            identity = try fileSystem.identity(at: path)
        } catch {
            throw .pathUnavailable(role, errno: error.errno)
        }
        // Every compared path has an existing parent, because its resolution
        // required one. A missing parent here is an error, not a silent match.
        guard let parent = parentIdentity else { throw .parentUnavailable(role, errno: ENOENT) }
        return NamedEntry(directory: directory, parent: parent, leaf: url.lastPathComponent, identity: identity)
    }

    /// Whether two names are one file.
    /// - An existing name and a name that does not exist are never one file: a
    ///   name that exists is found by lookup, so a missing name is not an alias of it.
    /// - Two existing names are one file when they are the same object, whatever
    ///   their spelling or links. Two roles that share an object are an overlap.
    /// - Two missing names are one file when they are in the same directory object
    ///   and their leaves are canonically equivalent, or match after case folding on
    ///   a volume that folds case.
    private static func sameEntry(
        _ first: NamedEntry,
        _ second: NamedEntry,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> Bool {
        switch (first.identity, second.identity) {
        case let (a?, b?): return a == b
        case (nil, nil): break
        default: return false
        }
        guard first.parent == second.parent else { return false }
        // Swift `==` compares canonical equivalence, so NFC and NFD spellings match
        // on every volume. The volume's normalization behavior is not queryable here.
        if first.leaf == second.leaf { return true }
        // The volume is asked only when the folded names match. A case-sensitive
        // volume then answers false, and the two spellings stay distinct.
        guard foldedLeaf(first.leaf) == foldedLeaf(second.leaf) else { return false }
        return try foldsCase(directory: first.directory, fileSystem: fileSystem)
    }

    /// The case-insensitive key of a missing name's leaf: Foundation's case folding
    /// in a fixed locale, which removes case distinctions, including final sigma,
    /// long s and micro sign. It is not APFS's own table. So it can refuse a pair
    /// APFS keeps apart, and it can miss an alias that APFS folds and it does not.
    private static func foldedLeaf(_ leaf: String) -> String {
        leaf.folding(options: [.caseInsensitive], locale: foldingLocale)
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Whether the volume of `directory` folds case. Asked only when two missing
    /// names match after case folding. A volume that does not answer is refused,
    /// not assumed to be either kind.
    private static func foldsCase(directory: String, fileSystem: any StateRootFileSystem) throws(StateRootFailure) -> Bool {
        let answer: Bool?
        do {
            answer = try fileSystem.volumeSupportsCaseSensitiveNames(at: directory)
        } catch {
            throw .caseSensitivityUnavailable(errno: error.errno)
        }
        guard let sensitive = answer else { throw .caseSensitivityUnknown }
        return !sensitive
    }

    /// The writer-owned files are few (at most four), so pairwise is bounded.
    private static func checkDisjoint(_ files: [StateRootFile], fileSystem: any StateRootFileSystem) throws(StateRootFailure) {
        var entries: [NamedEntry] = []
        for file in files {
            entries.append(try namedEntry(at: file.path, role: file.role, fileSystem: fileSystem))
        }
        for first in files.indices {
            for second in files.indices where second > first {
                if try sameEntry(entries[first], entries[second], fileSystem: fileSystem) {
                    throw .overlap(files[first].role, files[second].role)
                }
            }
        }
    }
}
