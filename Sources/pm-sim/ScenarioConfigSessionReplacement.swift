// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// `config-session-replacement` (decisions 0015, 0021, 0027 and 0031): the configuration replacement capability that the store consumes,
/// taken through the production bootstrap over the real OS adapters in a scratch root. Each component maps to its own resolved file. A stale
/// baseline is a conflict that keeps the external bytes. A replacement with the current baseline persists its own file and no other, and the
/// journal keeps its bytes. A second bootstrap of the root is busy while the capability is held, and the root is taken again once the session
/// is dropped. Nothing outside the scratch root is touched, and no socket is opened. This is a physical capability test, not a runtime workflow.
enum ConfigSessionReplacementScenario {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-config-session-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let verdict = SessionReplacementVerdict()
        let holder = SessionHolder()
        do {
            try exercise(scratch: scratch, holder: holder, verdict: verdict)
        } catch {
            verdict.check("the scenario ran to completion", false)
            verdict.note("the scenario stopped: \(error.localizedDescription)")
        }
        cleanUp(scratch: scratch, holder: holder, verdict: verdict)
        return ScenarioResult(
            name: "config-session-replacement", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: verdict.assertions.isEmpty ? [.init("scenario produced assertions", false)] : verdict.assertions,
            notes: verdict.notes
        )
    }

    private static func exercise(scratch: URL, holder: SessionHolder, verdict: SessionReplacementVerdict) throws {
        let state = scratch.appendingPathComponent("state", isDirectory: true)
        let environment = RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("config.json"))
        if let refusal = takeSession(environment, into: holder) {
            verdict.check("the production bootstrap takes the scratch root", false)
            verdict.note("the bootstrap refused the scratch root: \(refusal)")
            return
        }
        try exerciseReplacements(holder: holder, verdict: verdict)
        verdict.check("the root is busy while the capability is held", isBusy(environment, holder: holder))
        // Dropping the last reference closes the lease, so the same root can be taken again.
        holder.replace(nil)
        verdict.check("dropping the session closes its lease, and the root is taken again", takeSession(environment, into: holder) == nil)
        holder.replace(nil)
    }

    /// Seeds the four files, then runs the replacements through the session. It holds the session only through `holder`, so the caller can
    /// drop it afterwards.
    private static func exerciseReplacements(holder: SessionHolder, verdict: SessionReplacementVerdict) throws {
        guard let session = holder.session else {
            verdict.check("the session is held for the replacements", false)
            return
        }
        let access = StateFileAccess.operatingSystem()
        verdict.check("runtime maps to the runtime file", session.configurationFile(for: .runtime).role == .config)
        verdict.check("platform maps to the platform file", session.configurationFile(for: .platform).role == .platformConfig)
        verdict.check("preferences maps to the preferences file", session.configurationFile(for: .preferences).role == .preferences)

        let journal = Data("journal-bytes".utf8)
        try write(journal, to: session.plan.journal.path)
        var current: [ConfigurationComponent: Data] = [
            .runtime: Data("runtime-prior".utf8),
            .platform: Data("platform-prior".utf8),
            .preferences: Data("preferences-prior".utf8),
        ]
        for (component, bytes) in current {
            try write(bytes, to: session.configurationFile(for: component).path)
        }

        // A stale baseline: the runtime file changed after its baseline was observed. The conflict keeps the external bytes.
        let external = Data("runtime-external".utf8)
        try write(external, to: session.configurationFile(for: .runtime).path)
        let stale = session.replaceConfigurationFile(
            .runtime, staged: Data("runtime-staged".utf8), expecting: baseline(current[.runtime]), access: access
        )
        let afterStale = try read(session.configurationFile(for: .runtime).path)
        verdict.check("a stale baseline is a conflict and keeps the external bytes", stale == .conflict && afterStale == external)
        current[.runtime] = external

        // Each component persists its own file under its current baseline, and nothing else changes.
        for component in ConfigurationComponent.allCases {
            let staged = Data("\(component)-staged".utf8)
            let outcome = session.replaceConfigurationFile(
                component, staged: staged, expecting: baseline(current[component]), access: access
            )
            verdict.check("\(component) persists its own file under the current baseline", outcome == .verifiedPersisted(writeError: nil))
            current[component] = staged
        }
        for component in ConfigurationComponent.allCases {
            let onDisk = try read(session.configurationFile(for: component).path)
            verdict.check("\(component) holds exactly the bytes it persisted", onDisk == current[component])
        }
        let journalOnDisk = try read(session.plan.journal.path)
        verdict.check("the journal keeps its bytes through every replacement", journalOnDisk == journal)
    }

    /// Takes the root into `holder`. The result is the refusal, or nil when the root was taken. No local keeps the session.
    private static func takeSession(_ environment: RuntimeEnvironment, into holder: SessionHolder) -> StateRootAcquisitionFailure? {
        switch StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in holder.noteReleaseFailure(errno: failure.errno) }
        ) {
        case .success(let session):
            holder.replace(session)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Whether a second bootstrap of the root is refused as busy. An unexpected session is released when the probe returns, and the
    /// probe reports its close through the holder.
    private static func isBusy(_ environment: RuntimeEnvironment, holder: SessionHolder) -> Bool {
        switch StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in holder.noteReleaseFailure(errno: failure.errno) }
        ) {
        case .failure(.busy):
            return true
        case .success, .failure:
            return false
        }
    }

    /// Releases the held session first. The scratch root is removed only when every close was confirmed, since an unconfirmed close may still
    /// hold the lock, and a failed removal fails the verdict.
    private static func cleanUp(scratch: URL, holder: SessionHolder, verdict: SessionReplacementVerdict) {
        holder.replace(nil)
        guard holder.releaseFailureCount == 0 else {
            verdict.check("the writer lease is released with a confirmed close", false)
            let first = holder.firstReleaseFailureErrno.map { "errno \($0)" } ?? "no errno"
            verdict.note("a writer lease close was not confirmed (\(holder.releaseFailureCount) failed, first \(first)); the scratch root was kept")
            return
        }
        do {
            try FileManager.default.removeItem(at: scratch)
            verdict.check("the scratch directory is removed", true)
        } catch {
            verdict.check("the scratch directory is removed", false)
            verdict.note("scratch cleanup failed: \(error.localizedDescription)")
        }
    }

    private static func baseline(_ bytes: Data?) -> ConfigurationFileBaseline {
        ConfigurationFileBaseline(observing: bytes.map { ConfigurationFileInput.present($0) } ?? .missing)
    }

    private static func write(_ bytes: Data, to path: String) throws {
        try bytes.write(to: URL(fileURLWithPath: path))
    }

    private static func read(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}

/// The assertions and notes of one run. Both lists have a fixed capacity: a run past it is a scenario bug, so recording traps.
private final class SessionReplacementVerdict {
    static let assertionCapacity = 32
    static let noteCapacity = 8

    private(set) var assertions: [ScenarioAssertion] = []
    private(set) var notes: [String] = []

    func check(_ name: String, _ passed: Bool) {
        precondition(assertions.count < Self.assertionCapacity, "a scenario records a bounded number of assertions")
        assertions.append(.init(name, passed))
    }

    func note(_ text: String) {
        precondition(notes.count < Self.noteCapacity, "a scenario records a bounded number of notes")
        notes.append(text)
    }
}

/// The one session the run may hold, kept where cleanup can reach it whichever step failed. It counts each lease close that was not confirmed.
/// The previous session is released after the lock is left, so a close that fails reports through `noteReleaseFailure` without deadlock.
private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: StateRootSession?
    private var failures = 0
    /// The errno of the first unconfirmed close. Later failures are counted, not kept, so the diagnostic stays one value.
    private var firstFailureErrno: Int32?

    var session: StateRootSession? {
        lock.withLock { held }
    }

    var releaseFailureCount: Int {
        lock.withLock { failures }
    }

    var firstReleaseFailureErrno: Int32? {
        lock.withLock { firstFailureErrno }
    }

    func replace(_ value: StateRootSession?) {
        _ = lock.withLock { () -> StateRootSession? in
            let previous = held
            held = value
            return previous
        }
    }

    func noteReleaseFailure(errno: Int32) {
        lock.withLock {
            failures += 1
            if firstFailureErrno == nil { firstFailureErrno = errno }
        }
    }
}
