// SPDX-License-Identifier: Apache-2.0
// Stand-in for the PlatformMac module, compiled only by scripts/test-app-entry.py. It is not the update helper
// preflight. It answers the one argument the entry checks and prints a marker, so the script can see that it ran.
import Foundation

public enum UpdateHelperPreflightWorker {
    public static func run(arguments: [String]) -> Int32? {
        guard arguments.contains("--conduit-update-helper-preflight") else { return nil }
        print("worker updater")
        return 9
    }
}
