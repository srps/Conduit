// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ServiceManagement

package final class LoginItemManager {
    package init() {}
    /// Returns whether the registration changed, so a caller that reconciles
    /// the switch can retry a failed change on the next save.
    @discardableResult
    package func setEnabled(_ enabled: Bool, logger: (any LogSink)?) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger?.log(.notice, "Launch at login enabled.", category: .system)
            } else {
                try SMAppService.mainApp.unregister()
                logger?.log(.notice, "Launch at login disabled.", category: .system)
            }
            return true
        } catch {
            logger?.log(.warning, "Could not change launch-at-login status: \(error.localizedDescription)", category: .system)
            return false
        }
    }
}
