// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyAuth
import PlatformMac

/// The process entry. Synchronous and `@MainActor` on purpose: SwiftUI and AppKit
/// start from the top-level main thread, outside any main-queue block and any
/// MainActor job. An `async` entry runs as a MainActor job drained from the main
/// dispatch queue, and `NSApplicationMain`'s nested run loop then does not service
/// queued main-queue work or MainActor jobs. `scripts/test-app-entry.py` checks this.
@main
@MainActor
enum ConduitMain {
    static func main() {
        // Checked before the workers: they run ahead of app composition and
        // reach the real helper or the Kerberos cache. A dev request, by flag
        // or by bundle, never does, in a release build either.
        if let refusal = DevLaunch.workerRefusal(
            arguments: CommandLine.arguments,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            DevLaunch.fail(refusal)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let status = UpdateHelperPreflightWorker.run(arguments: arguments) {
            exit(status)
        }
        if let status = KerberosTicketRecoveryWorker.run(arguments: arguments) {
            exit(status)
        }
        // Takes the state root before SwiftUI builds the app, so a busy or refused
        // root exits with nothing loaded, migrated or recovered (decision 0028).
        PreparedAppLaunch.prepare()
        ConduitApp.main()
    }
}
