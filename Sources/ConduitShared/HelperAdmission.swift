// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Who the helper acts for, decided per request.
///
/// The console user is the peer the helper serves. At the loginwindow the
/// console reports uid 0, which is also when an app quitting for logout asks
/// the helper to undo what it applied. So while no console user is
/// published, the last console user may still undo, restore and stop;
/// applying fresh redirection waits for a session. The peer must be that
/// uid, not merely non-root: during a fast user switch the console is also
/// uid 0, and another user's process must not reshape the system proxy.
public enum HelperAdmission {
    /// Commands that only undo, restore or stop.
    public static func isTeardownOnly(_ command: HelperCommand) -> Bool {
        switch command {
        case .ping, .removeDNS, .clearSystemProxy, .disableAutoproxy,
             .stopDNSRelay, .stopTCPRelay,
             .setWebProxyEndpoint, .setAutoproxyURL, .setAutoproxy,
             .setProxyBypass, .setDNSServers:
            // The setters restore a recorded prior state during teardown;
            // the helper cannot tell a restore from an apply.
            return true
        case .applyDNS, .applySystemProxy, .startDNSRelay, .startTCPRelay:
            return false
        }
    }

    /// `nil` admits the request. `consoleUID` 0 means nobody; `lastConsoleUID`
    /// is the most recent non-zero console uid this helper has seen; `command`
    /// is `nil` when the request did not parse.
    public static func refusal(
        peerUID: uid_t,
        consoleUID: uid_t,
        lastConsoleUID: uid_t?,
        command: HelperCommand?
    ) -> HelperRefusal? {
        guard peerUID != 0 else { return .unauthorized }
        if consoleUID != 0 {
            return peerUID == consoleUID ? nil : .unauthorized
        }
        if let lastConsoleUID, peerUID == lastConsoleUID,
           let command, isTeardownOnly(command) {
            return nil
        }
        return .noConsoleUser
    }
}
