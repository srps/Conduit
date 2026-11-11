// SPDX-License-Identifier: Apache-2.0
// pm-vpn-check — diagnostic CLI for Conduit's `VPNStatusMonitor`.
//
// Standalone tool that wires up only the SCDynamicStore-based VPN observer
// and prints every state transition to stdout. Used for two purposes:
//
//   1. Live verification that VPNStatusMonitor correctly observes utun
//      transitions on the current macOS version. Run it, toggle your VPN,
//      watch the state stream.
//   2. Reproducer harness when a user reports "VPN status row shows the
//      wrong thing." Output captures exactly what the kernel told us via
//      SCDynamicStore plus the fused state we derived.
//
// Side-effect surface (intentionally minimal — mirrors the AGENTS.md
// constraint on `pm-proxy`):
//   - SCDynamicStoreCreate / SCDynamicStoreSetNotificationKeys / Copy*
//     against the user's live store. Read-only.
//   - One DispatchQueue. No network, no Keychain, no proxy listener,
//     no system-proxy mutation, no privileged helper IPC.
//
// Usage:
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-vpn-check
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-vpn-check --duration 120 --grace 5 --min-visible 1
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-vpn-check --pushed-dns
//
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-vpn-check --snapshot
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-vpn-check --watch --max-duration 600 > connect.ndjson
//
// `--pushed-dns` reads the tunnels' pushed resolvers once through
// `PushedResolverMonitor.readOnce()` and prints them masked: domains as
// `dN.example`, servers as documentation addresses, service IDs as `serviceN`.
// The output can be pasted into a public issue.
//
// `--snapshot` reads every tunnel key once through `SystemTunnelStore` and
// prints one line of JSON, masked by `TunnelStoreMask`. `--watch` prints such
// a line at the start and after every store notification, until Ctrl-C or
// `--max-duration` seconds. Both only read the store. The lines go to stdout
// and everything else to stderr, so stdout can be saved as a fixture.

import Dispatch
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

@main
enum PMVpnCheck {
    static func main() {
        let args = parseArgs()
        if args.pushedDNS {
            printPushedResolvers()
            return
        }
        switch args.capture {
        case .snapshot:
            printSnapshot()
            return
        case .watch:
            watchSnapshots(maxDuration: args.maxDurationSeconds)
            return
        case nil:
            break
        }

        print("pm-vpn-check — VPNStatusMonitor live diagnostic")
        print("  duration       : \(args.durationSeconds)s")
        print("  graceSeconds   : \(args.graceSeconds)")
        print("  minVisibleSecs : \(args.minVisibleSeconds)")
        print("---")

        let received = NIOLockedValueBox<Int>(0)
        let monitor = VPNStatusMonitor(
            graceSecondsProvider: { args.graceSeconds },
            minVisibleSecondsProvider: { args.minVisibleSeconds }
        )
        monitor.setOnChange { state in
            let ts = isoTimestamp()
            received.withLockedValue { $0 += 1 }
            print("[\(ts)] VPN STATE → \(format(state))")
            fflush(stdout)
        }

        // Install signal handlers so Ctrl-C produces a clean teardown
        // (releases the SCDynamicStore handle and balances the +1 retain
        // installStore() takes on self for the C callback context).
        let signalSource = installSigintHandler { monitor.stop(); exit(0) }
        defer { signalSource.cancel() }

        monitor.start()
        Thread.sleep(forTimeInterval: args.durationSeconds)
        monitor.stop()

        print("---")
        let count = received.withLockedValue { $0 }
        print("Observed \(count) state transitions in \(args.durationSeconds)s.")
        if count == 0 {
            print("WARN: zero transitions. Either the prime missed (no utun visible to SCDynamicStore) or the monitor is stuck. Check `scutil -- list .*utun.*` to see what the kernel actually publishes.")
        }
    }

    // MARK: - Args

    private struct Args {
        var durationSeconds: TimeInterval
        var graceSeconds: TimeInterval
        var minVisibleSeconds: TimeInterval
        var pushedDNS = false
        var capture: CaptureMode?
        var maxDurationSeconds: TimeInterval
    }

    private enum CaptureMode {
        case snapshot
        case watch
    }

    /// How long `--watch` runs when `--max-duration` is not given.
    private static let defaultMaxDurationSeconds: TimeInterval = 900

    private static func parseArgs() -> Args {
        var duration: TimeInterval = 60
        var grace: TimeInterval = 2
        var minVisible: TimeInterval = 0.5
        var pushedDNS = false
        var capture: CaptureMode?
        var maxDuration = defaultMaxDurationSeconds

        var iter = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iter.next() {
            switch arg {
            case "--duration":
                if let next = iter.next(), let v = Double(next) { duration = v }
            case "--grace":
                if let next = iter.next(), let v = Double(next) { grace = v }
            case "--min-visible":
                if let next = iter.next(), let v = Double(next) { minVisible = v }
            case "--pushed-dns":
                pushedDNS = true
            case "--snapshot":
                capture = .snapshot
            case "--watch":
                capture = .watch
            case "--max-duration":
                guard let next = iter.next(), let seconds = Double(next), seconds > 0, seconds.isFinite else {
                    fail("--max-duration takes a number of seconds above zero", code: 2)
                }
                maxDuration = seconds
            case "--help", "-h":
                print("Usage: pm-vpn-check [--duration <s>] [--grace <s>] [--min-visible <s>]")
                print("       pm-vpn-check --pushed-dns | --snapshot | --watch [--max-duration <s>]")
                print("  --duration     run for this many seconds (default 60)")
                print("  --grace        VPN grace window before declaring disconnect (default 2)")
                print("  --min-visible  minimum-visible-flap debounce (default 0.5)")
                print("  --pushed-dns   read the tunnels' pushed resolvers once, print them masked, exit")
                print("  --snapshot     read every tunnel key once, print one masked JSON line, exit")
                print("  --watch        print a masked JSON line now and after each store notification")
                print("  --max-duration stop --watch after this many seconds (default \(Int(defaultMaxDurationSeconds)))")
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown arg: \(arg)\n".utf8))
            }
        }
        return Args(
            durationSeconds: duration, graceSeconds: grace, minVisibleSeconds: minVisible, pushedDNS: pushedDNS,
            capture: capture, maxDurationSeconds: maxDuration
        )
    }

    // MARK: - Tunnel store captures

    private static func printSnapshot() {
        var mask = TunnelStoreMask()
        let capture = TunnelStoreCapture(reading: SystemTunnelStore().readKeys(), at: Date(), elapsed: 0, mask: &mask)
        emit(capture)
        if let failure = capture.failure { fail("the store could not be read: \(failure)", code: 1) }
    }

    private static func watchSnapshots(maxDuration: TimeInterval) {
        let watch = CaptureWatch()
        let subscription: any TunnelStoreSubscription
        switch watch.subscribe() {
        case .success(let made): subscription = made
        case .failure(let failure):
            fail("the store could not be watched: \(failure.step.rawValue) code \(failure.code)", code: 1)
        }
        // Subscribed before the first reading, so no change falls between them.
        watch.queue.async { watch.capture() }

        let interrupted = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { interrupted.signal() }
        sigint.resume()
        note("watching the tunnel keys for up to \(Int(maxDuration)) s; Ctrl-C stops")

        let reason = interrupted.wait(timeout: .now() + maxDuration) == .success ? "interrupted" : "max duration reached"
        sigint.cancel()
        subscription.cancel()
        // Lets a line that is being written finish.
        watch.queue.sync {}
        note("stopped: \(reason)")
    }

    /// Reads and prints on one queue, so lines come out whole and in order.
    private final class CaptureWatch: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.github.srps.Conduit.pm-vpn-check.watch")
        private let store = SystemTunnelStore()
        private let began = ProcessInfo.processInfo.systemUptime
        /// Touched only on `queue`.
        private var mask = TunnelStoreMask()

        func subscribe() -> Result<any TunnelStoreSubscription, TunnelReading.Failure> {
            store.subscribe(
                queue: queue, onChange: { [self] in capture() },
                onUncancelledRelease: { outcome in
                    switch outcome {
                    case .success: note("the watch was released without a cancel; the store detached it")
                    case .failure(let failure):
                        note("the watch was released without a cancel and the store refused to detach it: \(failure.step.rawValue) code \(failure.code)")
                    }
                }
            )
        }

        /// Runs on `queue`.
        func capture() {
            emit(TunnelStoreCapture(
                reading: store.readKeys(), at: Date(),
                elapsed: ProcessInfo.processInfo.systemUptime - began, mask: &mask
            ))
        }
    }

    private static func emit(_ capture: TunnelStoreCapture) {
        do {
            print(try capture.line())
            fflush(stdout)
        } catch {
            fail("a capture could not be encoded: \(error)", code: 1)
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("pm-vpn-check: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        note(message)
        exit(code)
    }

    // MARK: - Pushed resolvers

    private static func printPushedResolvers() {
        print("pm-vpn-check — pushed resolvers, one read-only store reading, masked")
        let reading = PushedResolverMonitor.readOnce()
        if let failure = reading.failure {
            print("unavailable: \(failure.rawValue)")
            exit(1)
        }
        var mask = Mask()
        print("resolvers: \(reading.resolvers.count)")
        for resolver in reading.resolvers {
            let order = resolver.searchOrder.map(String.init) ?? "-"
            print("  \(mask.service(resolver.serviceID)) \(resolver.interface) searchOrder=\(order) overridesPrimary=\(resolver.overridesPrimary)")
            print("    domains: \(resolver.domains.map { mask.domain($0) })")
            print("    servers: \(resolver.servers.map { mask.server($0) })")
        }
        print("rejections: \(reading.rejections.count)")
        for rejection in reading.rejections {
            let value = rejection.value.map { raw in
                rejection.reason == .invalidServer || IPAddressSyntax.isLiteral(raw) ? mask.server(raw) : mask.domain(raw)
            } ?? "-"
            print("  \(mask.service(rejection.serviceID)) \(rejection.interface ?? "-") \(rejection.reason.rawValue) \(value)")
        }
    }

    /// Stable placeholders: the same input masks to the same output within a run.
    private struct Mask {
        private var domains: [String: String] = [:]
        private var servers: [String: String] = [:]
        private var services: [String: String] = [:]

        mutating func domain(_ value: String) -> String {
            remember(value, in: &domains) { "d\($0).example" }
        }

        mutating func server(_ value: String) -> String {
            let v6 = value.contains(":")
            return remember(value, in: &servers) { v6 ? "2001:db8::\($0)" : "192.0.2.\($0)" }
        }

        mutating func service(_ value: String) -> String {
            remember(value, in: &services) { "service\($0)" }
        }

        private func remember(_ value: String, in table: inout [String: String], _ make: (Int) -> String) -> String {
            if let known = table[value] { return known }
            let masked = make(table.count + 1)
            table[value] = masked
            return masked
        }
    }

    // MARK: - Helpers

    private static func format(_ state: VPNObservedState) -> String {
        switch state {
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnected(let reason):
            switch reason {
            case .userInitiated: return "disconnected(userInitiated)"
            case .networkLost: return "disconnected(networkLost)"
            case .unknown: return "disconnected(unknown)"
            }
        case .unknown: return "unknown"
        }
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func installSigintHandler(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            handler()
        }
        source.resume()
        return source
    }
}
