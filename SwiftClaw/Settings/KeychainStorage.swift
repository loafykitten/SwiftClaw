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

/// What a secret field shows versus what the Keychain holds. A failed write
/// keeps the typed value on screen (so the user doesn't lose it) but leaves
/// `persisted` at the last value that actually landed, so the field can say
/// the change didn't save instead of looking like the credential is in use.
nonisolated struct KeychainEntry: Equatable, Sendable {
    private(set) var entered: String
    private(set) var persisted: String

    init(persisted: String) {
        self.entered = persisted
        self.persisted = persisted
    }

    /// Whether the field shows a value the Keychain doesn't hold.
    var isUnsaved: Bool {
        entered != persisted
    }

    /// Shows `newValue` and stores it through `write` (`Keychain.set` in
    /// production), which returns `false` when the Keychain rejected it.
    mutating func update(_ newValue: String, write: (String) -> Bool) {
        entered = newValue
        if write(newValue) {
            persisted = newValue
        }
    }

    /// Inline copy for a field whose last write failed; `nil` once saved.
    var saveFailureMessage: String? {
        guard isUnsaved else { return nil }
        if entered.isEmpty {
            return "Couldn't remove this key from the Keychain, so the saved key is still in use."
        }
        if persisted.isEmpty {
            return "Couldn't save this key to the Keychain, so no key is in use. Edit it to try again."
        }
        return "Couldn't save this key to the Keychain, so the previously saved key is still in use. Edit it to try again."
    }
}

/// Like `@AppStorage`, but backed by the Keychain. Use for secrets such as API
/// keys. Every edit is written immediately; `$value.text` binds a field and
/// `$value.entry` says whether the Keychain actually holds what it shows.
@propertyWrapper
struct KeychainStorage: DynamicProperty {
    struct Projection {
        let text: Binding<String>
        let entry: KeychainEntry
    }

    @State private var entry: KeychainEntry
    private let key: String

    init(_ key: String) {
        self.key = key
        _entry = State(initialValue: KeychainEntry(persisted: Keychain.string(forKey: key) ?? ""))
    }

    var wrappedValue: String {
        get { entry.entered }
        nonmutating set {
            entry.update(newValue) { Keychain.set($0, forKey: key) }
        }
    }

    var projectedValue: Projection {
        Projection(
            text: Binding(
                get: { wrappedValue },
                set: { wrappedValue = $0 }
            ),
            entry: entry
        )
    }
}
