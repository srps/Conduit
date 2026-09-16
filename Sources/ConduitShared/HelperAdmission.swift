// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Who the helper acts for, decided per request.
///
/// The console user is the peer the helper serves. At the loginwindow the
/// console reports uid 0, which is also when an app quitting for logout asks
/// the helper to undo what it applied. So while no console user is
/// published, the last console user may still clear, remove and stop;
/// anything that sets a value waits for a session, since the helper
/// cannot tell a restore from an apply. The peer must be that uid, not
/// merely non-root: during a fast user switch the console is also uid 0,
/// and another user's process must not reshape the system proxy.
public enum HelperAdmission {
    /// Commands that take no value: they only clear, remove or stop.
    public static func isTeardownOnly(_ command: HelperCommand) -> Bool {
        switch command {
        case .ping, .removeDNS, .clearSystemProxy, .disableAutoproxy,
             .stopDNSRelay, .stopTCPRelay:
            return true
        case .applyDNS, .applySystemProxy, .startDNSRelay, .startTCPRelay,
             .setWebProxyEndpoint, .setAutoproxyURL, .setAutoproxy,
             .setProxyBypass, .setDNSServers:
            return false
        }
    }

    /// `set-dns-servers <service> Empty` returns a service to DHCP. It is the
    /// only value-carrying form admitted at the loginwindow: system-DNS
    /// teardown stops the relay first, and a service left on 127.0.0.1 after
    /// that has no resolver at all.
    public static func isDNSReset(_ command: HelperCommand, values: [String]) -> Bool {
        command == .setDNSServers && values.count == 2
            && values[1].caseInsensitiveCompare(HelperInputValidator.emptyListSentinel) == .orderedSame
    }

    /// `nil` admits the request. `consoleUID` 0 means nobody; `lastConsoleUID`
    /// is the most recent non-zero console uid this helper has seen; `command`
    /// is `nil` when the request did not parse; `values` are its arguments.
    public static func refusal(
        peerUID: uid_t,
        consoleUID: uid_t,
        lastConsoleUID: uid_t?,
        command: HelperCommand?,
        values: [String] = []
    ) -> HelperRefusal? {
        guard peerUID != 0 else { return .unauthorized }
        if consoleUID != 0 {
            return peerUID == consoleUID ? nil : .unauthorized
        }
        if let lastConsoleUID, peerUID == lastConsoleUID, let command,
           isTeardownOnly(command) || isDNSReset(command, values: values) {
            return nil
        }
        return .noConsoleUser
    }
}
