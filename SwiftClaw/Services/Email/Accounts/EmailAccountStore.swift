import Foundation

/// Persisted IMAP+SMTP account configuration. Stored as JSON in
/// `UserDefaults` (`SettingsKeys.emailAccounts`); passwords are kept in the
/// Keychain under per-account keys derived from the account's UUID (see
/// `EmailAccountKeychainKeys`).
///
/// One `StoredEmailAccount` maps 1:1 to a `SwiftMailClient` instance at sync
/// time. Adding an account is additive; deleting one also removes its
/// Keychain passwords.
///
/// `folders` and the special-use mailbox fields cache the per-account
/// special-use folder names resolved via IMAP `LIST (SPECIAL-USE)` on first
/// use. They're additive Codable fields and stay `nil` until the
/// first `SwiftMailClient.resolveSpecialUseMailboxes()` call lands them —
/// calls that pre-date resolution fall back to a per-provider default table.
nonisolated struct StoredEmailAccount: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var displayName: String
    var imapHost: String
    var imapPort: Int
    var imapUsername: String
    var smtpHost: String
    var smtpPort: Int
    var smtpUsername: String
    var fromAddress: String
    /// Server-side Archive folder name (resolved via IMAP SPECIAL-USE). Gmail
    /// uses `[Gmail]/All Mail`; Outlook uses `Archive`; others vary. `nil`
    /// until resolved — callers fall back to `"Archive"`.
    var archiveMailbox: String?
    /// Server-side Trash folder name. `nil` until resolved — callers fall back
    /// to `"Trash"`.
    var trashMailbox: String?
    /// Server-side Sent folder name. Used by the reply composer's APPEND path
    /// so sent mail shows up locally + on other clients. `nil` until resolved.
    var sentMailbox: String?
    /// Server-side Drafts folder name. Drafts sync read-only.
    var draftsMailbox: String?
    /// Server-side Junk/Spam folder name. Synced and visible, but excluded from
    /// scheduled review unless explicitly requested by folder name.
    var junkMailbox: String?
    /// Cached selectable server folder catalog from IMAP LIST.
    var folders: [MailFolderDescriptor]?
    /// Custom folder names opted into scheduled review. `nil` means none.
    var reviewIncludedMailboxes: [String]?

    init(
        id: UUID = UUID(),
        displayName: String = "",
        imapHost: String = "",
        imapPort: Int = SettingsStorage.defaultEmailImapPort,
        imapUsername: String = "",
        smtpHost: String = "",
        smtpPort: Int = SettingsStorage.defaultEmailSmtpPort,
        smtpUsername: String = "",
        fromAddress: String = "",
        archiveMailbox: String? = nil,
        trashMailbox: String? = nil,
        sentMailbox: String? = nil,
        draftsMailbox: String? = nil,
        junkMailbox: String? = nil,
        folders: [MailFolderDescriptor]? = nil,
        reviewIncludedMailboxes: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUsername = imapUsername
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.fromAddress = fromAddress
        self.archiveMailbox = archiveMailbox
        self.trashMailbox = trashMailbox
        self.sentMailbox = sentMailbox
        self.draftsMailbox = draftsMailbox
        self.junkMailbox = junkMailbox
        self.folders = folders
        self.reviewIncludedMailboxes = reviewIncludedMailboxes
    }

    /// Same as `imapUsername` for most providers. Used as the display label
    /// when `displayName` is empty.
    var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (imapUsername.isEmpty ? fromAddress : imapUsername) : trimmed
    }

    /// Resolved Archive mailbox, or `"Archive"` as a sensible default before
    /// `resolveSpecialUseMailboxes()` has run. (Gmail/others get corrected to
    /// the real folder on first resolution; the default just keeps the local
    /// flag flip + a best-effort server move from blocking the UI.)
    var resolvedArchiveMailbox: String { archiveMailbox ?? "Archive" }
    /// Resolved Trash mailbox, or `"Trash"` as a sensible default.
    var resolvedTrashMailbox: String { trashMailbox ?? "Trash" }
    /// Resolved Sent mailbox, or `nil` — the Sent APPEND path is best-effort
    /// and skipped entirely when there's no resolved Sent folder.
    var resolvedSentMailbox: String? { sentMailbox }

    /// Maps a mailbox name to its folder role using the cached special-use
    /// names first (they can out-resolve the catalog on servers without
    /// SPECIAL-USE, where `resolveSpecialUseMailboxes` falls back to name
    /// heuristics), then the cached folder catalog. `nil` when the name is
    /// unknown to both.
    func folderRole(forMailbox name: String) -> MailFolderRole? {
        func matches(_ candidate: String?) -> Bool {
            guard let candidate, !candidate.isEmpty else { return false }
            return name.caseInsensitiveCompare(candidate) == .orderedSame
        }
        if matches(sentMailbox) { return .sent }
        if matches(draftsMailbox) { return .drafts }
        if matches(trashMailbox) { return .trash }
        if matches(archiveMailbox) { return .archive }
        if matches(junkMailbox) { return .junk }
        return folders?.first { matches($0.name) }?.role
    }

    /// True when all hosts/usernames/from address are present. Passwords
    /// aren't checked here — they live in the Keychain and a missing password
    /// surfaces as a sync-time auth error.
    var isComplete: Bool {
        !imapHost.isEmpty
            && !imapUsername.isEmpty
            && !smtpHost.isEmpty
            && !smtpUsername.isEmpty
            && !fromAddress.isEmpty
    }
}

/// Per-account Keychain key helpers. Passwords are keyed by account UUID so
/// deleting an account can scrub its credentials cleanly.
nonisolated enum EmailAccountKeychainKeys {
    static func imapPassword(for accountID: UUID) -> String {
        "settings.email.account.\(accountID.uuidString).imapPassword"
    }

    static func smtpPassword(for accountID: UUID) -> String {
        "settings.email.account.\(accountID.uuidString).smtpPassword"
    }
}

/// Single source of truth for the user's configured email accounts.
/// Observable so SwiftUI views re-render when accounts are added/removed.
/// Persisted as JSON to `UserDefaults`; passwords go through `Keychain`
/// using per-account keys.
///
/// On first launch after upgrade, `migrateLegacyIfNeeded()` reads the old
/// flat `SettingsKeys.emailImapHost` etc. and creates a single account entry,
/// copying passwords from the legacy keys to the new per-account keys.
@MainActor
@Observable
final class EmailAccountStore {
    static let shared = EmailAccountStore()

    private let userDefaults: UserDefaults
    private(set) var accounts: [StoredEmailAccount]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.accounts = SettingsStorage.loadCodable(
            [StoredEmailAccount].self,
            forKey: SettingsKeys.emailAccounts,
            default: [],
            userDefaults: userDefaults
        )
        // Enforce the completeness invariant at the data layer, not just when
        // Settings happens to be on screen: a partial row (a migration edge or
        // external UserDefaults tampering) must never be visible to sync /
        // MailClient code. Editor-created accounts are always complete
        // (`EmailAccountEditorSheet.canConfirm`), so this only ever removes
        // genuinely-unusable rows.
        pruneIncompleteAccounts()
    }

    /// Drops any persisted account that fails `isComplete`, scrubbing its
    /// Keychain passwords + sync state. Runs on load so the invariant holds
    /// regardless of UI navigation. Skipped in previews so the preview host
    /// doesn't nuke real Keychain / UserDefaults entries.
    private func pruneIncompleteAccounts() {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }
        let incomplete = accounts.filter { !$0.isComplete }
        guard !incomplete.isEmpty else { return }
        incomplete.forEach { remove($0) }
    }

    /// Returns a `Sendable` async closure that snapshots the current account
    /// list on the MainActor. Used by `MailSyncWorker` (an actor) so it can
    /// read the latest accounts each sync without crossing isolation unsafely.
    func accountsProvider() -> @Sendable () async -> [StoredEmailAccount] {
        let store = self
        return {
            await MainActor.run { store.accounts }
        }
    }

    @discardableResult
    func add(_ account: StoredEmailAccount) -> StoredEmailAccount {
        accounts.append(account)
        persist()
        return account
    }

    func update(_ account: StoredEmailAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            accounts.append(account)
            persist()
            return
        }
        accounts[index] = account
        persist()
    }

    func remove(_ account: StoredEmailAccount, deleteKeychain: Bool = true) {
        accounts.removeAll(where: { $0.id == account.id })
        if deleteKeychain {
            Keychain.delete(EmailAccountKeychainKeys.imapPassword(for: account.id))
            Keychain.delete(EmailAccountKeychainKeys.smtpPassword(for: account.id))
        }
        // Drop incremental-sync high-water marks so a re-added account with
        // the same UUID doesn't resume from a stale position.
        MailboxSyncStateStore.shared.resetAll(for: account.id)
        persist()
    }

    func account(for id: UUID) -> StoredEmailAccount? {
        accounts.first(where: { $0.id == id })
    }

    /// True if at least one configured account is complete enough to sync.
    var hasConfiguredAccount: Bool {
        accounts.contains(where: { $0.isComplete })
    }

    // MARK: - Keychain

    func imapPassword(for account: StoredEmailAccount) -> String? {
        Keychain.string(forKey: EmailAccountKeychainKeys.imapPassword(for: account.id))
    }

    func smtpPassword(for account: StoredEmailAccount) -> String? {
        Keychain.string(forKey: EmailAccountKeychainKeys.smtpPassword(for: account.id))
    }

    func setPassword(_ password: String, kind: EmailAccountPasswordKind, for account: StoredEmailAccount) {
        let key: String
        switch kind {
        case .imap: key = EmailAccountKeychainKeys.imapPassword(for: account.id)
        case .smtp: key = EmailAccountKeychainKeys.smtpPassword(for: account.id)
        }
        Keychain.set(password, forKey: key)
    }

    // MARK: - Legacy migration

    /// Reads the pre-multi-account flat settings keys (`SettingsKeys.emailImapHost`
    /// etc.) and synthesizes a single `StoredEmailAccount` with the same
    /// values. Copies any Keychain passwords to per-account keys, then clears
    /// the legacy keys. Idempotent: a no-op if `accounts` is already non-empty
    /// or the legacy state is incomplete (a partial legacy config won't
    /// produce an incomplete account — `EmailAccountEditorSheet.canConfirm`
    /// enforces completeness + Test Connection for new accounts; the migration
    /// path keeps the same invariant so the editor never opens with stale
    /// partial data on disk).
    func migrateLegacyIfNeeded() {
        guard accounts.isEmpty else { return }
        let legacyHost = userDefaults.string(forKey: SettingsKeys.emailImapHost) ?? ""
        guard !legacyHost.isEmpty else { return }

        let smtpHost = userDefaults.string(forKey: SettingsKeys.emailSmtpHost) ?? ""
        let imapUsername = userDefaults.string(forKey: SettingsKeys.emailImapUsername) ?? ""
        let smtpUsername = userDefaults.string(forKey: SettingsKeys.emailSmtpUsername) ?? ""
        let fromAddress = userDefaults.string(forKey: SettingsKeys.emailFromAddress) ?? ""
        // Don't synthesize an incomplete account — a partial legacy state would
        // otherwise land a row the editor can't make usable without re-entering
        // everything. Leave it untouched; the user will add an account through
        // the editor when ready.
        guard !smtpHost.isEmpty,
              !imapUsername.isEmpty,
              !smtpUsername.isEmpty,
              !fromAddress.isEmpty else { return }

        let account = StoredEmailAccount(
            id: UUID(),
            displayName: imapUsername,
            imapHost: legacyHost,
            imapPort: {
                let stored = userDefaults.integer(forKey: SettingsKeys.emailImapPort)
                return stored > 0 ? stored : SettingsStorage.defaultEmailImapPort
            }(),
            imapUsername: imapUsername,
            smtpHost: smtpHost,
            smtpPort: {
                let stored = userDefaults.integer(forKey: SettingsKeys.emailSmtpPort)
                return stored > 0 ? stored : SettingsStorage.defaultEmailSmtpPort
            }(),
            smtpUsername: smtpUsername,
            fromAddress: fromAddress
        )
        accounts = [account]

        if let imapPW = Keychain.string(forKey: SettingsKeys.emailImapPassword), !imapPW.isEmpty {
            Keychain.set(imapPW, forKey: EmailAccountKeychainKeys.imapPassword(for: account.id))
        }
        if let smtpPW = Keychain.string(forKey: SettingsKeys.emailSmtpPassword), !smtpPW.isEmpty {
            Keychain.set(smtpPW, forKey: EmailAccountKeychainKeys.smtpPassword(for: account.id))
        }

        persist()

        // Clear the legacy keys so this migration doesn't run again. The
        // Keychain entries are left in place (harmless; no one reads them
        // after migration).
        for key in [
            SettingsKeys.emailImapHost,
            SettingsKeys.emailImapPort,
            SettingsKeys.emailImapUsername,
            SettingsKeys.emailSmtpHost,
            SettingsKeys.emailSmtpPort,
            SettingsKeys.emailSmtpUsername,
            SettingsKeys.emailFromAddress,
        ] {
            userDefaults.removeObject(forKey: key)
        }
    }

    // MARK: - Internals

    private func persist() {
        SettingsStorage.saveCodable(accounts, forKey: SettingsKeys.emailAccounts, userDefaults: userDefaults)
    }
}

nonisolated enum EmailAccountPasswordKind {
    case imap
    case smtp
}
