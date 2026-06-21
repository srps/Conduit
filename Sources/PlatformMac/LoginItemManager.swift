// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ServiceManagement

package final class LoginItemManager {
    package init() {}
    package func setEnabled(_ enabled: Bool, logger: (any LogSink)?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger?.log(.notice, "Launch at login enabled.", category: .system)
            } else {
                try SMAppService.mainApp.unregister()
                logger?.log(.notice, "Launch at login disabled.", category: .system)
            }
        } catch {
            logger?.log(.warning, "Could not change launch-at-login status: \(error.localizedDescription)", category: .system)
        }
    }
}
