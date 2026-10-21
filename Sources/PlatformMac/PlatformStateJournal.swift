// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

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
    package var locationID: String? = nil
    package var serviceID: String? = nil
    package var appliedValue: [String: String]? = nil
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
    /// Where the journal reports trouble (#191): the host's event log in
    /// both hosts, a collector in `pm-sim`. Called with the journal's lock
    /// held, so it must not call back into the journal.
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let lock = NSLock()
    private var loaded: [PlatformStateRecord]?
    private var fileStateBox: FileState = .absent
    /// Writes that failed since the last one landed. Non-zero is a
    /// failed-write episode, which is reported once, when it starts, and
    /// once more when a write lands again.
    private var failedWrites = 0
    /// Legacy-import steps already reported, so a snapshot that stays
    /// unreadable is one event, not one per launch-recovery pass.
    private var reportedImportSteps: Set<LegacyImportStep> = []

    package init(fileURL: URL, logger: (any LogSink)? = nil, eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil) {
        self.fileURL = fileURL
        self.logger = logger
        self.eventSink = eventSink
    }

    /// Applying new machine settings needs readable prior-state storage.
    /// Recovery may keep retry evidence in memory, but must not use that as
    /// permission to publish new settings while disk evidence is corrupt.
    package func requireReadableForApply() throws {
        guard fileState != .unreadable else { throw NetworkSettingsError.unreadableJournal }
    }

    /// Whether the on-disk journal could be read. Callers use this to tell
    /// "we hold nothing on this surface" from "we cannot say what we hold".
    package var fileState: FileState {
        locked {
            _ = loadLocked()
            return fileStateBox
        }
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
        locked {
            var records = loadLocked()
            guard !records.contains(where: { $0.surface == surface && $0.scope == scope }) else { return }
            records.append(
                PlatformStateRecord(surface: surface, scope: scope, priorValue: value, recordedAt: now)
            )
            saveLocked(records, operation: .recordPrior, surface: surface)
        }
    }

    /// `recordPrior` for a write that is about to happen (#175): throws when
    /// the record cannot be saved, and caches nothing then, so the caller
    /// withholds the write rather than make a change it cannot undo. First
    /// write wins as before, except over a record whose prior value holds
    /// `placeholderKey`: that scope was recorded without being read, and so
    /// was never written, and the value read now is its real prior.
    package func capturePriorBeforeWrite(
        surface: PlatformSurface,
        scope: String,
        value: [String: String]?,
        replacingPlaceholder placeholderKey: String,
        now: Date = .now
    ) throws {
        try locked {
            var records = loadLocked()
            let committed = records
            guard fileStateBox != .unreadable else {
                noteWriteFailedLocked(operation: .capturePrior, surface: surface, cause: .journalUnreadable)
                throw NetworkSettingsError.persistenceFailed
            }
            if let index = records.firstIndex(where: { $0.surface == surface && $0.scope == scope }) {
                guard records[index].priorValue?[placeholderKey] != nil else { return }
                records[index].priorValue = value
                records[index].recordedAt = now
            } else {
                records.append(PlatformStateRecord(surface: surface, scope: scope, priorValue: value, recordedAt: now))
            }
            guard saveLocked(records, operation: .capturePrior, surface: surface) else {
                loaded = committed
                throw NetworkSettingsError.persistenceFailed
            }
        }
    }

    /// Durable write-ahead evidence for identity-scoped network mutations.
    package func recordNetworkState(
        surface: PlatformSurface, locationID: String, serviceID: String,
        prior: [String: String], applied: [String: String], maximumRecords: Int
    ) throws {
        try locked {
            var records = loadLocked()
            let committed = records
            guard fileStateBox != .unreadable else {
                noteWriteFailedLocked(operation: .recordNetworkState, surface: surface, cause: .journalUnreadable)
                throw NetworkSettingsError.persistenceFailed
            }
            let scope = locationID + "/" + serviceID
            if let index = records.firstIndex(where: { $0.surface == surface && $0.scope == scope }) {
                records[index].appliedValue = applied
                records[index].recordedAt = .now
            } else {
                guard records.filter({ $0.locationID != nil }).count < maximumRecords else {
                    throw NetworkSettingsError.capacityExceeded
                }
                records.append(PlatformStateRecord(
                    surface: surface, scope: scope, priorValue: prior, recordedAt: .now,
                    locationID: locationID, serviceID: serviceID, appliedValue: applied
                ))
            }
            guard saveLocked(records, operation: .recordNetworkState, surface: surface) else {
                loaded = committed
                throw NetworkSettingsError.persistenceFailed
            }
        }
    }

    package func forgetNetworkState(surface: PlatformSurface, scope: String) throws {
        try locked {
            var records = loadLocked()
            let committed = records
            records.removeAll { $0.surface == surface && $0.scope == scope }
            guard saveLocked(records, operation: .forgetNetworkState, surface: surface) else {
                loaded = committed
                throw NetworkSettingsError.persistenceFailed
            }
        }
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
        locked {
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
            saveLocked(records, operation: ownership == nil ? .markApplied : .markReleased, surface: surface)
        }
    }

    package func ownership(of surface: PlatformSurface) -> SurfaceOwnership {
        locked {
            guard let marker = loadLocked().first(where: {
                $0.surface == surface && $0.scope == Self.appliedMarkerScope
            }) else {
                return .unknown
            }
            // A marker written before this key existed carries no payload and meant
            // exactly "applied", so that is what it keeps meaning.
            return marker.priorValue?[Self.ownershipKey] == Self.releasedOwnership ? .released : .applied
        }
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
        locked {
            var records = loadLocked()
            for index in records.indices where records[index].surface == surface {
                records[index].recordedAt = now
            }
            saveLocked(records, operation: .touch, surface: surface)
        }
    }

    // MARK: - Reading

    package func prior(surface: PlatformSurface, scope: String) -> RecordedPrior {
        locked {
            guard let record = loadLocked().first(where: { $0.surface == surface && $0.scope == scope }) else {
                return .notRecorded
            }
            guard let value = record.priorValue else { return .wasAbsent }
            return .wasPresent(value)
        }
    }

    package func scopes(for surface: PlatformSurface) -> [String] {
        records(for: surface).map(\.scope)
    }

    /// Real scopes only — the applied marker is bookkeeping, not a setting.
    package func records(for surface: PlatformSurface) -> [PlatformStateRecord] {
        locked {
            return loadLocked().filter { $0.surface == surface && $0.scope != Self.appliedMarkerScope }
        }
    }

    /// Real scopes only, matching `records(for:)`. The two disagreed before:
    /// this counted the ownership marker as a record, which was harmless while
    /// the marker's only states were "present" and "absent" — every caller
    /// pairs it with `isMarkedApplied`, so the marker was covered twice. It
    /// stops being harmless once the marker can say *released*, because then a
    /// surface with nothing outstanding would still report records.
    package func hasRecords(for surface: PlatformSurface) -> Bool {
        locked {
            return loadLocked().contains { $0.surface == surface && $0.scope != Self.appliedMarkerScope }
        }
    }

    package var isEmpty: Bool {
        locked {
            return loadLocked().isEmpty
        }
    }

    /// Oldest `recordedAt` across a surface, for callers that treat a
    /// long-abandoned record as evidence of a crash rather than a live session.
    package func oldestRecordDate(for surface: PlatformSurface) -> Date? {
        locked {
            return loadLocked().filter { $0.surface == surface }.map(\.recordedAt).min()
        }
    }

    // MARK: - Forgetting

    /// Drops a record once its prior value has been put back. Call *after* a
    /// successful restore: dropping it first turns a failed restore into a
    /// permanently stranded setting with no record that we caused it.
    package func forget(surface: PlatformSurface, scope: String) {
        locked {
            var records = loadLocked()
            records.removeAll { $0.surface == surface && $0.scope == scope }
            saveLocked(records, operation: .forget, surface: surface)
        }
    }

    package func forgetAll(surface: PlatformSurface) {
        locked {
            var records = loadLocked()
            records.removeAll { $0.surface == surface }
            saveLocked(records, operation: .forgetAll, surface: surface)
        }
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
        switch Self.readRecords(at: fileURL) {
        case .success(let records):
            fileStateBox = .loaded
            loaded = records
            return records
        case .failure(let failure):
            // Recovery may inspect recognized residue, but cannot attribute
            // prior settings. Keep the file intact for diagnosis and repair.
            fileStateBox = .unreadable
            loaded = []
            report(
                "platform.journal_unreadable",
                detail: "file=\(fileURL.lastPathComponent) \(failure.detail)",
                level: .warning,
                message: "Could not read the platform-state journal at \(fileURL.path) (\(failure.diagnostic)); recovery will inspect recognized residue; prior settings are unknown and the journal will be preserved."
            )
            return []
        }
    }

    /// Returns whether the records reached disk. Legacy callers retain an
    /// in-memory copy after failure; durable network operations roll it back.
    @discardableResult
    private func saveLocked(_ records: [PlatformStateRecord], operation: WriteOperation, surface: PlatformSurface) -> Bool {
        // Legacy resolver adoption needs its in-memory evidence for retry even
        // when persistence is unavailable. Never replace the corrupt disk file.
        loaded = records
        guard fileStateBox != .unreadable else {
            noteWriteFailedLocked(operation: operation, surface: surface, cause: .journalUnreadable)
            return false
        }
        do {
            let data = try CanonicalJSON.encoder().encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a half-written journal read back after a crash would
            // claim prior values that were never true.
            try data.write(to: fileURL, options: .atomic)
            fileStateBox = .loaded
            noteWriteLandedLocked()
            return true
        } catch {
            noteWriteFailedLocked(operation: operation, surface: surface, cause: .io(error))
            return false
        }
    }

    // MARK: - Reporting (#191)

    /// The writes that can fail, named in `platform.journal_write_failed`.
    private enum WriteOperation: String {
        case recordPrior = "record_prior"
        case capturePrior = "capture_prior"
        case recordNetworkState = "record_network_state"
        case forgetNetworkState = "forget_network_state"
        case markApplied = "mark_applied"
        case markReleased = "mark_released"
        case touch
        case forget
        case forgetAll = "forget_all"
        case importLegacyDNS = "import_legacy_dns"
    }

    private enum WriteFailure {
        /// Refused: the file on disk could not be read, so it is kept.
        case journalUnreadable
        case io(Error)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    /// Event first, then the log line derived from it. Called with the lock
    /// held, so events reach the sink in the order the journal decided
    /// them: a failed-write episode is never reported after the write that
    /// ended it. The sink must not call back into the journal.
    private func report(
        _ name: String, detail: String, level: LogLevel, message: String, logger: (any LogSink)? = nil
    ) {
        let event = RuntimeEvent(kind: .config, event: name, detail: detail)
        eventSink?(event)
        (logger ?? self.logger)?.log(level, "\(message) \(event.event) \(event.detail ?? "")", category: .system)
    }

    /// A failing disk is one event, not one per write: the episode is
    /// reported when it starts and again when a write lands.
    private func noteWriteFailedLocked(operation: WriteOperation, surface: PlatformSurface, cause: WriteFailure) {
        failedWrites += 1
        guard failedWrites == 1 else { return }
        let base = "operation=\(operation.rawValue) surface=\(surface.rawValue)"
        switch cause {
        case .journalUnreadable:
            report(
                "platform.journal_write_failed",
                detail: base + " reason=journal_unreadable",
                level: .error,
                message: "Refusing to overwrite an unreadable platform-state journal; it is kept for diagnosis, and new state is held in memory only until it is repaired."
            )
        case .io(let error):
            // The in-memory copy still serves this process, so a failed write
            // is survivable *now* — but it means a crash from here on leaves
            // the user's original settings unrecoverable, which nobody would
            // otherwise learn.
            report(
                "platform.journal_write_failed",
                detail: base + " reason=io error=\(Self.errorToken(error))",
                level: .error,
                message: "Could not write the platform-state journal at \(fileURL.path) (\(error.displayDescription)); if this process dies, the previous system settings cannot be restored."
            )
        }
    }

    private func noteWriteLandedLocked() {
        guard failedWrites > 0 else { return }
        let failures = failedWrites
        failedWrites = 0
        report(
            "platform.journal_write_recovered",
            detail: "failures=\(failures)",
            level: .notice,
            message: "The platform-state journal is being written again after \(failures) failed write(s)."
        )
    }

    // MARK: - Decoding

    /// Why a journal file could not be trusted.
    private enum ReadFailure: Error {
        case readFailed(Error)
        /// Neither date encoding decodes the records.
        case undecodable(canonical: Error, iso8601: Error)

        /// `key=value` tokens for the event: short, with no spaces.
        var detail: String {
            switch self {
            case .readFailed(let error):
                "reason=read_failed error=\(PlatformStateJournal.errorToken(error))"
            case .undecodable(let canonical, let iso8601):
                "reason=undecodable canonical=\(PlatformStateJournal.errorToken(canonical)) iso8601=\(PlatformStateJournal.errorToken(iso8601))"
            }
        }

        /// Every error in full, for the log line.
        var diagnostic: String {
            switch self {
            case .readFailed(let error):
                error.displayDescription
            case .undecodable(let canonical, let iso8601):
                "as records with epoch dates: \(canonical.displayDescription); as records with ISO-8601 dates: \(iso8601.displayDescription)"
            }
        }
    }

    /// Current dates first, then the historical ISO-8601 ones, upgraded on
    /// the next write. Both errors are kept: the second alone hid that the
    /// file was most likely a damaged current-format journal.
    private static func readRecords(at url: URL) -> Result<[PlatformStateRecord], ReadFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.readFailed(error))
        }
        let canonicalError: Error
        do {
            return .success(try CanonicalJSON.decoder().decode([PlatformStateRecord].self, from: data))
        } catch {
            canonicalError = error
        }
        do {
            return .success(try JSONDecoder.iso8601Decoder.decode([PlatformStateRecord].self, from: data))
        } catch {
            return .failure(.undecodable(canonical: canonicalError, iso8601: error))
        }
    }

    /// A short, space-free name for an error, for an event's `key=value`
    /// detail. The log line derived from the event carries the full text.
    static func errorToken(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            let error = error as NSError
            return "\(error.domain):\(error.code)"
        }
        let kind: String
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let found):
            (kind, context) = ("type_mismatch", found)
        case .valueNotFound(_, let found):
            (kind, context) = ("value_not_found", found)
        case .keyNotFound(let key, let found):
            (kind, context) = ("key_not_found:" + key.stringValue, found)
        case .dataCorrupted(let found):
            (kind, context) = ("data_corrupted", found)
        @unknown default:
            return "decoding_error"
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        let token = path.isEmpty ? kind : kind + "@" + path
        return String(token.map { $0.isWhitespace ? "_" : $0 })
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
    ///
    /// Every step that does not complete is reported once, as
    /// `platform.legacy_dns_import_failed`; a completed import is
    /// `platform.legacy_dns_imported` (#191).
    @discardableResult
    package func importLegacyDNSSnapshot(at snapshotURL: URL, logger: (any LogSink)? = nil) -> Bool {
        // No snapshot is the common case: nothing to import, nothing to say.
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return false }
        return locked { importLegacyDNSSnapshotLocked(at: snapshotURL, logger: logger) }
    }

    /// A step of the import that did not complete, named in
    /// `platform.legacy_dns_import_failed`.
    enum LegacyImportStep: String {
        case readSnapshot = "read_snapshot"
        case decodeSnapshot = "decode_snapshot"
        case journalUnreadable = "journal_unreadable"
        case journalWrite = "journal_write"
        case removeSnapshot = "remove_snapshot"
    }

    private func importLegacyDNSSnapshotLocked(at snapshotURL: URL, logger: (any LogSink)?) -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            reportImportFailed(.readSnapshot, error: error, logger: logger,
                               message: "Legacy DNS snapshot at \(snapshotURL.path) could not be read (\(error.displayDescription)); leaving it in place.")
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let snapshot: LegacyDNSSnapshot
        do {
            snapshot = try decoder.decode(LegacyDNSSnapshot.self, from: data)
        } catch {
            reportImportFailed(.decodeSnapshot, error: error, logger: logger,
                               message: "Legacy DNS snapshot at \(snapshotURL.path) could not be decoded (\(error.displayDescription)); leaving it in place.")
            return false
        }

        var records = loadLocked()
        guard fileStateBox != .unreadable else {
            reportImportFailed(.journalUnreadable, error: nil, logger: logger,
                               message: "Legacy DNS snapshot found but the platform-state journal is unreadable; leaving both in place.")
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
        guard saveLocked(records, operation: .importLegacyDNS, surface: .systemDNS) else {
            reportImportFailed(.journalWrite, error: nil, logger: logger,
                               message: "Legacy DNS snapshot could not be written into the journal; keeping \(snapshotURL.path) as the recovery copy.")
            return false
        }
        report("platform.legacy_dns_imported", detail: "interfaces=\(snapshot.interfaces.count)", level: .notice,
               message: "Imported the 0.1.x DNS snapshot (\(snapshot.interfaces.count) interface(s)) into the platform-state journal.",
               logger: logger)
        do {
            try FileManager.default.removeItem(at: snapshotURL)
        } catch {
            // The journal now knows the surface, so the snapshot is never
            // imported again; it is only left behind, but say so.
            reportImportFailed(.removeSnapshot, error: error, logger: logger,
                               message: "Imported the legacy DNS snapshot but could not remove \(snapshotURL.path) (\(error.displayDescription)).")
        }
        return true
    }

    /// Once per step for the journal's lifetime: a snapshot that stays
    /// unreadable is one event, not one per recovery pass.
    private func reportImportFailed(_ step: LegacyImportStep, error: Error?, logger: (any LogSink)?, message: String) {
        guard reportedImportSteps.insert(step).inserted else { return }
        let detail = "step=\(step.rawValue)" + (error.map { " error=\(Self.errorToken($0))" } ?? "")
        report("platform.legacy_dns_import_failed", detail: detail, level: .warning, message: message, logger: logger)
    }
}
