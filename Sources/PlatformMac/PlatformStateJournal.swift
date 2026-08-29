// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// A platform setting Conduit changes on the user's machine.
///
/// Each case documents the keys its records use, because the journal stores
/// prior values as an untyped `[String: String]` so that one record type can
/// serve every surface. The alternative — a payload enum with a case per
/// surface — puts the same knowledge in two places and reintroduces exactly the
/// per-surface divergence this file exists to remove.
package enum PlatformSurface: String, Codable, Sendable, CaseIterable {
    /// Scope: network service name. Keys: `webEnabled`, `webHost`, `webPort`,
    /// `secureEnabled`, `secureHost`, `securePort`, `autoEnabled`, `autoURL`,
    /// `bypassDomains` (comma-separated; an empty string means the service had
    /// no bypass entries). `ProxyServiceState` is the typed reader and writer
    /// for this shape — decode through it rather than indexing the dictionary.
    case systemProxy

    /// Scope: network service name. Keys: `servers` (comma-separated; an empty
    /// string means the service had no explicit servers).
    case systemDNS

    /// Scope: variable name. Keys: `value`.
    case launchdEnvironment

    /// Scope: resolver domain. Keys: `contents` (the whole file as written).
    case resolverFile
}

/// What the journal knows about a scope's state before Conduit touched it.
package enum RecordedPrior: Equatable, Sendable {
    /// No record. The journal cannot say what was there, so teardown must fall
    /// back to its unconditional behaviour — see `PlatformStateJournal`.
    case notRecorded
    /// Nothing was there: teardown removes what we added rather than restoring.
    case wasAbsent
    /// Something was there: teardown puts it back.
    case wasPresent([String: String])
}

package struct PlatformStateRecord: Codable, Equatable, Sendable {
    package var surface: PlatformSurface
    package var scope: String
    /// `nil` records "nothing was here before us" — distinct from having no
    /// record at all, which the journal represents by the entry's absence.
    package var priorValue: [String: String]?
    package var recordedAt: Date
}

/// Remembers what the machine looked like before Conduit changed it, so
/// teardown can put it back instead of blanket-clearing.
///
/// ## Why this exists
///
/// Four platform surfaces needed the same thing and had three different answers
/// (or none). `SystemDNSManager` kept a bespoke `saved-dns.json` snapshot and
/// restored from it. `SystemProxyManager`, the launchd environment, and the
/// resolver files kept nothing at all and tore down unconditionally — so the
/// first stop, quit, or failed start silently erased a system proxy the user or
/// an MDM profile had configured, with nothing able to put it back.
///
/// `EnvironmentManager`'s shell-profile marker block is deliberately *not*
/// folded in here. It answers a different question — "which region of a file we
/// do not own is ours" — and snapshotting a user's `.zshrc` into our state
/// directory would be worse than the delimiters it uses today.
///
/// ## The safety rule
///
/// Ownership evidence may only ever *narrow* a teardown when it positively
/// identifies a different owner. A missing record means "we do not know", and
/// the caller must then fall back to its unconditional clear.
///
/// The inverse — refusing to clean up anything we cannot prove we own — turns
/// every lost record (a `SIGKILL`, an installer swapping the app, a wiped state
/// directory) into stranded resolver files and a system proxy pointing at a
/// port nothing serves. That breaks DNS and proxying for every client on the
/// machine and is strictly worse than over-clearing, which at most costs the
/// user a setting they can see and restore. Over-clearing is recoverable;
/// stranding is not. When in doubt, clean up.
package final class PlatformStateJournal: @unchecked Sendable {
    /// How much the journal file can be trusted to describe what we hold.
    package enum FileState: Equatable, Sendable {
        /// No file. Nothing was ever recorded, so there is nothing outstanding.
        case absent
        /// A file exists but could not be read or decoded. It may have
        /// described settings we changed, so callers must assume the worst and
        /// fall back to an unconditional teardown.
        case unreadable
        /// Read successfully; its contents are the whole truth.
        case loaded
    }

    private let fileURL: URL
    private let logger: (any LogSink)?
    private let lock = NSLock()
    private var loaded: [PlatformStateRecord]?
    private var fileStateBox: FileState = .absent

    package init(fileURL: URL, logger: (any LogSink)? = nil) {
        self.fileURL = fileURL
        self.logger = logger
    }

    /// Whether the on-disk journal could be read. Callers use this to tell
    /// "we hold nothing on this surface" from "we cannot say what we hold".
    package var fileState: FileState {
        lock.lock()
        defer { lock.unlock() }
        _ = loadLocked()
        return fileStateBox
    }

    /// Whether the journal positively knows it holds nothing for `surface` —
    /// no prior values and no applied marker, read from a file it could parse.
    ///
    /// This is the one question whose answer may *stop* a teardown, so it is
    /// deliberately narrow: an unreadable journal returns `false`, and the
    /// caller clears unconditionally rather than risk stranding.
    package func knowsSurfaceIsIdle(_ surface: PlatformSurface) -> Bool {
        guard fileState != .unreadable else { return false }
        return !isMarkedApplied(surface: surface) && !hasRecords(for: surface)
    }

    // MARK: - Recording

    /// Records what was at `scope` before we changed it. **First write wins.**
    ///
    /// Apply runs more than once per session — config reloads, restarts, VPN
    /// transitions — and every run after the first sees *our own* value as the
    /// current state. Letting a later call overwrite the record would replace
    /// the user's original setting with ours and make restore a no-op that
    /// looks like it worked.
    package func recordPrior(
        surface: PlatformSurface,
        scope: String,
        value: [String: String]?,
        now: Date = .now
    ) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        guard !records.contains(where: { $0.surface == surface && $0.scope == scope }) else { return }
        records.append(
            PlatformStateRecord(surface: surface, scope: scope, priorValue: value, recordedAt: now)
        )
        saveLocked(records)
    }

    /// Reserved scope for the surface-ownership marker. Prefixed with a
    /// control character so it can never collide with a real scope — network
    /// service names, variable names and resolver domains are all printable.
    private static let appliedMarkerScope = "\u{0}applied"
    private static let ownershipKey = "ownership"
    private static let releasedOwnership = "released"

    /// What the journal believes about who owns a surface right now.
    package enum SurfaceOwnership: Equatable, Sendable {
        /// No marker. Either we never applied, or the record was lost.
        case unknown
        /// We applied and have not torn down.
        case applied
        /// We applied and put everything back. Whatever the surface holds now
        /// is the user's, not ours.
        case released
    }

    /// Records that a surface was applied even if it captured no per-scope
    /// prior values.
    ///
    /// "We applied and there was nothing to capture" and "we have no record"
    /// want opposite fallbacks. The first means teardown has nothing to undo
    /// and must do nothing. The second means we cannot say what we changed, so
    /// teardown has to reset the surface — and doing that in the first case
    /// would clear settings the user made *after* we applied, which is the
    /// erasing behaviour this journal exists to stop.
    package func markApplied(surface: PlatformSurface, now: Date = .now) {
        setOwnership(surface: surface, ownership: nil, now: now)
    }

    /// Records that teardown ran and put the prior values back.
    ///
    /// Unlike the prior values, which are dropped once restored, this outlives
    /// the teardown — because "the journal holds nothing for this surface" is
    /// otherwise two situations with opposite right answers. It is "we never
    /// applied, or we lost the record", where a caller must fall back to
    /// probing the machine for its own residue; and it is "we just restored",
    /// where probing is actively wrong. A user whose *own* proxy is a loopback
    /// address gets it flagged as our residue by any such probe, and the
    /// second teardown of a session then disables the settings the first one
    /// restored. Remembering that we let go is what tells the two apart.
    package func markReleased(surface: PlatformSurface, now: Date = .now) {
        setOwnership(surface: surface, ownership: Self.releasedOwnership, now: now)
    }

    /// Last write wins, deliberately, and unlike `recordPrior`. Prior values
    /// describe what was there before us and must never be overwritten by our
    /// own; ownership describes the present and has to be able to change.
    private func setOwnership(surface: PlatformSurface, ownership: String?, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        let value = ownership.map { [Self.ownershipKey: $0] }
        if let index = records.firstIndex(where: {
            $0.surface == surface && $0.scope == Self.appliedMarkerScope
        }) {
            records[index].priorValue = value
            records[index].recordedAt = now
        } else {
            records.append(
                PlatformStateRecord(
                    surface: surface,
                    scope: Self.appliedMarkerScope,
                    priorValue: value,
                    recordedAt: now
                )
            )
        }
        saveLocked(records)
    }

    package func ownership(of surface: PlatformSurface) -> SurfaceOwnership {
        lock.lock()
        defer { lock.unlock() }
        guard let marker = loadLocked().first(where: {
            $0.surface == surface && $0.scope == Self.appliedMarkerScope
        }) else {
            return .unknown
        }
        // A marker written before this key existed carries no payload and meant
        // exactly "applied", so that is what it keeps meaning.
        return marker.priorValue?[Self.ownershipKey] == Self.releasedOwnership ? .released : .applied
    }

    package func isMarkedApplied(surface: PlatformSurface) -> Bool {
        ownership(of: surface) == .applied
    }

    /// Refreshes a surface's timestamps without touching the recorded values.
    ///
    /// `recordedAt` doubles as a liveness signal — a record far in the past is
    /// read as the residue of a crashed run rather than a live session — so a
    /// long-lived session has to be able to say "still mine" without
    /// overwriting the prior values it is holding.
    package func touch(surface: PlatformSurface, now: Date = .now) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        for index in records.indices where records[index].surface == surface {
            records[index].recordedAt = now
        }
        saveLocked(records)
    }

    // MARK: - Reading

    package func prior(surface: PlatformSurface, scope: String) -> RecordedPrior {
        lock.lock()
        defer { lock.unlock() }
        guard let record = loadLocked().first(where: { $0.surface == surface && $0.scope == scope }) else {
            return .notRecorded
        }
        guard let value = record.priorValue else { return .wasAbsent }
        return .wasPresent(value)
    }

    package func scopes(for surface: PlatformSurface) -> [String] {
        records(for: surface).map(\.scope)
    }

    /// Real scopes only — the applied marker is bookkeeping, not a setting.
    package func records(for surface: PlatformSurface) -> [PlatformStateRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.surface == surface && $0.scope != Self.appliedMarkerScope }
    }

    /// Real scopes only, matching `records(for:)`. The two disagreed before:
    /// this counted the ownership marker as a record, which was harmless while
    /// the marker's only states were "present" and "absent" — every caller
    /// pairs it with `isMarkedApplied`, so the marker was covered twice. It
    /// stops being harmless once the marker can say *released*, because then a
    /// surface with nothing outstanding would still report records.
    package func hasRecords(for surface: PlatformSurface) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().contains { $0.surface == surface && $0.scope != Self.appliedMarkerScope }
    }

    package var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().isEmpty
    }

    /// Oldest `recordedAt` across a surface, for callers that treat a
    /// long-abandoned record as evidence of a crash rather than a live session.
    package func oldestRecordDate(for surface: PlatformSurface) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.surface == surface }.map(\.recordedAt).min()
    }

    // MARK: - Forgetting

    /// Drops a record once its prior value has been put back. Call *after* a
    /// successful restore: dropping it first turns a failed restore into a
    /// permanently stranded setting with no record that we caused it.
    package func forget(surface: PlatformSurface, scope: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        records.removeAll { $0.surface == surface && $0.scope == scope }
        saveLocked(records)
    }

    package func forgetAll(surface: PlatformSurface) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        records.removeAll { $0.surface == surface }
        saveLocked(records)
    }

    // MARK: - Persistence

    private func loadLocked() -> [PlatformStateRecord] {
        if let loaded { return loaded }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // No file at all: nothing was ever recorded here.
            fileStateBox = .absent
            loaded = []
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.iso8601Decoder.decode([PlatformStateRecord].self, from: data)
            fileStateBox = .loaded
            loaded = decoded
            return decoded
        } catch {
            // Recovered, not swallowed: callers read `.unreadable` as "we
            // cannot say what we changed" and fall back to an unconditional
            // teardown, which is the safe direction. Say so out loud, because
            // it also means a crash from here on cannot restore anything.
            logger?.log(
                .warning,
                "Could not read the platform-state journal at \(fileURL.path) (\(error.displayDescription)); teardown will clear settings unconditionally instead of restoring them.",
                category: .system
            )
            fileStateBox = .unreadable
            loaded = []
            return []
        }
    }

    /// Returns whether the records reached disk. The in-memory copy is
    /// updated either way, so this process keeps working from it.
    @discardableResult
    private func saveLocked(_ records: [PlatformStateRecord]) -> Bool {
        loaded = records
        do {
            let data = try JSONEncoder.prettyISO8601Encoder.encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a half-written journal read back after a crash would
            // claim prior values that were never true.
            try data.write(to: fileURL, options: .atomic)
            fileStateBox = .loaded
            return true
        } catch {
            // The in-memory copy still serves this process, so a failed write
            // is survivable *now* — but it means a crash from here on leaves
            // the user's original settings unrecoverable, which nobody would
            // otherwise learn.
            logger?.log(
                .error,
                "Could not write the platform-state journal at \(fileURL.path) (\(error.displayDescription)); if this process dies, the previous system settings cannot be restored.",
                category: .system
            )
            return false
        }
    }
}

extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var prettyISO8601Encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Legacy DNS snapshot

/// The `saved-dns.json` document 0.1.x wrote before the journal existed.
package struct LegacyDNSSnapshot: Codable, Equatable {
    package var savedAt: Date
    package var interfaces: [String: [String]]

    package init(savedAt: Date, interfaces: [String: [String]]) {
        self.savedAt = savedAt
        self.interfaces = interfaces
    }
}

extension PlatformStateJournal {
    /// Seeds the DNS surface from a 0.1.x snapshot, then removes the file.
    ///
    /// The case this exists for: 0.1.1 crashed with system-DNS management
    /// active, so the machine still points at 127.0.0.1 and the user's
    /// resolvers exist only in `saved-dns.json`; then the user upgrades. With
    /// an empty journal, launch recovery would see nothing to restore and
    /// leave DNS on a dead relay — and the next apply would record 127.0.0.1
    /// as the prior value. The snapshot's own timestamp is kept so the
    /// staleness rule judges the crash, not the upgrade.
    ///
    /// A journal that already knows the surface wins, and an unreadable
    /// journal refuses: it may describe other surfaces, and a write from here
    /// would replace it. The snapshot is the last copy of the resolvers, so it
    /// is removed only once the import is on disk — one atomic write, not a
    /// record at a time. Returns whether an import happened.
    @discardableResult
    package func importLegacyDNSSnapshot(at fileURL: URL, logger: (any LogSink)? = nil) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let snapshot = try? decoder.decode(LegacyDNSSnapshot.self, from: data) else {
            logger?.log(.warning, "Legacy DNS snapshot at \(fileURL.path) could not be read; leaving it in place.", category: .system)
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        guard fileStateBox != .unreadable else {
            logger?.log(.warning, "Legacy DNS snapshot found but the platform-state journal is unreadable; leaving both in place.", category: .system)
            return false
        }
        guard !records.contains(where: { $0.surface == .systemDNS }) else { return false }

        for (service, servers) in snapshot.interfaces {
            records.append(PlatformStateRecord(
                surface: .systemDNS,
                scope: service,
                priorValue: ["servers": servers.joined(separator: ",")],
                recordedAt: snapshot.savedAt
            ))
        }
        records.append(PlatformStateRecord(
            surface: .systemDNS,
            scope: Self.appliedMarkerScope,
            priorValue: nil,
            recordedAt: snapshot.savedAt
        ))
        guard saveLocked(records) else {
            logger?.log(.warning, "Legacy DNS snapshot could not be written into the journal; keeping \(fileURL.path) as the recovery copy.", category: .system)
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logger?.log(.warning, "Imported the legacy DNS snapshot but could not remove \(fileURL.path): \(error.displayDescription)", category: .system)
        }
        logger?.log(.notice, "Imported the 0.1.x DNS snapshot (\(snapshot.interfaces.count) interface(s)) into the platform-state journal.", category: .system)
        return true
    }
}
