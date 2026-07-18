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
    let sent: [EmailThread]
    let drafts: [EmailThread]
    let junk: [EmailThread]
    let archive: [EmailThread]
    let trash: [EmailThread]
    let customFolders: [String: [EmailThread]]
    let customFolderNames: [String]

    init(emails: [Email], accountScope: EmailAccountScope) {
        let scopedEmails = emails.filter { accountScope.includes($0) }
        inbox = Self.threads(from: scopedEmails.filter {
            !$0.isArchived
                && !$0.isDeleted
                && ($0.role == .inbox || $0.role == .sent)
        })
        sent = Self.threads(from: scopedEmails.filter { $0.role == .sent && !$0.isDeleted })
        drafts = Self.threads(from: scopedEmails.filter { $0.role == .drafts && !$0.isDeleted })
        junk = Self.threads(from: scopedEmails.filter { $0.role == .junk && !$0.isDeleted })
        archive = Self.threads(from: scopedEmails.filter { $0.isArchived && !$0.isDeleted })
        trash = Self.threads(from: scopedEmails.filter(\.isDeleted))

        var groupedCustom: [String: [Email]] = [:]
        for email in scopedEmails where email.role == .custom && !email.isArchived && !email.isDeleted {
            groupedCustom[email.mailbox, default: []].append(email)
        }
        customFolderNames = groupedCustom.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        customFolders = Dictionary(uniqueKeysWithValues: customFolderNames.map { name in
            (name, Self.threads(from: groupedCustom[name] ?? []))
        })
    }

    /// The sidebar's mailbox list. Empty mailboxes stay hidden except
    /// Inbox + Flagged, the primary navigation anchors. Custom folders are
    /// per-account — the unified multi-account view passes
    /// `showCustomFolders: false` so two accounts' folder lists don't
    /// interleave into one long sidebar.
    func visibleMailboxes(showCustomFolders: Bool) -> [EmailMailbox] {
        var mailboxes: [EmailMailbox] = [.inbox, .flagged]
        if !sent.isEmpty { mailboxes.append(.sent) }
        if !drafts.isEmpty { mailboxes.append(.drafts) }
        if !junk.isEmpty { mailboxes.append(.junk) }
        if !archive.isEmpty { mailboxes.append(.archive) }
        if !trash.isEmpty { mailboxes.append(.trash) }
        if showCustomFolders {
            mailboxes.append(contentsOf: customFolderNames.map(EmailMailbox.custom))
        }
        return mailboxes
    }

    func threads(for mailbox: EmailMailbox) -> [EmailThread] {
        switch mailbox {
        case .inbox:
            inbox
        case .flagged:
            inbox.filter { $0.isFlagged }
        case .sent:
            sent
        case .drafts:
            drafts
        case .junk:
            junk
        case .archive:
            archive
        case .trash:
            trash
        case .custom(let name):
            customFolders[name] ?? []
        }
    }

    func search(_ mailbox: EmailMailbox, with searchText: String) -> [EmailThread] {
        guard SearchQuery.isActive(searchText) else { return threads(for: mailbox) }
        return threads(for: mailbox).filter { $0.matchesSearch(searchText) }
    }

    private static func threads(from emails: [Email]) -> [EmailThread] {
        var seen = Set<UUID>()
        return emails.compactMap { email in
            guard let thread = email.thread else { return nil }
            guard seen.insert(thread.id).inserted else { return nil }
            return thread
        }
    }

    var allThreads: [EmailThread] {
        var seen = Set<UUID>()
        return (inbox + sent + drafts + junk + archive + trash + customFolderNames.flatMap { customFolders[$0] ?? [] })
            .filter { seen.insert($0.id).inserted }
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
