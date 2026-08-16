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
    /// `secureEnabled`, `secureHost`, `securePort`, `autoEnabled`, `autoURL`.
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
    private let fileURL: URL
    private let lock = NSLock()
    private var loaded: [PlatformStateRecord]?

    package init(fileURL: URL) {
        self.fileURL = fileURL
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
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.surface == surface }.map(\.scope)
    }

    package func records(for surface: PlatformSurface) -> [PlatformStateRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.surface == surface }
    }

    package func hasRecords(for surface: PlatformSurface) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().contains { $0.surface == surface }
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

    package func forgetEverything() {
        lock.lock()
        defer { lock.unlock() }
        saveLocked([])
    }

    // MARK: - Persistence

    private func loadLocked() -> [PlatformStateRecord] {
        if let loaded { return loaded }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso8601Decoder.decode([PlatformStateRecord].self, from: data)
        else {
            // An unreadable or corrupt journal is indistinguishable from no
            // journal, and both mean the same thing to every caller: we cannot
            // say what was here, so fall back to an unconditional teardown.
            loaded = []
            return []
        }
        loaded = decoded
        return decoded
    }

    private func saveLocked(_ records: [PlatformStateRecord]) {
        loaded = records
        guard let data = try? JSONEncoder.prettyISO8601Encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic: a half-written journal read back after a crash would claim
        // prior values that were never true.
        try? data.write(to: fileURL, options: .atomic)
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
