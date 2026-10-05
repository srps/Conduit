// SPDX-License-Identifier: Apache-2.0
import Foundation
import SystemConfiguration
import ConduitShared

package protocol NetworkLocationObserving: Sendable {
    func start(onChange: @escaping @Sendable (Result<String, NetworkSettingsError>) -> Void)
    func stop()
}

/// Preferences apply notifications detect location switches even with an unchanged NWPath.
/// Holds one subscription, one last identity and one callback; no polling or per-location timers.
package final class NetworkLocationMonitor: NetworkLocationObserving, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "Conduit.network-location")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var preferences: SCPreferences?
    private var callback: (@Sendable (Result<String, NetworkSettingsError>) -> Void)?
    private var lastID: String?

    package init() { queue.setSpecific(key: queueKey, value: true) }

    package func start(onChange: @escaping @Sendable (Result<String, NetworkSettingsError>) -> Void) {
        var initial: SCPreferences?
        var unavailable = false
        lock.withLock {
            guard preferences == nil else { return }
            callback = onChange
            guard let prefs = SCPreferencesCreate(nil, "Conduit location observer" as CFString, nil) else {
                unavailable = true
                return
            }
            var context = SCPreferencesContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            guard SCPreferencesSetCallback(prefs, { prefs, _, context in
                guard let context else { return }
                Unmanaged<NetworkLocationMonitor>.fromOpaque(context).takeUnretainedValue().receive(prefs)
            }, &context), SCPreferencesSetDispatchQueue(prefs, queue) else {
                SCPreferencesSetCallback(prefs, nil, nil)
                unavailable = true
                return
            }
            preferences = prefs
            initial = prefs
        }
        if unavailable { onChange(.failure(.unavailable)) }
        if let initial { receive(initial) }
    }

    private func receive(_ prefs: SCPreferences) {
        let delivery = lock.withLock { () -> ((@Sendable (Result<String, NetworkSettingsError>) -> Void), Result<String, NetworkSettingsError>)? in
            guard preferences === prefs, let callback else { return nil }
            SCPreferencesSynchronize(prefs)
            guard let current = SCNetworkSetCopyCurrent(prefs), let id = SCNetworkSetGetSetID(current) as String? else {
                return (callback, .failure(.unavailable))
            }
            guard id != lastID else { return nil }
            lastID = id
            return (callback, .success(id))
        }
        if let (callback, result) = delivery { callback(result) }
    }

    package func stop() {
        let prefs = lock.withLock { () -> SCPreferences? in
            defer { preferences = nil; callback = nil; lastID = nil }
            return preferences
        }
        if let prefs {
            SCPreferencesSetDispatchQueue(prefs, nil)
            // Drain callbacks before the unretained context can be released.
            if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
            SCPreferencesSetCallback(prefs, nil, nil)
        }
    }

    deinit { stop() }
}
