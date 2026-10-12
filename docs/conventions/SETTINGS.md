# Settings & Persistence Conventions

All settings code lives in `Settings/`.

1. **`SettingsKeys`** (`AppSettings.swift`) — string constants for every
   persisted key.
2. **`@AppStorage(SettingsKeys.foo)`** — non-secret primitives in views.
3. **`@KeychainStorage(SettingsKeys.bar)`** (`KeychainStorage.swift`) — secrets
   (API keys, IMAP/SMTP passwords). Use `Keychain.set/delete/string(forKey:)`
   outside SwiftUI. Per-account keys are runtime values, so account passwords
   use `Keychain.set(...)` directly rather than the property wrapper.
   The wrapper keeps what the field shows apart from what the Keychain holds
   (`KeychainEntry`): bind fields with `$key.text`, and show them through
   `SecretKeyRow(secret: $key)` so a rejected write is flagged inline instead
   of looking saved.
   `Keychain.set`/`delete` return `false` on failure — check it wherever a
   user confirms a save, and never delete a migration source until the
   Keychain verifiably holds the value.
4. **`SettingsStorage`** — static helpers with an injectable `UserDefaults` for
   tests (template: `isWebSearchEnabled(userDefaults:)`). Defaults/ranges live
   as `static let defaultX` / `xRange` next to the helper. Tests pass a
   `UserDefaultsFixture`.
