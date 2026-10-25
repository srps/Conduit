// SPDX-License-Identifier: Apache-2.0
// Stand-in for the ProxyAuth module, compiled only by scripts/test-app-entry.py. It is not the Kerberos worker. It
// answers the one argument the entry checks and prints a marker, so the script can see that the worker ran.
import Foundation

public enum KerberosTicketRecoveryWorker {
    public static func run(arguments: [String]) -> Int32? {
        guard arguments.contains("--conduit-kerberos-ticket") else { return nil }
        print("worker kerberos")
        return 7
    }
}
