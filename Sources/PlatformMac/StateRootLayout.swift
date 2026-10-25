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

    /// The fixed logical leaf this role may be written under (decision 0028).
    /// A writer-owned file whose logical name is another spelling is refused.
    package var fixedLeaf: String {
        switch self {
        case .config: RuntimeEnvironment.configFileName
        case .platformConfig: RuntimeEnvironment.platformConfigFileName
        case .preferences: RuntimeEnvironment.preferencesFileName
        case .journal: RuntimeEnvironment.platformStateFileName
        }
    }
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
    /// A writer-owned file's logical name is not its fixed slot (decision 0028).
    /// Only the fixed name is writable: move or rename the file to it beneath the
    /// root. Nothing is copied, imported or renamed, and the file is not read.
    case unsupportedFileName(StateRootRole)
    /// The root directory's identity changed between the check before the lease
    /// and the check after the layout, or the layout names another root. A check,
    /// not a compare-and-swap: a retarget after the last check is not excluded.
    case rootChanged
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
/// locks nothing, and creates only missing root/ancestor directories when the caller asks.
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
    /// Resolves the writer layout: all four files, their fixed slots, containment,
    /// reserved names and disjointness. A writer-owned role must name its fixed
    /// leaf beneath the root (decision 0028); the configuration is checked the
    /// same way only when this host writes it.
    /// - Parameter createRootIfMissing: creates the missing root and ancestors with
    ///   mode 0700. Existing directories are never changed.
    package static func resolve(
        _ environment: RuntimeEnvironment,
        configAccess: StateRootConfigAccess,
        createRootIfMissing: Bool = false,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> StateRootPlan {
        let root = try prepareRoot(environment.configDirectory.path, createIfMissing: createRootIfMissing, fileSystem: fileSystem)
        let configSlot: String? = configAccess == .writerOwned ? StateRootRole.config.fixedLeaf : nil
        let config = try resolveFile(.config, environment.configFile.path, root: root, slot: configSlot, fileSystem: fileSystem)
        let platformConfig = try resolveFile(
            .platformConfig, environment.platformConfigFile.path, root: root, slot: StateRootRole.platformConfig.fixedLeaf, fileSystem: fileSystem
        )
        let preferences = try resolveFile(
            .preferences, environment.preferencesFile.path, root: root, slot: StateRootRole.preferences.fixedLeaf, fileSystem: fileSystem
        )
        let journal = try resolveFile(
            .journal, environment.platformStateFile.path, root: root, slot: StateRootRole.journal.fixedLeaf, fileSystem: fileSystem
        )

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
        let root = try prepareRoot(environment.configDirectory.path, createIfMissing: createRootIfMissing, fileSystem: fileSystem)
        let config = try resolveFile(.config, environment.configFile.path, root: root, slot: nil, fileSystem: fileSystem)
        try checkReserved(config, root: root.path, fileSystem: fileSystem)
        return StateRootInputPlan(root: root, config: config)
    }

    /// The pure name check of the writer-owned files (decision 0028), run before anything is
    /// touched. It takes no file-system effect, so it cannot create a directory, take the lease
    /// or read a file. A writer role's logical leaf must be its fixed slot, or a fold alias that
    /// the post-lease check in `fixedSlotPath` decides by asking the volume. Any other leaf is
    /// `unsupportedFileName` here, so an arbitrary `custom.json` or a link named `alias.json`
    /// creates nothing. Containment, reserved names and overlap stay in `resolve`, after the lease.
    package static func preflightWritableNames(_ environment: RuntimeEnvironment) throws(StateRootFailure) {
        let writers: [(role: StateRootRole, path: String)] = [
            (.config, environment.configFile.path),
            (.platformConfig, environment.platformConfigFile.path),
            (.preferences, environment.preferencesFile.path),
            (.journal, environment.platformStateFile.path),
        ]
        for writer in writers {
            let leaf = try logicalLeaf(of: writer.path, role: writer.role)
            guard slotSpelling(of: leaf, slot: writer.role.fixedLeaf) != .other else {
                throw .unsupportedFileName(writer.role)
            }
        }
    }

    /// The canonical root of a configuration directory. A missing directory is
    /// created only when `createIfMissing` is set. The root and each missing ancestor are
    /// created with mode 0700, outermost first (`createMissingDirectories`). An existing
    /// ancestor, and an existing root, is never changed. A racing creator is tolerated:
    /// an EEXIST is judged by a directory recheck. Startup calls this before it takes the
    /// lease, so creating the missing directories is the only change made to the root before
    /// the lease is held.
    package static func prepareRoot(
        _ path: String,
        createIfMissing: Bool,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> CanonicalStateRoot {
        // The OS refuses a path whose C string, terminator included, exceeds PATH_MAX. Refusing it here, before
        // any effect, bounds the missing-name list in `createMissingDirectories` for every file system, fakes included.
        guard path.utf8CString.count <= Int(PATH_MAX) else { throw .rootUnavailable(errno: ENAMETOOLONG) }
        let kind: StateRootEntryKind
        do { kind = try fileSystem.entryKind(at: path) } catch { throw .rootUnavailable(errno: error.errno) }
        if kind == .missing {
            guard createIfMissing else { throw .rootMissing }
            try createMissingDirectories(endingAt: path, fileSystem: fileSystem)
        }
        let canonical: String
        do { canonical = try fileSystem.canonicalPath(of: path) } catch { throw .rootUnavailable(errno: error.errno) }
        guard canonical != "/" else { throw .rootIsFilesystemRoot }
        let canonicalKind: StateRootEntryKind
        do { canonicalKind = try fileSystem.entryKind(at: canonical) } catch { throw .rootUnavailable(errno: error.errno) }
        guard canonicalKind == .directory else { throw .rootNotDirectory }
        return CanonicalStateRoot(canonicalPath: canonical)
    }

    /// Creates the root and each of its missing ancestors, outermost first, one `createDirectory`
    /// each. The walk climbs from the root until it meets an existing entry, which must be a
    /// directory once any link is followed: a file, another object or a dangling link is refused,
    /// and nothing beneath it is created. A directory that a racing creator makes first is accepted
    /// only when it is a directory. The bound is set by `prepareRoot`: the root path, terminator included,
    /// is at most PATH_MAX bytes (1024 on Darwin). Each missing entry is a prefix of that path, and each
    /// step strictly shortens it. Thus at most PATH_MAX - 1 entries are held, each under PATH_MAX
    /// bytes, and the array is never unbounded. A failure leaves
    /// the directories already made in place: nothing is rolled back, and the refusal names the errno of
    /// the step that failed.
    private static func createMissingDirectories(endingAt path: String, fileSystem: any StateRootFileSystem) throws(StateRootFailure) {
        var missing: [String] = []
        var current = path
        while current != "/" {
            let kind: StateRootEntryKind
            do { kind = try fileSystem.entryKind(at: current) } catch { throw .rootUnavailable(errno: error.errno) }
            if kind != .missing {
                try requireDirectory(current, fileSystem: fileSystem)
                break
            }
            missing.append(current)
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            // A path that has no parent to climb to would loop here. Paths are absolute, so this refuses rather than spins.
            guard parent != current else { throw .rootUnavailable(errno: EINVAL) }
            current = parent
        }
        for directory in missing.reversed() {
            do {
                try fileSystem.createDirectory(at: directory)
            } catch {
                guard error.errno == EEXIST else { throw .rootUnavailable(errno: error.errno) }
                try requireDirectory(directory, fileSystem: fileSystem)
            }
        }
    }

    /// The entry at `path`, followed through any link, must be a directory. A dangling link fails
    /// with the errno realpath gives. A file or another object is `rootNotDirectory`.
    private static func requireDirectory(_ path: String, fileSystem: any StateRootFileSystem) throws(StateRootFailure) {
        let resolved: String
        do { resolved = try fileSystem.canonicalPath(of: path) } catch { throw .rootUnavailable(errno: error.errno) }
        let kind: StateRootEntryKind
        do { kind = try fileSystem.entryKind(at: resolved) } catch { throw .rootUnavailable(errno: error.errno) }
        guard kind == .directory else { throw .rootNotDirectory }
    }

    /// The logical leaf of a configured path: its last component, which must name something.
    private static func logicalLeaf(of path: String, role: StateRootRole) throws(StateRootFailure) -> String {
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else { throw .invalidName(role) }
        return leaf
    }

    /// Resolves a file's identity without requiring that it exists. The parent
    /// must exist. A missing parent is refused as `parentUnavailable(ENOENT)`.
    /// That is a preflight result of this layout, which creates nothing and
    /// resolves no missing directory tail. It does not claim that a store cannot
    /// create the directory: the existing save paths do create parents. A store
    /// that does so must take the lease first, and must resolve the created path
    /// with this function again before it writes.
    /// `slot` is the fixed logical leaf a writer-owned file must name, or nil for a
    /// read-only input, which may be any file.
    private static func resolveFile(
        _ role: StateRootRole,
        _ path: String,
        root: CanonicalStateRoot,
        slot: String?,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> StateRootFile {
        let leaf = try logicalLeaf(of: path, role: role)
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let parent: String
        do { parent = try fileSystem.canonicalPath(of: parentPath) } catch { throw .parentUnavailable(role, errno: error.errno) }
        // A file beneath a regular file is not a missing file: it names nothing.
        let parentKind: StateRootEntryKind
        do { parentKind = try fileSystem.entryKind(at: parent) } catch { throw .parentUnavailable(role, errno: error.errno) }
        guard parentKind == .directory else { throw .parentUnavailable(role, errno: ENOTDIR) }
        let candidate: String
        if let slot {
            candidate = try fixedSlotPath(role, leaf: leaf, slot: slot, parent: parent, root: root.path, fileSystem: fileSystem)
        } else {
            candidate = parent == "/" ? "/" + leaf : parent + "/" + leaf
        }

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

    /// The logical name check of a writer-owned file (decision 0028), after the lease. The logical
    /// parent must be the canonical root, reached through any root or directory alias. The logical
    /// leaf must be the role's fixed slot (`slotSpelling`, the same predicate as `preflightWritableNames`).
    /// A fold alias is a slot only on a volume that folds case, which only this check can ask. Nothing
    /// else is a writable slot, whatever it links to. The result is the slot's spelling beneath the root,
    /// so a case alias writes the fixed name. A link at the slot is still resolved afterwards.
    private static func fixedSlotPath(
        _ role: StateRootRole,
        leaf: String,
        slot: String,
        parent: String,
        root: String,
        fileSystem: any StateRootFileSystem
    ) throws(StateRootFailure) -> String {
        guard parent == root else { throw .outsideRoot(role) }
        switch slotSpelling(of: leaf, slot: slot) {
        case .slot:
            break
        case .foldAlias:
            guard try foldsCase(directory: root, fileSystem: fileSystem) else { throw .unsupportedFileName(role) }
        case .other:
            throw .unsupportedFileName(role)
        }
        return root + "/" + slot
    }

    /// How a logical leaf relates to its fixed slot: the slot itself, a fold alias that only a
    /// case-folding volume can accept, or any other name. The one predicate for both the
    /// pre-lease preflight and the post-lease check, so the two cannot disagree on a name.
    private enum SlotSpelling: Equatable {
        case slot
        case foldAlias
        case other
    }

    private static func slotSpelling(of leaf: String, slot: String) -> SlotSpelling {
        if leaf == slot { return .slot }
        return foldedLeaf(leaf) == foldedLeaf(slot) ? .foldAlias : .other
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
