// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import ConduitShared
import PlatformMac
import ProxyKernel

/// #182 and #191 over `FakeMachine` and a scratch state directory: a
/// platform-state journal written by a newer Conduit fails closed, so an
/// apply is refused before it writes anything, and the file is kept byte
/// for byte with an event that says why; a journal directory that cannot be
/// written is one failure event for the episode and one recovery event when
/// a write lands; and the bare-array files every release so far wrote, in
/// either date encoding, still read as version 1, as does the envelope.
enum JournalIntegrityScenarios {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pm-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("journal-integrity cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
        func names() -> [String] { events.withLockedValue { $0.map(\.event) } }
        func details(_ name: String) -> [String] {
            events.withLockedValue { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
        }

        // Phase 1: a newer Conduit's journal. The apply is refused before it
        // writes anything, the journal says why, the writes that follow are
        // refused as one episode, and the file is untouched.
        let newerDirectory = root.appendingPathComponent("newer", isDirectory: true)
        try FileManager.default.createDirectory(at: newerDirectory, withIntermediateDirectories: false)
        let newerFile = newerDirectory.appendingPathComponent("platform-state.json")
        let newer = Data(#"{"version":2,"records":[{"surface":"systemProxy","scope":"Wi-Fi"}]}"#.utf8)
        try newer.write(to: newerFile)
        let machine = FakeMachine(resolverDirectory: root.appendingPathComponent("resolver"))
        let newerJournal = PlatformStateJournal(fileURL: newerFile, eventSink: sink)
        let manager = EnvironmentManager(journal: newerJournal, homeDirectory: newerDirectory,
                                         commandRunner: machine.run, eventSink: sink)
        var config = GenericDefaults.shared.makeConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        var refusal = "none"
        do {
            _ = try manager.apply(config: config, logger: nil)
        } catch NetworkSettingsError.unreadableJournal {
            refusal = "unreadable_journal"
        } catch {
            refusal = "\(error)"
        }
        let failedClosed = newerJournal.fileState == .unreadable && refusal == "unreadable_journal"
            && details("platform.journal_unreadable") == ["file=platform-state.json reason=unsupported_version version=2 supported=1"]
            && machine.launchdEnvironment["HTTP_PROXY"] == nil
            && !FileManager.default.fileExists(atPath: newerDirectory.appendingPathComponent(".zshrc").path)
        newerJournal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: nil)
        newerJournal.markApplied(surface: .systemDNS)
        newerJournal.forgetAll(surface: .systemProxy)
        let kept = (try Data(contentsOf: newerFile)) == newer
        let refusedOnce = details("platform.journal_write_failed")
            == ["operation=record_prior surface=systemDNS reason=journal_unreadable"]
        let order = names()

        // Phase 2: a journal directory that cannot be written. Three failed
        // writes are one event; the write that lands reports the episode over.
        events.withLockedValue { $0.removeAll() }
        let locked = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            catch { fputs("journal-integrity permission reset failed: \(error.localizedDescription)\n", stderr) }
        }
        let lockedJournal = PlatformStateJournal(fileURL: locked.appendingPathComponent("platform-state.json"), eventSink: sink)
        lockedJournal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: ["servers": ""])
        lockedJournal.markApplied(surface: .systemDNS)
        lockedJournal.touch(surface: .systemDNS)
        let oneFailure = details("platform.journal_write_failed").count == 1
            && details("platform.journal_write_failed").first?.hasPrefix("operation=record_prior surface=systemDNS reason=io") == true
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        lockedJournal.touch(surface: .systemDNS)
        let recovered = details("platform.journal_write_recovered") == ["failures=3"]
            && PlatformStateJournal(fileURL: locked.appendingPathComponent("platform-state.json"))
                .prior(surface: .systemDNS, scope: "Wi-Fi") == .wasPresent(["servers": ""])

        // Phase 3: version 1 in every shape a release wrote or will write.
        events.withLockedValue { $0.removeAll() }
        let epoch = #"[{"surface":"systemProxy","scope":"Wi-Fi","recordedAt":1780000000}]"#
        let shapes: [(String, String)] = [
            ("epoch", epoch),
            ("iso8601", #"[{"surface":"systemProxy","scope":"Wi-Fi","recordedAt":"2026-05-28T20:26:40Z"}]"#),
            ("envelope", #"{"version":1,"records":\#(epoch)}"#),
        ]
        var unread: [String] = []
        for (name, data) in shapes {
            let file = root.appendingPathComponent("v1-\(name).json")
            try Data(data.utf8).write(to: file)
            let journal = PlatformStateJournal(fileURL: file, eventSink: sink)
            if journal.fileState != .loaded || journal.prior(surface: .systemProxy, scope: "Wi-Fi") != .wasAbsent {
                unread.append(name)
            }
        }
        let versionOne = unread.isEmpty && names().isEmpty

        return ScenarioResult(
            name: "journal-integrity", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a newer journal fails closed with journal_unreadable, and the apply writes nothing", failedClosed),
                .init("the newer journal is kept byte for byte", kept),
                .init("three refused writes are one journal_write_failed", refusedOnce),
                .init("an unwritable journal directory is one failure event for three writes", oneFailure),
                .init("a landed write reports the episode over, and the held records reach disk", recovered),
                .init("bare arrays in both date encodings and the v1 envelope read as version 1, silently", versionOne),
            ],
            notes: ["refusal=\(refusal)", "unread=\(unread.joined(separator: ","))", "events=\(order.joined(separator: ","))"]
        )
    }
}
