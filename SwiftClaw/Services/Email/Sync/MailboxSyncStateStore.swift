import Foundation

/// Persisted high-water mark for incremental IMAP fetches per
/// `(accountID, mailbox)` pair. Stored as JSON in
/// `UserDefaults` (`SettingsKeys.emailMailboxSyncStates`).
///
/// `MailSyncWorker` reads the stored state for an account+mailbox before
/// fetching, compares the recorded `uidValidity` against the live
/// `MailboxFetchResult.uidValidity`, and either continues incrementally
/// (validity matches → pass `lastSeenUID` as `sinceUID`) or resets to a full
/// fetch (validity differs → pass `nil`). After a successful fetch the
/// worker writes the new high-water back via `update(_:for:mailbox:)`.
struct MailboxSyncState: Codable, Sendable, Hashable {
    var uidValidity: UInt32
    var lastSeenUID: UInt32

    init(uidValidity: UInt32 = 0, lastSeenUID: UInt32 = 0) {
        self.uidValidity = uidValidity
        self.lastSeenUID = lastSeenUID
    }
}

/// Single source of truth for incremental-sync high-water marks.
///
/// `@MainActor` singleton — `MailSyncWorker` (an actor) reaches it via
/// `@Sendable` closures that hop to MainActor (see
/// `MailboxSyncStateStore.provider` / `.updater`). Defaults can be overridden
/// in tests by passing custom closures into `MailSyncWorker.init`.
@MainActor
@Observable
final class MailboxSyncStateStore {
    static let shared = MailboxSyncStateStore()

    private let userDefaults: UserDefaults
    private var states: [String: MailboxSyncState]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: SettingsKeys.emailMailboxSyncStates),
           let decoded = try? JSONDecoder().decode([String: MailboxSyncState].self, from: data) {
            self.states = decoded
        } else {
            self.states = [:]
        }
    }

    func state(for accountID: UUID, mailbox: String) -> MailboxSyncState? {
        states[Self.key(for: accountID, mailbox: mailbox)]
    }

    func update(_ state: MailboxSyncState, for accountID: UUID, mailbox: String) {
        states[Self.key(for: accountID, mailbox: mailbox)] = state
        persist()
    }

    /// Removes the recorded state — useful when an account is deleted or when
    /// a test needs to start clean.
    func reset(for accountID: UUID, mailbox: String) {
        states.removeValue(forKey: Self.key(for: accountID, mailbox: mailbox))
        persist()
    }

    /// Removes every state recorded for an account (called when the account
    /// is removed from `EmailAccountStore`).
    func resetAll(for accountID: UUID) {
        let prefix = "\(accountID.uuidString):"
        states = states.filter { !$0.key.hasPrefix(prefix) }
        persist()
    }

    /// A `@Sendable` provider the worker (actor-isolated) can call to snapshot
    /// the current state for an account+mailbox without crossing MainActor
    /// isolation unsafely.
    func provider() -> @Sendable (UUID, String) async -> MailboxSyncState? {
        { [weak self] accountID, mailbox in
            await MainActor.run { self?.state(for: accountID, mailbox: mailbox) }
        }
    }

    /// A `@Sendable` updater the worker can write through.
    func updater() -> @Sendable (MailboxSyncState, UUID, String) async -> Void {
        { [weak self] state, accountID, mailbox in
            await MainActor.run { self?.update(state, for: accountID, mailbox: mailbox) }
        }
    }

    // MARK: - Internals

    static func key(for accountID: UUID, mailbox: String) -> String {
        "\(accountID.uuidString):\(mailbox)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            userDefaults.set(data, forKey: SettingsKeys.emailMailboxSyncStates)
        }
    }
}
