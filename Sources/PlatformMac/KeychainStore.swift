// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import Security

package enum KeychainStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    package var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "Keychain returned invalid data."
        }
    }
}

package struct KeychainStore {
    private let service = "io.github.srps.Conduit"
    package static var accessibleAttribute: CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// Persist an opaque envelope of bytes at the given account key.
    ///
    /// The parameter is `SecretBytes` rather than
    /// raw `Data` so the call site is marked "this is sensitive" at
    /// the type level, and the in-memory lifetime of the bytes is
    /// bounded by SecretBytes's zero-on-deinit. The bytes are materialised
    /// briefly as `Data` via `withUnsafeBytes` here because Security
    /// framework's `kSecValueData` attribute requires `Data` (or
    /// CFData) — the intermediate copy is scoped to the CFDictionary
    /// construction below and released at the end of this method.
    ///
    /// The secret is also Keychain-encrypted at rest per
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    package func save(secret: SecretBytes, account: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(deleteQuery as CFDictionary)

        let status: OSStatus = secret.withUnsafeBytes { buf in
            let data = Data(buf)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: Self.accessibleAttribute
            ]
            return SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    /// Load the opaque envelope at the given account key, or `nil` if
    /// absent. The returned `SecretBytes` wraps the Keychain-provided
    /// data immediately; the intermediate `Data` (produced by
    /// `SecItemCopyMatching`) is released at the end of this method.
    package func load(account: String) throws -> SecretBytes? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.invalidData
        }
        return SecretBytes(data)
    }

    package func exists(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return true
    }

    package func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
