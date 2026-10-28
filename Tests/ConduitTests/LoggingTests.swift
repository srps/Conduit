// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import Conduit  // AppLogStore lives in the app target

final class LoggingTests: XCTestCase {

    @MainActor func testRingBufferCapturesAllLevels() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minStderrLevel = .error
        store.minBufferedLevel = .debug

        store.log(.debug, "debug msg")
        store.log(.info, "info msg")
        store.log(.warning, "warning msg")
        store.log(.error, "error msg")

        XCTAssertEqual(store.entries.count, 4, "Ring buffer should capture all levels regardless of minStderrLevel")
        XCTAssertEqual(store.entries[0].level, .debug)
        XCTAssertEqual(store.entries[3].level, .error)
    }

    @MainActor func testRingBufferToleratesOverflowSlackBeforeTrimming() {
        // Amortised-trim contract: the buffer grows up to `maxEntries +
        // trimSlack` (= 2256) before any trim happens. Appending 2100
        // entries puts us inside the slack window — no trim should fire,
        // so all 2100 entries are still present.
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .debug
        for i in 0..<2100 {
            store.log(.info, "entry \(i)")
        }
        XCTAssertEqual(store.entries.count, 2100,
                       "Within the trim-slack window the buffer must NOT trim — that's the whole point of the amortised path.")
        XCTAssertEqual(store.entries.first?.message, "entry 0",
                       "No trim means the oldest entry is still index 0.")
    }

    @MainActor func testRingBufferTrimsBackToMaxOnceSlackExceeded() {
        // Cross the slack ceiling (maxEntries + trimSlack = 2256) by one
        // and assert we trim back to `maxEntries` (2000), keeping the
        // newest 2000 entries — i.e. the first kept entry's index is
        // (2257 - 2000) - 1 = 256 (since entry 0 is the very first append
        // and we drop entries 0…256, keeping 257…2256).
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .debug
        for i in 0..<2257 {
            store.log(.info, "entry \(i)")
        }
        XCTAssertEqual(store.entries.count, 2000,
                       "Once we exceed maxEntries + trimSlack, the next append trims back to maxEntries.")
        XCTAssertEqual(store.entries.first?.message, "entry 257",
                       "Trim drops the (count - maxEntries) oldest entries.")
        XCTAssertEqual(store.entries.last?.message, "entry 2256",
                       "Newest entry stays at the end after trim.")
    }

    @MainActor func testRingBufferTrimAmortisesAcrossBurst() {
        // Smoke check: 10000 appends after the buffer is full should
        // remain bounded, never holding more than the slack ceiling.
        // This is the actual perf contract — under a 10K burst we never
        // hold > 2256 entries even momentarily.
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .debug
        for i in 0..<2256 {
            store.log(.info, "warmup \(i)")
        }
        XCTAssertEqual(store.entries.count, 2256, "warmup should fill exactly to the slack ceiling")

        for i in 0..<10_000 {
            store.log(.info, "burst \(i)")
            XCTAssertLessThanOrEqual(
                store.entries.count, 2256,
                "Buffer must never exceed maxEntries + trimSlack mid-burst (count=\(store.entries.count) at i=\(i))"
            )
        }
        XCTAssertGreaterThanOrEqual(store.entries.count, 2000,
                                    "Post-burst the buffer is at least maxEntries.")
        XCTAssertLessThanOrEqual(store.entries.count, 2256,
                                 "Post-burst the buffer is at most maxEntries + trimSlack.")
    }

    @MainActor func testExportDiagnosticLog() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .debug
        store.log(.info, "alpha", category: .proxy)
        store.log(.warning, "beta", category: .system)

        let export = store.exportDiagnosticLog()
        XCTAssertTrue(export.contains("alpha"))
        XCTAssertTrue(export.contains("beta"))
        XCTAssertTrue(export.contains("[INFO]"))
        XCTAssertTrue(export.contains("[WARNING]"))
    }

    @MainActor func testClearEntries() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .debug
        store.log(.info, "will be cleared")
        XCTAssertFalse(store.entries.isEmpty)

        store.clearEntries()
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor func testMinStderrLevelDefault() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        XCTAssertEqual(store.minStderrLevel, .notice)
    }

    @MainActor func testMinBufferedLevelDefault() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        XCTAssertEqual(store.minBufferedLevel, .notice)
    }

    @MainActor func testBelowBufferedLevelNotBuffered() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .warning
        store.log(.debug, "should not appear")
        store.log(.info, "should not appear")
        store.log(.notice, "should not appear")
        store.log(.warning, "should appear")
        store.log(.error, "should appear")
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].level, .warning)
        XCTAssertEqual(store.entries[1].level, .error)
    }

    @MainActor func testFileLoggingCreatesFile() async throws {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        // AppLogStore.log filters all outputs (stderr, buffer, file)
        // by `min(stderrLevel, bufferedLevel)`, keeping the file write
        // consistent with the other outputs. The
        // test logs at .info, so lower the threshold to allow it through.
        store.minBufferedLevel = .info
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConduitLogTest-\(UUID().uuidString)")
        let logFile = tmpDir.appendingPathComponent("test.log")
        defer { removeScratch([tmpDir]) }

        store.logFileURL = logFile
        store.log(.info, "file-logged-message")

        let drained = await store.drain(until: deadline(in: 5))
        XCTAssertEqual(drained, .drained, "the admitted line left the file writer's queue")

        store.logFileURL = nil

        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("file-logged-message"))
    }

    // MARK: - Physical outputs off MainActor

    private func scratchLog(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConduitLogTest-\(UUID().uuidString)")
        addTeardownBlock { removeScratch([directory]) }
        return directory.appendingPathComponent(name)
    }

    /// The bounded join in a synchronous function, so a test can park the main thread on it: the compiler rejects the wait inside
    /// async code.
    private static func parked(_ signal: DispatchSemaphore) -> DispatchTimeoutResult {
        signal.wait(timeout: .now() + 10)
    }

    /// A burst from off main while the main thread is parked. The file takes every line and drains without main; the UI history is
    /// handed off through one bounded buffer and one scheduled drain, and shows the newest lines once main is free. What did not fit
    /// was evicted from the UI history only: no physical record was lost.
    @MainActor func testABurstWhileMainIsParkedReachesTheFileAndOneDrainBringsTheNewestHistory() async throws {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .info
        let logFile = scratchLog("burst.log")
        store.logFileURL = logFile
        let count = 3_000
        let finished = DispatchSemaphore(value: 0)
        let fileDrained = NIOLockedValueBox(false)
        DispatchQueue.global().async {
            for index in 0..<count { store.log(.info, "burst \(index)") }
            fileDrained.withLockedValue { $0 = store.flushFileLog(timeout: 5) }
            finished.signal()
        }
        XCTAssertEqual(Self.parked(finished), .success, "the burst and its file drain finished while main was parked")
        XCTAssertTrue(fileDrained.withLockedValue { $0 }, "the physical file drained without the main thread")
        XCTAssertTrue(store.entries.isEmpty, "no history reached main while it was parked")
        XCTAssertEqual(store.historyDrainsScheduled, 1, "one scheduled drain for the whole burst")

        for _ in 0..<5_000 where store.entries.last?.message != "burst \(count - 1)" {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(store.entries.last?.message, "burst \(count - 1)", "the newest history arrived once main was free")
        XCTAssertTrue((2_000...2_256).contains(store.entries.count), "bounded like the ring: \(store.entries.count)")
        XCTAssertEqual(store.historyEvicted, count - store.entries.count, "the rest was UI history evicted, counted apart")
        let lines = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").filter { $0.contains("burst ") }
        XCTAssertEqual(lines.count, count, "every line reached the file")
        XCTAssertEqual(store.statistics.droppedRecords, 0, "UI eviction is not record loss")
        XCTAssertEqual(store.statistics.failedRecords, 0)
        store.logFileURL = nil
    }

    /// An entry still in the hand-off is appended before the next main-thread entry, so the history keeps emission order, and a
    /// main-thread caller still reads its own entry right after logging it.
    @MainActor func testAnOffMainEntryStillHandedOffPrecedesTheNextMainEntry() {
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minBufferedLevel = .info
        let logged = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.log(.info, "off main first")
            logged.signal()
        }
        XCTAssertEqual(Self.parked(logged), .success)
        store.log(.info, "main second")
        XCTAssertEqual(store.entries.map(\.message), ["off main first", "main second"])
    }

    /// A wait registered on the file writer before a Settings toggle times out while the toggle is closing that writer. It is counted
    /// once, by the store, before and after the swap, and the closed writer's own count of it is not added again. The held line is
    /// written by the close and folded in, so no counter goes back.
    @MainActor func testATimeoutAcrossAToggleIsCountedOnceAndNoCounterGoesBack() async throws {
        let held = HeldDestinationGuard(holds: 1)
        let store = AppLogStore(destinationGuard: held, eventLog: RuntimeEventLog())
        store.minBufferedLevel = .info
        store.logFileURL = scratchLog("first.log")
        // `.info` stays off stderr, so only the file counts these lines.
        store.log(.info, "held line")
        XCTAssertEqual(Self.parked(held.entered), .success, "the file's open is held")
        let before = store.statistics

        let timedOut = DispatchSemaphore(value: 0)
        let wait = Task.detached {
            let outcome = await store.drain(until: deadline(in: 0.3))
            timedOut.signal()
            return outcome
        }
        DispatchQueue.global().async {
            _ = timedOut.wait(timeout: .now() + 10)
            held.release()
        }
        // The close blocks here until the held write ends, which is after the wait timed out.
        store.logFileURL = scratchLog("second.log")
        let outcome = await wait.value
        XCTAssertEqual(outcome, .timedOut)
        let after = store.statistics
        XCTAssertEqual(after.flushTimeouts, before.flushTimeouts + 1, "the late timeout is counted once, across the swap")
        XCTAssertEqual(after.writtenRecords, before.writtenRecords + 1, "the close wrote the held line, and it was folded in")
        XCTAssertEqual(after.droppedRecords, before.droppedRecords)

        store.log(.info, "next line")
        let drained = await store.drain(until: deadline(in: 5))
        XCTAssertEqual(drained, .drained)
        let last = store.statistics
        XCTAssertEqual(last.flushTimeouts, after.flushTimeouts)
        XCTAssertEqual(last.writtenRecords, after.writtenRecords + 1)
        store.logFileURL = nil
    }

    /// A sink that cannot say whether its lines left its queues answers `unavailable`; the stock sinks with nothing pending answer
    /// `drained`, and the store tries the file and stderr both.
    func testAnUnknownSinkCannotClaimADrainAndTheStockSinksAnswerTheirOwn() async {
        struct Unknown: LogSink {
            var minLevel: LogLevel { .debug }
            func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {}
        }
        let unknown = await Unknown().drain(until: deadline(in: 1))
        XCTAssertEqual(unknown, .unavailable)
        let discarding = await DiscardingLogSink().drain(until: deadline(in: 1))
        XCTAssertEqual(discarding, .drained)
        let recording = await RecordingLogSink().drain(until: deadline(in: 1))
        XCTAssertEqual(recording, .drained)
        let console = await ConsoleLogSink().drain(until: deadline(in: 5))
        XCTAssertEqual(console, .drained)
    }

    func testLogLevelComparable() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.notice)
        XCTAssertTrue(LogLevel.notice < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertTrue(LogLevel.debug < LogLevel.error)
    }

    @MainActor func testLogEntryFormattedContainsAllFields() {
        let entry = LogEntry(level: .warning, category: .proxy, message: "test message")
        let formatted = entry.formatted()
        XCTAssertTrue(formatted.contains("[WARNING]"))
        XCTAssertTrue(formatted.contains("[Proxy]"))
        XCTAssertTrue(formatted.contains("test message"))
    }

    // MARK: - LogSink extension filtering

    /// Regression guard: `RecordingLogSink(minLevel: .info)` must drop
    /// `.debug` entries and capture `.info`-and-above entries. Before the
    /// fix, conformers' `log` methods bypassed the filter and captured
    /// every level unconditionally — making the `minLevel` parameter a
    /// lie for `ConsoleLogSink` (floods stderr in non-verbose `pm-proxy`)
    /// and `RecordingLogSink` (tests assertion-capturing at `.info` got
    /// `.debug` noise). The fix centralises filtering in the
    /// `LogSink.log` extension; conformers implement `logImpl` and trust
    /// the caller to have filtered.
    func testRecordingLogSinkFiltersByMinLevel() {
        let sink = RecordingLogSink(minLevel: .info)

        sink.log(.debug, "below threshold", category: .general)
        XCTAssertTrue(sink.entries().isEmpty,
                      ".debug must be filtered when minLevel is .info; " +
                      "if this fails, the LogSink extension is bypassed or a conformer " +
                      "bypasses the extension's minLevel guard.")

        sink.log(.info, "at threshold", category: .general)
        sink.log(.warning, "above threshold", category: .general)
        XCTAssertEqual(sink.entries().count, 2)
        XCTAssertEqual(sink.entries()[0].level, .info)
        XCTAssertEqual(sink.entries()[1].level, .warning)
    }

    /// Regression guard: the `@autoclosure` on `LogSink.log`'s `message`
    /// parameter must defer interpolation when the level is filtered out.
    /// The extension's earlier
    /// `(level, category:, message)` parameter order never matched any
    /// call site, so the optimisation was dead code. Every in-tree
    /// callsite passes `log(.level, "msg", category: .cat)` — the
    /// extension's new `(level, message @autoclosure, category: = .general)`
    /// shape now matches, so the short-circuit fires.
    func testAutoclosureDefersMessageInterpolationWhenFilteredOut() {
        let sideEffectCount = NIOLockedValueBox<Int>(0)
        let sink = RecordingLogSink(minLevel: .info)

        // Below-threshold: the message expression would increment the
        // counter if interpolation ran. The @autoclosure wrapper must
        // defer until after the `level >= minLevel` check — which fails,
        // so the counter stays at 0.
        sink.log(.debug, "side effect: \(buildExpensiveString(counter: sideEffectCount))", category: .general)
        XCTAssertEqual(sideEffectCount.withLockedValue { $0 }, 0,
                       "Message interpolation must be deferred when the level is filtered out. " +
                       "A non-zero counter means the @autoclosure optimisation regressed.")

        // At-threshold: the expression runs and the line is captured.
        sink.log(.info, "side effect: \(buildExpensiveString(counter: sideEffectCount))", category: .general)
        XCTAssertEqual(sideEffectCount.withLockedValue { $0 }, 1,
                       "Message interpolation must run when the level passes the filter.")
        XCTAssertEqual(sink.entries().count, 1)
    }

    func testLogSinkSanitizesCredentialBearingHeaders() {
        let sink = RecordingLogSink(minLevel: .debug)
        let token = String(repeating: "A", count: 96)

        sink.log(
            .info,
            "Proxy-Authorization: Negotiate \(token)\nCookie: session=abc123; theme=dark",
            category: .auth
        )

        let message = sink.entries().first?.message ?? ""
        XCTAssertTrue(message.contains("Proxy-Authorization: <redacted>"))
        XCTAssertTrue(message.contains("Cookie: <redacted>"))
        XCTAssertFalse(message.contains(token))
        XCTAssertFalse(containsUnmaskedLongBase64LikeToken(message))
    }

    func testLogSinkSanitizesAuthorizationAndSetCookieHeaders() {
        let sink = RecordingLogSink(minLevel: .debug)
        let token = String(repeating: "C", count: 96)

        sink.log(
            .info,
            "Authorization: Bearer \(token)\r\nSet-Cookie: refresh=\(token); HttpOnly",
            category: .auth
        )

        let message = sink.entries().first?.message ?? ""
        XCTAssertTrue(message.contains("Authorization: <redacted>"))
        XCTAssertTrue(message.contains("Set-Cookie: <redacted>"))
        XCTAssertFalse(message.contains(token))
        XCTAssertFalse(containsUnmaskedLongBase64LikeToken(message))
    }

    func testLogSinkSanitizesBearerTokensOutsideHeaderLines() {
        let sink = RecordingLogSink(minLevel: .debug)
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"

        sink.log(.warning, "upstream returned Bearer \(token)", category: .auth)

        let message = sink.entries().first?.message ?? ""
        XCTAssertTrue(message.contains("Bearer <redacted>"))
        XCTAssertFalse(message.contains(token))
    }

    func testRuntimeEventSanitizesDetail() {
        let token = String(repeating: "B", count: 96)
        let event = RuntimeEvent(
            kind: .auth,
            event: "auth.challenge",
            detail: "Authorization: Negotiate \(token)"
        )

        XCTAssertEqual(event.detail, "Authorization: <redacted>")
        XCTAssertFalse(event.detail?.contains(token) ?? true)
        XCTAssertFalse(containsUnmaskedLongBase64LikeToken(event.detail ?? ""))
    }

    /// Helper: a side-effecting string builder used by the autoclosure
    /// deferral test. The counter ticks up each invocation so the test
    /// can verify whether the expression ran.
    private func buildExpensiveString(counter: NIOLockedValueBox<Int>) -> String {
        counter.withLockedValue { $0 += 1 }
        return "expensive"
    }

    private func containsUnmaskedLongBase64LikeToken(_ value: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9+/_=-]{65,}\b"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
