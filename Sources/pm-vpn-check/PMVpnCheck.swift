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

import Dispatch
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

@main
enum PMVpnCheck {
    static func main() {
        let args = parseArgs()

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
    }

    private static func parseArgs() -> Args {
        var duration: TimeInterval = 60
        var grace: TimeInterval = 2
        var minVisible: TimeInterval = 0.5

        var iter = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iter.next() {
            switch arg {
            case "--duration":
                if let next = iter.next(), let v = Double(next) { duration = v }
            case "--grace":
                if let next = iter.next(), let v = Double(next) { grace = v }
            case "--min-visible":
                if let next = iter.next(), let v = Double(next) { minVisible = v }
            case "--help", "-h":
                print("Usage: pm-vpn-check [--duration <s>] [--grace <s>] [--min-visible <s>]")
                print("  --duration     run for this many seconds (default 60)")
                print("  --grace        VPN grace window before declaring disconnect (default 2)")
                print("  --min-visible  minimum-visible-flap debounce (default 0.5)")
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown arg: \(arg)\n".utf8))
            }
        }
        return Args(durationSeconds: duration, graceSeconds: grace, minVisibleSeconds: minVisible)
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
