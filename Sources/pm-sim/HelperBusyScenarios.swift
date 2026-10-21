// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

/// `pm-sim helper-busy-status` (#197, liveness audit F1). The real helper
/// client reads its status against a stand-in on a temporary Unix socket
/// that takes the ping and never answers, as a helper still in another
/// request's command does. That reading is `busy` with
/// `auth.privilege_helper_busy`, keeps a verdict already held, and refuses
/// an update as `helper_busy`; a refused connect stays `notResponding`. No
/// root, nothing under /Library, no fallback.
enum HelperBusyScenarios {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func run() async throws -> ScenarioResult {
        let started = Date()
        let budget = 200
        let held = try HeldListener()
        defer { held.stop() }
        let events = EventCollector()
        let noFallback = AppleScriptPrivilegeClient(runner: { _ in
            events.fallbackRan()
            throw Failure(description: "a status read ran the AppleScript fallback")
        })
        let busyClient = HelperToolPrivilegeClient(
            eventSink: { events.append($0) }, socketPath: held.path, fallback: noFallback,
            transactionMilliseconds: budget, binaryPath: held.path
        )
        let busy = busyClient.status
        let busyEvents = events.drain()

        // The installed binary with nothing listening: a conclusive failure.
        let binary = "/tmp/pm-sim-helper-bin-\(getpid())"
        guard FileManager.default.createFile(atPath: binary, contents: Data()) else {
            throw Failure(description: "could not create \(binary)")
        }
        defer { unlink(binary) }
        let refusedClient = HelperToolPrivilegeClient(
            eventSink: { events.append($0) }, socketPath: binary + ".sock", fallback: noFallback,
            transactionMilliseconds: budget, binaryPath: binary
        )
        let refused = refusedClient.status
        let refusedEvents = events.drain()

        let exitCode = UpdateHelperPreflightWorker.run(arguments: [UpdateHelperPreflightWorker.argument]) { busy }
        var updateEvents: [RuntimeEvent] = []
        var installs = 0
        let gate = UpdateInstallGate(preflight: FakeUpdatePreflight(
            failure: UpdateHelperPreflightWorker.failureReason(exitCode: exitCode ?? 0)
        )) { updateEvents.append($0) }
        let candidate = UpdateCandidate(archive: URL(string: "https://example.invalid/update.zip")!, version: "0.5.7",
                                        length: 1, signature: "fixture", publicKey: "fixture",
                                        host: URL(fileURLWithPath: "/tmp/Conduit.app"))
        do {
            try await gate.run(candidate) { installs += 1 }
        } catch let error as UpdatePreflightError where error.reason == "helper_busy" {
            // The refusal under test; the serving host keeps running.
        }

        return ScenarioResult(
            name: "helper-busy-status", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a ping the helper takes and never answers reads as busy, not notResponding", busy == .busy),
                .init("the busy reading is one auth.privilege_helper_busy naming the reply wait",
                      busyEvents.map(\.event) == ["auth.privilege_helper_busy"]
                          && (busyEvents.first?.detail?.contains("waiting for the reply") ?? false)),
                .init("a busy reading keeps the installed verdict", HelperToolPrivilegeClient.Status.installed.updated(by: busy) == .installed),
                .init("a refused connect is a conclusive notResponding", refused == .notResponding),
                .init("the refused read is one auth.privilege_helper_not_responding",
                      refusedEvents.map(\.event) == ["auth.privilege_helper_not_responding"]),
                .init("no status read ran the AppleScript fallback", !events.fallbackWasRun),
                .init("the update preflight refuses a busy helper as helper_busy",
                      exitCode == 74 && installs == 0
                          && updateEvents.map(\.detail) == ["version=0.5.7", "version=0.5.7 reason=helper_busy"]),
            ],
            notes: ["busy=\(busyEvents.compactMap(\.detail)) refused=\(refusedEvents.compactMap(\.detail))"]
        )
    }

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RuntimeEvent] = []
        private var fallback = false
        func append(_ event: RuntimeEvent) { lock.withLock { events.append(event) } }
        func drain() -> [RuntimeEvent] {
            lock.withLock {
                defer { events.removeAll() }
                return events
            }
        }
        func fallbackRan() { lock.withLock { fallback = true } }
        var fallbackWasRun: Bool { lock.withLock { fallback } }
    }

    /// Accepts, reads one request line, and holds the connection open
    /// without answering until `stop()`.
    private final class HeldListener: @unchecked Sendable {
        let path: String
        private let serverFD: Int32
        private let lock = NSLock()
        private var held: [Int32] = []
        private let done = DispatchSemaphore(value: 0)

        init() throws {
            // sun_path is 104 bytes; /tmp keeps it short.
            path = "/tmp/pm-sim-busy-\(getpid()).sock"
            unlink(path)
            serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFD >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            path.withCString { source in
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    _ = strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, capacity)
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(serverFD, 1) == 0 else {
                let reason = String(cString: strerror(errno))
                close(serverFD)
                throw Failure(description: "bind/listen \(path): \(reason)")
            }
            Thread { [self] in
                serve()
                done.signal()
            }.start()
        }

        private func serve() {
            while true {
                let peer = accept(serverFD, nil, nil)
                guard peer >= 0 else { return }
                var byte: UInt8 = 0
                while Darwin.read(peer, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
                lock.withLock { held.append(peer) }
            }
        }

        func stop() {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            _ = done.wait(timeout: .now() + 5)
            lock.withLock { held }.forEach { close($0) }
            unlink(path)
        }
    }
}
