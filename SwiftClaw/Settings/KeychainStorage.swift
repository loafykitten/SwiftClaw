import Foundation
import Security
import SwiftUI

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw"

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

    static func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            delete(key)
            return
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

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration of API keys previously stored in UserDefaults.
    static func migrateAPIKeysFromUserDefaults() {
        let keys = [
            SettingsKeys.azureAPIKey,
            SettingsKeys.neuralwattAPIKey,
            SettingsKeys.openRouterAPIKey,
        ]
        let defaults = UserDefaults.standard

        for key in keys {
            if let value = defaults.string(forKey: key), !value.isEmpty, string(forKey: key) == nil {
                set(value, forKey: key)
            }

            defaults.removeObject(forKey: key)
        }
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
