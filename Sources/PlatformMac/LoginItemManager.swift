// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ServiceManagement

package final class LoginItemManager {
    /// The registration write, injectable because `SMAppService` edits the
    /// user's login items for real and has no dry-run: a host test that flips
    /// the switch would otherwise register the test runner to launch at login.
    /// Mirrors the `commandRunner` seam on the other platform managers.
    private let setRegistered: (Bool) throws -> Void

    package init(
        setRegistered: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.setRegistered = setRegistered
    }

    /// Returns whether the registration changed, so a caller that reconciles
    /// the switch can retry a failed change on the next save.
    @discardableResult
    package func setEnabled(_ enabled: Bool, logger: (any LogSink)?) -> Bool {
        do {
            try setRegistered(enabled)
            logger?.log(.notice, enabled ? "Launch at login enabled." : "Launch at login disabled.", category: .system)
            return true
        } catch {
            logger?.log(.warning, "Could not change launch-at-login status: \(error.localizedDescription)", category: .system)
            return false
        }
    }
}
