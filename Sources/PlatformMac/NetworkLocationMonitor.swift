// SPDX-License-Identifier: Apache-2.0
import Foundation
import SystemConfiguration
import ConduitShared

package protocol NetworkLocationObserving: Sendable {
    func start(onChange: @escaping @Sendable (Result<String, NetworkSettingsError>) -> Void,
               onSettingsChange: @escaping @Sendable () -> Void)
    func stop()
}

/// Preferences notifications detect location switches and later settings rewrites
/// even with an unchanged NWPath. Holds one subscription and two callbacks.
package final class NetworkLocationMonitor: NetworkLocationObserving, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "Conduit.network-location")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var preferences: SCPreferences?
    private var callback: (@Sendable (Result<String, NetworkSettingsError>) -> Void)?
    private var settingsCallback: (@Sendable () -> Void)?
    private var lastID: String?

    package init() { queue.setSpecific(key: queueKey, value: true) }

    package func start(onChange: @escaping @Sendable (Result<String, NetworkSettingsError>) -> Void,
                       onSettingsChange: @escaping @Sendable () -> Void) {
        var initial: SCPreferences?
        var unavailable = false
        lock.withLock {
            guard preferences == nil else { return }
            callback = onChange
            settingsCallback = onSettingsChange
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
        let delivery = lock.withLock { () -> (@Sendable () -> Void)? in
            guard preferences === prefs, let callback else { return nil }
            SCPreferencesSynchronize(prefs)
            guard let current = SCNetworkSetCopyCurrent(prefs), let id = SCNetworkSetGetSetID(current) as String? else {
                return { callback(.failure(.unavailable)) }
            }
            if id != lastID {
                lastID = id
                return { callback(.success(id)) }
            }
            // A VPN client can rewrite Proxies after its path/VPN reports have
            // settled. The location identity stays unchanged. The host's
            // bounded reconcile compares values and skips our own writes.
            return settingsCallback
        }
        delivery?()
    }

    package func stop() {
        let prefs = lock.withLock { () -> SCPreferences? in
            defer { preferences = nil; callback = nil; settingsCallback = nil; lastID = nil }
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
