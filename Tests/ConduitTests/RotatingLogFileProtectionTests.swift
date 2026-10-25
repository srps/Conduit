// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import Conduit

/// The app log writer against the protected config, through the four collisions the parent executed against the
/// original writer (`actual-log-collision-probe`), plus the file-safety rules: special files, directories, symbolic
/// links, the latch, close failure and event-first publication. Every case is a scratch directory under the temp root.
final class RotatingLogFileProtectionTests: XCTestCase {
    private static let witness = Data(#"{"intent":"preserve"}"#.utf8)
    /// The fixed-code fact a close that cannot be confirmed leaves. Its detail is `stage=close code=<errno>`, no path.
    private static let cleanupEvent = "observability.log_file_cleanup_unconfirmed"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RotatingLogFileProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { removeScratch([dir]) }
        return dir
    }

    /// The four probe layouts, byte for byte: an active symlink, an active hardlink, and config symlinks to archive 1 and archive 2.
    private func collision(_ name: String) throws -> (config: URL, log: URL) {
        let dir = try tempDir().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json")
        let log = dir.appendingPathComponent("proxy.log")
        switch name {
        case "active-symlink":
            try Self.witness.write(to: config)
            try FileManager.default.createSymbolicLink(at: log, withDestinationURL: config)
        case "active-hardlink":
            try Self.witness.write(to: config)
            XCTAssertEqual(link(config.path, log.path), 0)
        default:
            try Data("old-log\n".utf8).write(to: log)
            let target = dir.appendingPathComponent(name == "archive1-target" ? "proxy.log.1" : "proxy.log.2")
            try Self.witness.write(to: target)
            if name == "archive2-target" {
                try Data("old-archive\n".utf8).write(to: dir.appendingPathComponent("proxy.log.1"))
            }
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        }
        return (config, log)
    }

    private func guardProtectingConfig(_ config: URL) -> any RecordFileDestinationGuarding {
        systemRecordFileDestinationGuard(protected: [ProtectedRecordFile(resource: .config, url: config)])
    }

    private func writer(
        _ log: URL, maxBytes: Int, archives: Int, guardian: any RecordFileDestinationGuarding, events: RuntimeEventLog,
        logger: any LogSink = DiscardingLogSink()
    ) -> any RotatingByteWriter {
        rotatingLogFile(
            url: log, maxBytes: maxBytes, archives: archives, destinationGuard: guardian,
            gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: logger),
            eventLog: events, logger: logger
        )
    }

    /// The writer with its effects replaced, so a test can name each descriptor the writer opens and closes.
    private func effectsWriter(
        _ log: URL, guardian: any RecordFileDestinationGuarding = UncheckedRecordFileDestination(),
        events: RuntimeEventLog, logger: any LogSink = DiscardingLogSink(), effects: RotatingLogFileEffects
    ) -> RotatingLogFile {
        RotatingLogFile(
            url: log, maxBytes: 1024, archives: 2, destinationGuard: guardian,
            gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: logger),
            eventLog: events, logger: logger, effects: effects
        )
    }

    private func refusals(_ events: RuntimeEventLog) -> [String?] {
        events.events.filter { $0.event == RecordFileDestinationGate.eventName }.map(\.detail)
    }

    // MARK: - The four collisions

    func testAnActiveSymlinkToTheConfigIsRefusedAndTheConfigBytesStay() throws {
        let (config, log) = try collision("active-symlink")
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(config), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(try Data(contentsOf: config), Self.witness)
        XCTAssertEqual(refusals(events), ["sink=log reason=protected_path resource=config"])
        file.close()
    }

    func testAnActiveHardlinkToTheConfigIsRefusedAndTheConfigBytesStay() throws {
        let (config, log) = try collision("active-hardlink")
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(config), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(try Data(contentsOf: config), Self.witness)
        XCTAssertEqual(refusals(events), ["sink=log reason=protected_identity resource=config"])
        file.close()
    }

    /// Rotation would rename the active file over `proxy.log.1`, which the config names. The archive slot is judged before the rename.
    func testAnArchiveOneAliasOfTheConfigIsRefusedBeforeAnyRotation() throws {
        let (config, log) = try collision("archive1-target")
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 4, archives: 2, guardian: guardProtectingConfig(config), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(try Data(contentsOf: config), Self.witness)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old-log\n", "the active file is not rotated away")
        XCTAssertEqual(refusals(events), ["sink=log reason=protected_path resource=config"])
        file.close()
    }

    /// Rotation would remove `proxy.log.2`, which the config names. The archive slot is judged before the unlink.
    func testAnArchiveTwoAliasOfTheConfigIsRefusedBeforeAnyRotation() throws {
        let (config, log) = try collision("archive2-target")
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 4, archives: 2, guardian: guardProtectingConfig(config), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(try Data(contentsOf: config), Self.witness)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old-log\n")
        XCTAssertEqual(try String(contentsOf: log.deletingLastPathComponent().appendingPathComponent("proxy.log.1"),
                                  encoding: .utf8), "old-archive\n", "the unrelated archive is untouched")
        XCTAssertEqual(refusals(events), ["sink=log reason=protected_path resource=config"])
        file.close()
    }

    // MARK: - Latch, ordering and file kinds

    /// After the refusal latches, further writes do not reach the guard or the descriptor.
    func testALatchedRefusalMakesNoFurtherAdmitCalls() throws {
        let (config, log) = try collision("active-symlink")
        let counting = CountingGuard(guardProtectingConfig(config))
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: counting, events: events)
        file.write(Data("first\n".utf8))
        file.flush()
        let afterRefusal = counting.count
        XCTAssertGreaterThan(afterRefusal, 0)
        for index in 0..<3 { file.write(Data("later \(index)\n".utf8)) }
        file.flush()
        XCTAssertEqual(counting.count, afterRefusal)
        XCTAssertEqual(refusals(events).count, 1)
        XCTAssertEqual(try Data(contentsOf: config), Self.witness)
        file.close()
    }

    /// The refusal event is appended before its derived line reaches the logger.
    func testARefusalIsPublishedEventFirst() throws {
        let (config, log) = try collision("active-symlink")
        let events = RuntimeEventLog()
        let logger = OrderingLogger(events: events, eventName: RecordFileDestinationGate.eventName)
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(config), events: events, logger: logger)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(logger.seenEventFirst, [true])
        file.close()
    }

    /// An existing directory where the active file belongs is refused by kind before it is opened, and its contents stay.
    func testADirectoryAtTheActivePathIsRefusedAndItsContentsStay() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("proxy.log", isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: log.appendingPathComponent("inside"))
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(dir.appendingPathComponent("config.json")), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(failureDetails(events), ["stage=unsupported_kind code=0"])
        XCTAssertEqual(try String(contentsOf: log.appendingPathComponent("inside"), encoding: .utf8), "keep\n")
        file.close()
    }

    /// A FIFO at the active path is refused by kind before any open, so no reader is needed and nothing can block.
    /// The open is also nonblocking, so even a regression here fails with ENXIO and does not hang.
    func testAFifoAtTheActivePathIsRefusedBeforeItIsOpened() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("proxy.log")
        XCTAssertEqual(mkfifo(log.path, 0o600), 0)
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(dir.appendingPathComponent("config.json")), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(failureDetails(events), ["stage=unsupported_kind code=0"])
        var info = stat()
        XCTAssertEqual(lstat(log.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
        file.close()
    }

    /// A directory in an archive slot is refused by kind before the rename, so no recursive removal can happen.
    func testADirectoryInAnArchiveSlotIsRefusedAndItsContentsStay() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("proxy.log")
        try Data("old-log\n".utf8).write(to: log)
        let archive = dir.appendingPathComponent("proxy.log.1", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: archive.appendingPathComponent("inside"))
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 4, archives: 1, guardian: guardProtectingConfig(dir.appendingPathComponent("config.json")), events: events)
        file.write(Data("new-log\n".utf8))
        file.flush()
        XCTAssertEqual(failureDetails(events), ["stage=unsupported_kind code=0"])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old-log\n")
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("inside"), encoding: .utf8), "keep\n")
        file.close()
    }

    /// A symbolic link to an ordinary admitted file is followed and keeps working; the link itself is not replaced.
    func testASymbolicLinkToAnAdmittedFileKeepsWriting() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("real.log")
        let log = dir.appendingPathComponent("proxy.log")
        try Data("old\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: real)
        let events = RuntimeEventLog()
        let file = writer(log, maxBytes: 1024, archives: 2, guardian: guardProtectingConfig(dir.appendingPathComponent("config.json")), events: events)
        file.write(Data("new\n".utf8))
        file.flush()
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "old\nnew\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: log.path), real.path)
        XCTAssertTrue(events.events.filter { $0.event.hasPrefix("observability.log_file_") }.isEmpty)
        file.close()
    }

    // MARK: - Descriptor flags

    /// The descriptor the guard receives is append-only, nonblocking and close-on-exec as the kernel reports it, read back
    /// with `fcntl` before the first write. The flags the open requested are kept as a second, weaker check.
    func testTheOpenedDescriptorIsAppendOnlyNonblockingAndCloseOnExec() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        let ledger = EffectLedger()
        let inspection = DescriptorInspection()
        let events = RuntimeEventLog()
        let file = effectsWriter(log, guardian: inspection, events: events, effects: ledger.effects(close: { Darwin.close($0) }))
        file.write(Data("line\n".utf8))
        file.flush()

        let kernel = try XCTUnwrap(inspection.flags)
        XCTAssertNotEqual(kernel.descriptor & FD_CLOEXEC, 0, "close-on-exec")
        XCTAssertNotEqual(kernel.status & O_APPEND, 0, "append-only")
        XCTAssertNotEqual(kernel.status & O_NONBLOCK, 0, "nonblocking")
        XCTAssertEqual(kernel.status & O_ACCMODE, O_WRONLY, "write-only")
        let requested = try XCTUnwrap(ledger.requested.withLockedValue { $0 })
        XCTAssertNotEqual(requested & O_CLOEXEC, 0)
        XCTAssertNotEqual(requested & O_NONBLOCK, 0)
        XCTAssertNotEqual(requested & O_APPEND, 0)
        file.close()
    }

    // MARK: - Close

    /// A failed close is reported once, is never retried, and no further descriptor is opened for the writer.
    func testAFailedCloseIsReportedOnceAndNeverRetriedOrReopened() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        let opens = NIOLockedValueBox(0)
        let closes = NIOLockedValueBox(0)
        let effects = RotatingLogFileEffects(
            openFile: { path, requested, mode in
                opens.withLockedValue { $0 += 1 }
                return Darwin.open(path, requested, mode)
            },
            closeDescriptor: { descriptor in
                closes.withLockedValue { $0 += 1 }
                _ = Darwin.close(descriptor)
                return -1
            }
        )
        let events = RuntimeEventLog()
        let file = RotatingLogFile(
            url: log, maxBytes: 1024, archives: 2, destinationGuard: UncheckedRecordFileDestination(),
            gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: DiscardingLogSink()),
            eventLog: events, logger: DiscardingLogSink(), effects: effects
        )
        file.write(Data("one\n".utf8))
        file.flush()
        file.close()
        file.write(Data("two\n".utf8))
        file.flush()
        file.close()

        XCTAssertEqual(opens.withLockedValue { $0 }, 1, "no reopen after an ambiguous close")
        XCTAssertEqual(closes.withLockedValue { $0 }, 1, "an ambiguous close is never retried")
        let details = failureDetails(events).compactMap { $0 }
        XCTAssertEqual(details.count, 1)
        XCTAssertTrue(details.first?.hasPrefix("stage=close ") ?? false, details.first ?? "none")
    }

    /// A write fails and opens the failure streak. The explicit close then reports its own ambiguous close once. The
    /// primary failure stands, the fixture's real descriptor is closed, and the writer never reopens.
    func testAFailedCloseAfterAFailureStreakIsReportedAsCleanupOnceAndNeverReopened() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        try Data("old\n".utf8).write(to: log)
        let ledger = EffectLedger()
        let events = RuntimeEventLog()
        let logger = OrderingLogger(events: events, eventName: Self.cleanupEvent)
        let file = effectsWriter(log, events: events, logger: logger, effects: ledger.effects(
            openWith: { path, _, _ in Darwin.open(path, O_RDONLY) }, close: ledger.closeRealThenEIO
        ))

        file.write(Data("new\n".utf8))
        file.flush()
        XCTAssertEqual(failureDetails(events), ["stage=write code=\(EBADF)"])
        file.close()
        file.write(Data("later\n".utf8))
        file.flush()
        file.close()

        XCTAssertEqual(failureDetails(events), ["stage=write code=\(EBADF)"], "the primary failure stands")
        XCTAssertEqual(cleanupDetails(events), ["stage=close code=\(EIO)"])
        XCTAssertEqual(ledger.opens.withLockedValue { $0 }, 1, "no reopen after an ambiguous close")
        XCTAssertEqual(ledger.closed.withLockedValue { $0 }.count, 1, "an ambiguous close is never retried")
        XCTAssertEqual(ledger.probes.withLockedValue { $0 }, [EBADF], "the close really closed the fixture descriptor")
        XCTAssertEqual(logger.seenEventFirst, [false, true], "the cleanup event is in the log before its derived line")
    }

    /// The descriptor validation fails, and the close of the descriptor it opened is ambiguous. The fake descriptor is
    /// `Int32.max`, so no real handle can be closed by accident. The validation fact and the cleanup fact both stand.
    func testAFailedValidationThenAFailedCloseReportsBothFactsAndNeverReopens() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        let ledger = EffectLedger()
        let events = RuntimeEventLog()
        let file = effectsWriter(log, events: events, effects: ledger.effects(
            openWith: { _, _, _ in Int32.max }, close: ledger.reportEIOWithoutClosing
        ))

        file.write(Data("one\n".utf8))
        file.flush()
        file.write(Data("two\n".utf8))
        file.flush()
        file.close()

        XCTAssertEqual(failureDetails(events), ["stage=fstat code=\(EBADF)"], "the validation fact stands")
        XCTAssertEqual(cleanupDetails(events), ["stage=close code=\(EIO)"])
        XCTAssertEqual(ledger.opens.withLockedValue { $0 }, 1, "no reopen after the failed validation")
        XCTAssertEqual(ledger.closed.withLockedValue { $0 }, [Int32.max], "one close, on the fake descriptor only")
    }

    /// The guard admits the path, then refuses the descriptor it opened. The refusal is the one gate event, and the close
    /// of that descriptor is ambiguous. The fixture's real descriptor is closed, and the writer never reopens.
    func testARefusedOpenedDescriptorWhoseCloseIsAmbiguousReportsTheRefusalAndTheCleanupOnce() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        try Data("old\n".utf8).write(to: log)
        let ledger = EffectLedger()
        let events = RuntimeEventLog()
        let file = effectsWriter(log, guardian: RefusesOpenedDescriptor(), events: events, effects: ledger.effects(
            close: ledger.closeRealThenEIO
        ))

        file.write(Data("new\n".utf8))
        file.flush()
        file.write(Data("later\n".utf8))
        file.flush()
        file.close()

        XCTAssertEqual(refusals(events), ["sink=log reason=protected_identity resource=config"])
        XCTAssertEqual(failureDetails(events), [], "a refusal is not an IO failure")
        XCTAssertEqual(cleanupDetails(events), ["stage=close code=\(EIO)"])
        XCTAssertEqual(ledger.opens.withLockedValue { $0 }, 1, "no reopen after the refusal")
        XCTAssertEqual(ledger.closed.withLockedValue { $0 }.count, 1, "an ambiguous close is never retried")
        XCTAssertEqual(ledger.probes.withLockedValue { $0 }, [EBADF], "the close really closed the fixture descriptor")
        XCTAssertEqual(try Data(contentsOf: log), Data("old\n".utf8), "the refused file is not written")
    }

    /// An ordinary IO failure is in the event log before its derived line reaches the logger.
    func testAnIOFailureIsPublishedEventFirst() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        try Data("old\n".utf8).write(to: log)
        let events = RuntimeEventLog()
        let logger = OrderingLogger(events: events, eventName: "observability.log_file_failed")
        let ledger = EffectLedger()
        let file = effectsWriter(log, events: events, logger: logger, effects: ledger.effects(
            openWith: { path, _, _ in Darwin.open(path, O_RDONLY) }, close: ledger.closeRealThenEIO
        ))
        file.write(Data("new\n".utf8))
        file.flush()
        XCTAssertEqual(logger.seenEventFirst, [true])
        file.close()
    }

    // MARK: - Store release

    /// The store owns the gate and the writer's logger, and neither keeps the store alive.
    @MainActor func testTheStoreIsReleasedWhileItsFileAndGateStillExist() throws {
        let log = try tempDir().appendingPathComponent("proxy.log")
        let events = RuntimeEventLog()
        weak var released: AppLogStore?
        do {
            let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
            store.logFileURL = log
            store.log(.notice, "before release")
            store.flushFileLog()
            released = store
        }
        XCTAssertNil(released)
    }

    // MARK: - Helpers

    private func failureDetails(_ events: RuntimeEventLog) -> [String?] {
        events.events.filter { $0.event == "observability.log_file_failed" }.map(\.detail)
    }

    private func cleanupDetails(_ events: RuntimeEventLog) -> [String?] {
        events.events.filter { $0.event == Self.cleanupEvent }.map(\.detail)
    }
}

/// Counts a writer's opens and closes, and records what each close left behind. A test builds its effects from it, so
/// each descriptor the writer opens and closes is named and checked.
private final class EffectLedger: @unchecked Sendable {
    let requested = NIOLockedValueBox<Int32?>(nil)
    let opens = NIOLockedValueBox(0)
    /// Every descriptor handed to the close hook, in order.
    let closed = NIOLockedValueBox<[Int32]>([])
    /// For each real descriptor the close hook closed, the errno of a `fcntl` probe afterwards. `EBADF` shows it took effect.
    let probes = NIOLockedValueBox<[Int32]>([])

    func effects(
        openWith: @escaping @Sendable (String, Int32, mode_t) -> Int32 = { Darwin.open($0, $1, $2) },
        close: @escaping @Sendable (Int32) -> Int32
    ) -> RotatingLogFileEffects {
        RotatingLogFileEffects(
            openFile: { [requested, opens] path, flags, mode in
                requested.withLockedValue { $0 = flags }
                opens.withLockedValue { $0 += 1 }
                return openWith(path, flags, mode)
            },
            closeDescriptor: { [closed] descriptor in
                closed.withLockedValue { $0.append(descriptor) }
                return close(descriptor)
            }
        )
    }

    /// Really closes the descriptor, then reports `EIO`: the ambiguous close the writer must report and never retry.
    func closeRealThenEIO(_ descriptor: Int32) -> Int32 {
        _ = Darwin.close(descriptor)
        let probe = fcntl(descriptor, F_GETFD)
        let probeErrno = errno
        probes.withLockedValue { $0.append(probe == -1 ? probeErrno : 0) }
        errno = EIO
        return -1
    }

    /// Reports `EIO` without closing anything. Only a fake descriptor is passed to it.
    func reportEIOWithoutClosing(_ descriptor: Int32) -> Int32 {
        errno = EIO
        return -1
    }
}

/// Reads the opened descriptor's flags back from the kernel, in the guard that admits it, before its first write.
private final class DescriptorInspection: RecordFileDestinationGuarding, @unchecked Sendable {
    struct Flags: Sendable {
        let descriptor: Int32
        let status: Int32
    }

    private let seen = NIOLockedValueBox<Flags?>(nil)

    var flags: Flags? { seen.withLockedValue { $0 } }

    func admit(destination: URL) throws {}

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        let flags = Flags(descriptor: fcntl(descriptor, F_GETFD), status: fcntl(descriptor, F_GETFL))
        seen.withLockedValue { $0 = flags }
    }
}

/// Admits the destination and refuses the descriptor it opened, as a late identity check would.
private struct RefusesOpenedDescriptor: RecordFileDestinationGuarding {
    func admit(destination: URL) throws {}

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        throw RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .config)
    }
}

/// Counts the guard's admit calls, so a latch can show that a refused writer no longer asks.
private final class CountingGuard: RecordFileDestinationGuarding, @unchecked Sendable {
    private let inner: any RecordFileDestinationGuarding
    private let calls = NIOLockedValueBox(0)

    init(_ inner: any RecordFileDestinationGuarding) {
        self.inner = inner
    }

    var count: Int { calls.withLockedValue { $0 } }

    func admit(destination: URL) throws {
        calls.withLockedValue { $0 += 1 }
        try inner.admit(destination: destination)
    }

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        calls.withLockedValue { $0 += 1 }
        try inner.admit(openedDescriptor: descriptor, destination: destination)
    }
}

/// Records, for each derived line, whether its event was already in the log when the line arrived.
private final class OrderingLogger: LogSink, @unchecked Sendable {
    private let events: RuntimeEventLog
    private let eventName: String
    private let seen = NIOLockedValueBox<[Bool]>([])

    init(events: RuntimeEventLog, eventName: String) {
        self.events = events
        self.eventName = eventName
    }

    var seenEventFirst: [Bool] { seen.withLockedValue { $0 } }
    var minLevel: LogLevel { .debug }

    func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        let present = events.events.contains { $0.event == eventName }
        seen.withLockedValue { $0.append(present) }
    }
}
