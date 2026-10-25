// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// `protected-app-log`: the app's file log writer, judged by the guard for its own `log` file, keeps every protected
/// file's bytes. The four collisions the parent executed against the original writer are refused before any write,
/// rename or unlink. A directory in the active or an archive slot is refused by kind and kept. Normal rotation and
/// oversized lines keep their archive behaviour, and a latched refusal makes no further guard calls.
/// Every case is a scratch directory under the temporary directory. No app, runtime or helper is touched.
///
/// The behavioural checks run first. The owned scratch root is then removed explicitly, and that outcome is one more
/// assertion, so a removal that fails changes the verdict instead of disappearing into a `defer`.
enum ProtectedLogScenarios {
    private static let witness = Data(#"{"intent":"preserve"}"#.utf8)

    static func run() async throws -> ScenarioResult {
        let began = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-app-log-\(UUID().uuidString)", isDirectory: true)
        let body: Result<[ScenarioAssertion], Error>
        do {
            body = .success(try checks(in: root))
        } catch {
            body = .failure(error)
        }
        let cleanup = removeOwnedRoot(root)

        switch (body, cleanup) {
        case (.success(var assertions), .success):
            assertions.append(.init("scratch root removed", true))
            return result(began: began, assertions: assertions, notes: [])
        case (.success(var assertions), .failure(let failure)):
            assertions.append(.init("scratch root removed", false))
            return result(began: began, assertions: assertions, notes: ["scratch root removal failed (code \(failure.code))"])
        case (.failure(let error), .success):
            throw error
        case (.failure(let error), .failure(let failure)):
            throw ScenarioSetupAndCleanupFailure(setup: String(describing: error), cleanupCode: failure.code)
        }
    }

    /// The behavioural checks, each against its own scratch directory under `root`.
    private static func checks(in root: URL) throws -> [ScenarioAssertion] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var assertions: [ScenarioAssertion] = []

        // The four collisions. Each is refused, the config keeps its bytes, and one refusal names the log sink.
        for name in ["active-symlink", "active-hardlink", "archive1-target", "archive2-target"] {
            let (config, log) = try collision(name, in: root)
            let events = RuntimeEventLog(capacity: 16)
            let file = writer(log, maxBytes: name.hasPrefix("archive") ? 4 : 1024, archives: 2,
                              guardian: guardProtecting(config), events: events)
            file.write(Data("new-log\n".utf8))
            file.flush()
            file.close()
            let refusals = details(events, event: RecordFileDestinationGate.eventName)
            assertions.append(.init("\(name): configuration bytes preserved",
                                    try Data(contentsOf: config) == witness))
            assertions.append(.init("\(name): one refusal from the log sink",
                                    refusals.count == 1 && refusals[0].hasPrefix("sink=log ")))
            if name.hasPrefix("archive") {
                assertions.append(.init("\(name): active file not rotated away",
                                        try String(contentsOf: log, encoding: .utf8) == "old-log\n"))
            }
        }

        // Directories are refused by kind before any open, rename or unlink, and their contents stay.
        let directories = root.appendingPathComponent("directories", isDirectory: true)
        let activeDirectory = directories.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: activeDirectory.appendingPathComponent("inside"))
        let activeEvents = RuntimeEventLog(capacity: 16)
        let activeWriter = writer(activeDirectory, maxBytes: 1024, archives: 2,
                                  guardian: guardProtecting(directories.appendingPathComponent("config.json")),
                                  events: activeEvents)
        activeWriter.write(Data("new-log\n".utf8))
        activeWriter.flush()
        activeWriter.close()
        let activeInside = try String(contentsOf: activeDirectory.appendingPathComponent("inside"), encoding: .utf8)
        assertions.append(.init("active directory: refused by kind, contents kept",
                                details(activeEvents, event: "observability.log_file_failed") == ["stage=unsupported_kind code=0"]
                                    && activeInside == "keep\n"))

        let archiveDirectory = directories.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archiveLog = archiveDirectory.appendingPathComponent("proxy.log")
        try Data("old-log\n".utf8).write(to: archiveLog)
        let archiveSlot = archiveDirectory.appendingPathComponent("proxy.log.1", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveSlot, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: archiveSlot.appendingPathComponent("inside"))
        let slotEvents = RuntimeEventLog(capacity: 16)
        let slotWriter = writer(archiveLog, maxBytes: 4, archives: 1,
                                guardian: guardProtecting(directories.appendingPathComponent("config.json")),
                                events: slotEvents)
        slotWriter.write(Data("new-log\n".utf8))
        slotWriter.flush()
        slotWriter.close()
        let slotLog = try String(contentsOf: archiveLog, encoding: .utf8)
        let slotInside = try String(contentsOf: archiveSlot.appendingPathComponent("inside"), encoding: .utf8)
        assertions.append(.init("archive directory: refused by kind, log and contents kept",
                                details(slotEvents, event: "observability.log_file_failed") == ["stage=unsupported_kind code=0"]
                                    && slotLog == "old-log\n"
                                    && slotInside == "keep\n"))

        // Normal rotation keeps its archive behaviour, and an oversized line is written whole.
        let normal = root.appendingPathComponent("normal", isDirectory: true)
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
        let normalLog = normal.appendingPathComponent("proxy.log")
        let normalWriter = writer(normalLog, maxBytes: 12, archives: 2,
                                  guardian: guardProtecting(normal.appendingPathComponent("config.json")),
                                  events: RuntimeEventLog(capacity: 16))
        for index in 1...5 { normalWriter.write(Data("line\(index)\n".utf8)) }
        normalWriter.flush()
        normalWriter.close()
        let live = try String(contentsOf: normalLog, encoding: .utf8)
        let archiveOne = try String(contentsOf: normal.appendingPathComponent("proxy.log.1"), encoding: .utf8)
        let archiveTwo = try String(contentsOf: normal.appendingPathComponent("proxy.log.2"), encoding: .utf8)
        assertions.append(.init("normal rotation: live, .1 and .2 hold the expected lines",
                                live == "line5\n" && archiveOne == "line3\nline4\n" && archiveTwo == "line1\nline2\n"))

        let oversized = root.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        let oversizedLog = oversized.appendingPathComponent("proxy.log")
        let oversizedWriter = writer(oversizedLog, maxBytes: 4, archives: 1,
                                     guardian: guardProtecting(oversized.appendingPathComponent("config.json")),
                                     events: RuntimeEventLog(capacity: 16))
        oversizedWriter.write(Data("short\n".utf8))
        oversizedWriter.write(Data("much longer line\n".utf8))
        oversizedWriter.flush()
        oversizedWriter.close()
        assertions.append(.init("oversized line: written whole into a fresh file",
                                try String(contentsOf: oversizedLog, encoding: .utf8) == "much longer line\n"))

        // A latched refusal makes no further guard calls and opens nothing.
        let latchedConfig = root.appendingPathComponent("latched-config.json")
        try witness.write(to: latchedConfig)
        let latchedLog = root.appendingPathComponent("latched-proxy.log")
        try FileManager.default.createSymbolicLink(at: latchedLog, withDestinationURL: latchedConfig)
        let counting = CountingGuard(guardProtecting(latchedConfig))
        let latchedEvents = RuntimeEventLog(capacity: 16)
        let latchedWriter = writer(latchedLog, maxBytes: 1024, archives: 2, guardian: counting, events: latchedEvents)
        latchedWriter.write(Data("first\n".utf8))
        latchedWriter.flush()
        let afterRefusal = counting.count
        for index in 0..<3 { latchedWriter.write(Data("later \(index)\n".utf8)) }
        latchedWriter.flush()
        latchedWriter.close()
        assertions.append(.init("latched refusal: no further guard calls, one refusal event",
                                afterRefusal > 0 && counting.count == afterRefusal
                                    && details(latchedEvents, event: RecordFileDestinationGate.eventName).count == 1))

        return assertions
    }

    /// Removes the owned scratch root recursively. This is the scenario's own UUID directory, never a product path.
    /// A root that was never created is already gone, so it passes.
    private static func removeOwnedRoot(_ root: URL) -> Result<Void, CleanupCode> {
        guard FileManager.default.fileExists(atPath: root.path) else { return .success(()) }
        do {
            try FileManager.default.removeItem(at: root)
            return .success(())
        } catch {
            return .failure(CleanupCode(code: (error as NSError).code))
        }
    }

    private static func result(began: Date, assertions: [ScenarioAssertion], notes: [String]) -> ScenarioResult {
        ScenarioResult(
            name: "protected-app-log", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: witness.count, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions,
            notes: ["Scratch directory under the temporary directory only; no app, runtime, helper or system setting is touched."] + notes
        )
    }

    /// The four probe layouts, byte for byte: an active symlink, an active hardlink, and config symlinks to archive 1 and archive 2.
    private static func collision(_ name: String, in root: URL) throws -> (config: URL, log: URL) {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json")
        let log = dir.appendingPathComponent("proxy.log")
        switch name {
        case "active-symlink":
            try witness.write(to: config)
            try FileManager.default.createSymbolicLink(at: log, withDestinationURL: config)
        case "active-hardlink":
            try witness.write(to: config)
            guard link(config.path, log.path) == 0 else { throw ScenarioSetupFailure(step: name) }
        default:
            try Data("old-log\n".utf8).write(to: log)
            let target = dir.appendingPathComponent(name == "archive1-target" ? "proxy.log.1" : "proxy.log.2")
            try witness.write(to: target)
            if name == "archive2-target" {
                try Data("old-archive\n".utf8).write(to: dir.appendingPathComponent("proxy.log.1"))
            }
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        }
        return (config, log)
    }

    private static func guardProtecting(_ config: URL) -> any RecordFileDestinationGuarding {
        systemRecordFileDestinationGuard(protected: [ProtectedRecordFile(resource: .config, url: config)])
    }

    private static func writer(
        _ log: URL, maxBytes: Int, archives: Int, guardian: any RecordFileDestinationGuarding, events: RuntimeEventLog
    ) -> any RotatingByteWriter {
        rotatingLogFile(
            url: log, maxBytes: maxBytes, archives: archives, destinationGuard: guardian,
            gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: DiscardingLogSink()),
            eventLog: events, logger: DiscardingLogSink()
        )
    }

    private static func details(_ events: RuntimeEventLog, event: String) -> [String] {
        events.events.filter { $0.event == event }.map { $0.detail ?? "" }
    }
}

/// A setup step that could not be built, so the scenario reports which one.
struct ScenarioSetupFailure: Error {
    let step: String
}

/// The owned scratch root could not be removed. Only the platform's code leaves the scenario, never the path.
struct CleanupCode: Error {
    let code: Int
}

/// The body and the scratch cleanup both failed. Both facts stay in the error, so neither hides the other.
struct ScenarioSetupAndCleanupFailure: Error, CustomStringConvertible {
    let setup: String
    let cleanupCode: Int

    var description: String {
        "setup failed (\(setup)) and scratch root removal failed (code \(cleanupCode))"
    }
}

/// Counts the guard's admit calls, so a latched refusal can show that it asks no more questions.
private final class CountingGuard: RecordFileDestinationGuarding, @unchecked Sendable {
    private let inner: any RecordFileDestinationGuarding
    private let lock = NSLock()
    private var calls = 0

    init(_ inner: any RecordFileDestinationGuarding) {
        self.inner = inner
    }

    var count: Int { lock.withLock { calls } }

    func admit(destination: URL) throws {
        lock.withLock { calls += 1 }
        try inner.admit(destination: destination)
    }

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        lock.withLock { calls += 1 }
        try inner.admit(openedDescriptor: descriptor, destination: destination)
    }
}
