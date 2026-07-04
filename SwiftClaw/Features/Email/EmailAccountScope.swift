import Foundation
import SwiftUI

/// Which account's mail the Email tab is showing: everything ("All
/// Accounts") or a single account. Extracted from `EmailView.swift` so the
/// scope/filtering logic is testable without the view.
enum EmailAccountScope: Hashable {
    case all
    case account(UUID)

    var isUnified: Bool {
        if case .all = self { return true }
        return false
    }

    func includes(_ email: Email) -> Bool {
        switch self {
        case .all:
            true
        case .account(let accountID):
            email.accountID == accountID
        }
    }

    /// Falls back to `.all` when the selected account no longer exists
    /// (removed in Settings while the Email tab held a stale selection).
    func normalized(availableAccounts: [StoredEmailAccount]) -> EmailAccountScope {
        switch self {
        case .all:
            .all
        case .account(let accountID):
            availableAccounts.contains { $0.id == accountID } ? self : .all
        }
    }
}

/// One-pass partition of the `@Query` email rows into per-mailbox thread
/// lists under an account scope. Built once per `EmailView.body` render so
/// the partition work isn't repeated per mailbox read.
@MainActor
struct EmailThreadScopeSnapshot {
    let inbox: [EmailThread]
    let archive: [EmailThread]
    let trash: [EmailThread]

    init(emails: [Email], accountScope: EmailAccountScope) {
        let scopedEmails = emails.filter { accountScope.includes($0) }
        inbox = Self.threads(from: scopedEmails.filter { !$0.isArchived && !$0.isDeleted })
        archive = Self.threads(from: scopedEmails.filter { $0.isArchived && !$0.isDeleted })
        trash = Self.threads(from: scopedEmails.filter(\.isDeleted))
    }

    func threads(for mailbox: EmailMailbox) -> [EmailThread] {
        switch mailbox {
        case .inbox:
            inbox
        case .flagged:
            inbox.filter { $0.isFlagged }
        case .archive:
            archive
        case .trash:
            trash
        }
    }

    func search(_ mailbox: EmailMailbox, with searchText: String) -> [EmailThread] {
        threads(for: mailbox).filter { $0.matchesSearch(searchText) }
    }

    private static func threads(from emails: [Email]) -> [EmailThread] {
        var seen = Set<UUID>()
        return emails.compactMap { email in
            guard let thread = email.thread else { return nil }
            guard seen.insert(thread.id).inserted else { return nil }
            return thread
        }
    }
}

/// Resolves the account label shown next to threads. Labels only appear in
/// the unified scope with more than one account — a single-account inbox
/// never needs them.
@MainActor
struct EmailAccountLabeler {
    static let removedAccountLabel = "Removed account"

    private let namesByID: [UUID: String]
    private let showsLabels: Bool

    init(accountScope: EmailAccountScope, accounts: [StoredEmailAccount]) {
        namesByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.effectiveDisplayName) }
        )
        showsLabels = accountScope.isUnified && accounts.count > 1
    }

    func label(for thread: EmailThread) -> String? {
        label(for: thread.accountID ?? thread.latestMessage?.accountID)
    }

    func label(for accountID: UUID?) -> String? {
        guard showsLabels else { return nil }
        guard let accountID else { return Self.removedAccountLabel }
        return namesByID[accountID] ?? Self.removedAccountLabel
    }
}

/// Capsule chip naming the account an email belongs to. One shared look for
/// every surface that labels mail by account: thread rows, thread detail,
/// and chat review-card rows.
struct EmailAccountBadge: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "person.crop.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
