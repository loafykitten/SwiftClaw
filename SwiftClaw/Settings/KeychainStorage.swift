import Foundation
import Security
import SwiftUI

nonisolated enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw"
    private static let logger = AppLog.make("keychain")

    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` (an empty string deletes the item). Returns `false`
    /// when the Keychain rejected the write, so callers can surface the
    /// failure instead of treating the secret as saved.
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let existingValue = string(forKey: key)

        guard !value.isEmpty else {
            return delete(key)
        }

        guard existingValue != value else {
            return true
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecSuccess {
            postChange(forKey: key)
            return true
        }
        guard status == errSecItemNotFound else {
            logger.error("Keychain update failed (OSStatus \(status, privacy: .public))")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("Keychain add failed (OSStatus \(addStatus, privacy: .public))")
            return false
        }
        postChange(forKey: key)
        return true
    }

    /// Removes the item. Returns `true` when it's gone afterwards (including
    /// when it never existed).
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            postChange(forKey: key)
            return true
        case errSecItemNotFound:
            return true
        default:
            logger.error("Keychain delete failed (OSStatus \(status, privacy: .public))")
            return false
        }
    }

    static let migratedAPIKeys = [
        SettingsKeys.azureAPIKey,
        SettingsKeys.neuralwattAPIKey,
        SettingsKeys.openRouterAPIKey,
        SettingsKeys.braveSearchAPIKey,
    ]

    /// One-time migration of API keys previously stored in UserDefaults. The
    /// UserDefaults copy is removed only once the Keychain verifiably holds a
    /// value for that key; a failed write leaves it in place for the next
    /// launch rather than losing the only copy. `read`/`write` are seams for
    /// tests.
    static func migrateAPIKeysFromUserDefaults(
        defaults: UserDefaults = .standard,
        keys: [String] = migratedAPIKeys,
        read: (String) -> String? = { string(forKey: $0) },
        write: (String, String) -> Bool = { set($0, forKey: $1) }
    ) {
        for key in keys {
            guard let value = defaults.string(forKey: key), !value.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            if read(key) == nil {
                guard write(value, key), read(key) != nil else {
                    logger.error("API key migration to the Keychain failed; keeping the UserDefaults copy")
                    continue
                }
            }
            defaults.removeObject(forKey: key)
        }
    }

    private static func postChange(forKey key: String) {
        NotificationCenter.default.post(
            name: SettingsNotifications.keychainDidChange,
            object: nil,
            userInfo: [SettingsNotifications.changedKey: key]
        )
    }
}

/// Like `@AppStorage`, but backed by the Keychain. Use for secrets such as API keys.
@propertyWrapper
struct KeychainStorage: DynamicProperty {
    @State private var value: String
    private let key: String

    init(_ key: String) {
        self.key = key
        _value = State(initialValue: Keychain.string(forKey: key) ?? "")
    }

    var wrappedValue: String {
        get { value }
        nonmutating set {
            value = newValue
            Keychain.set(newValue, forKey: key)
        }
    }

    var projectedValue: Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}
