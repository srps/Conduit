// SPDX-License-Identifier: Apache-2.0
//
// Standalone TSan probe for the continuation handoff in continuation-app-report.txt. No Conduit, no NIO, no packages.
//
// A task isolated to a default global actor (like `@RuntimeActor`) repeatedly awaits a nonisolated function shaped like
// `EventLoopFuture.get()`: its `withUnsafeThrowingContinuation` body hands the continuation to a dedicated non-pool thread through a
// lock-protected single-slot queue, and returns; that thread takes the work out under the lock and resumes the continuation outside it, as
// `SelectableEventLoop` runs a task submitted by an off-loop `whenComplete`. Consecutive awaits in the same function reuse the same
// task-allocator memory for their continuation contexts, as consecutive `.get()` calls in one test function do.
//
// Everything is legal Swift concurrency: each continuation is resumed exactly once, every value crossing threads is Sendable, the
// shared queue is lock-protected, and nothing here races by construction. The `usleep` calls only shift timing; they are not
// synchronization, so they do not give TSan a happens-before edge.
//
// Build:  swiftc -swift-version 6 -parse-as-library -sanitize=thread -g -Onone continuation-handoff.swift -o handoff-repro
// Run:    TSAN_OPTIONS=halt_on_error=1 ./handoff-repro <mode> [iterations] [delayMicros] [actor|nonisolated]
//
// Modes:
//   handoff       the body hands off and returns at once; whichever of resume and await comes first is left to timing (as in NIO)
//   resume-first  the body hands off, then sleeps before returning, so the resume usually lands before the await
//   await-first   the resumer sleeps before resuming, so the task usually suspends first and is re-enqueued (control)
//   inline        the body resumes on the awaiting thread itself (control: one thread, nothing to report)
//
// Prints only the mode, the bounds, a checksum and the elapsed time.

import Dispatch
import Foundation

@globalActor
actor ReproActor {
    static let shared = ReproActor()
}

enum Mode: String, CaseIterable, Sendable {
    case handoff
    case resumeFirst = "resume-first"
    case awaitFirst = "await-first"
    case inline
}

/// A non-Void result, like the `Channel` a bind's `.get()` returns.
final class Payload: Sendable {
    let n: Int
    init(_ n: Int) { self.n = n }
}

/// A dedicated thread with a lock-protected single-slot queue: the shape of an event loop's task queue.
final class Resumer: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: (@Sendable () -> Void)?
    private var finished = false
    private let exited = DispatchSemaphore(value: 0)

    func start() {
        let thread = Thread { [self] in
            run()
            exited.signal()
        }
        thread.name = "repro-resumer"
        thread.start()
    }

    func execute(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        precondition(pending == nil && !finished)
        pending = work
        condition.signal()
        condition.unlock()
    }

    /// Synchronous, so the join is not a blocking wait in an async context.
    func finishAndJoin() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
        precondition(exited.wait(timeout: .now() + 30) == .success)
    }

    private func run() {
        while true {
            condition.lock()
            while pending == nil, !finished { condition.wait() }
            guard let work = pending else {
                condition.unlock()
                return
            }
            pending = nil
            condition.unlock()
            // Outside the lock, as the loop runs its tasks.
            work()
        }
    }
}

struct Settings: Sendable {
    let mode: Mode
    let iterations: Int
    let delayMicros: UInt32
    let resumer: Resumer
}

/// Shaped like `EventLoopFuture.get()`: nonisolated, the continuation captured once and resumed once from the other thread.
func get<T: Sendable>(_ value: T, _ s: Settings) async throws -> T {
    try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<T, Error>) in
        switch s.mode {
        case .inline:
            continuation.resume(returning: value)
        case .handoff:
            s.resumer.execute { continuation.resume(returning: value) }
        case .resumeFirst:
            s.resumer.execute { continuation.resume(returning: value) }
            usleep(s.delayMicros)
        case .awaitFirst:
            let delay = s.delayMicros
            s.resumer.execute {
                usleep(delay)
                continuation.resume(returning: value)
            }
        }
    }
}

/// Alternates a non-Void and a Void result, as `isFree` alternates a bind and a close.
@ReproActor
func driveOnActor(_ s: Settings) async throws -> Int {
    var sum = 0
    for i in 0..<s.iterations {
        if i & 1 == 0 {
            sum &+= try await get(Payload(i), s).n
        } else {
            try await get((), s)
            sum &+= 1
        }
    }
    return sum
}

func driveNonisolated(_ s: Settings) async throws -> Int {
    var sum = 0
    for i in 0..<s.iterations {
        if i & 1 == 0 {
            sum &+= try await get(Payload(i), s).n
        } else {
            try await get((), s)
            sum &+= 1
        }
    }
    return sum
}

@main
enum HandoffRepro {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2, let mode = Mode(rawValue: args[1]) else {
            print("usage: handoff-repro <\(Mode.allCases.map(\.rawValue).joined(separator: "|"))> [iterations] [delayMicros] [actor|nonisolated]")
            exit(2)
        }
        let iterations = min(max(args.count > 2 ? Int(args[2]) ?? 200_000 : 200_000, 1), 2_000_000)
        let delayMicros = min(max(args.count > 3 ? UInt32(args[3]) ?? 20 : 20, 0), 1_000)
        let onActor = args.count > 4 ? args[4] != "nonisolated" : true

        let resumer = Resumer()
        resumer.start()
        let settings = Settings(mode: mode, iterations: iterations, delayMicros: delayMicros, resumer: resumer)

        let clock = ContinuousClock()
        let started = clock.now
        let checksum: Int
        if onActor {
            checksum = try await driveOnActor(settings)
        } else {
            checksum = try await driveNonisolated(settings)
        }
        let elapsed = clock.now - started
        resumer.finishAndJoin()

        print("mode=\(mode.rawValue) driver=\(onActor ? "actor" : "nonisolated") iterations=\(iterations) delayMicros=\(delayMicros) checksum=\(checksum) elapsed=\(elapsed)")
    }
}
