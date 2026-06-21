// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import UserNotifications

package final class NotificationManager {
    package init() {}
    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    package func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) { _, _ in }
    }

    package func post(title: String, body: String) {
        guard canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
