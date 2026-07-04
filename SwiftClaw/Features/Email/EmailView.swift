import Observation
import SwiftData
import SwiftUI

struct EmailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query(sort: \Email.date, order: .reverse)
    private var emails: [Email]

    @State private var selectedThreadID: UUID?
    @State private var selectedMailbox: EmailMailbox = .inbox
    @State private var emailSearchText = ""
    @State private var composingReplyFor: Email?
    @State private var manualSyncCoordinator = EmailManualSyncCoordinator.shared
    @State private var manualReviewCoordinator = EmailManualReviewCoordinator.shared
    @State private var selectedAccountScope: EmailAccountScope = .all
    @AppStorage(SettingsKeys.emailReviewSlideAction)
    private var quickActionRaw = SettingsStorage.defaultEmailReviewSlideAction.rawValue
    var pendingEmailID: UUID?
    var openCompactThread: ((EmailMailbox, UUID) -> Void)?
    var onPendingEmailHandled: () -> Void = {}

    private var isConfigured: Bool {
        EmailAccountStore.shared.hasConfiguredAccount
    }

    private var completeAccounts: [StoredEmailAccount] {
        EmailAccountStore.shared.accounts.filter(\.isComplete)
    }

    private var quickAction: ReviewActionToken {
        EmailReviewSlideAction(rawValue: quickActionRaw)?.token
            ?? SettingsStorage.defaultEmailReviewSlideAction.token
    }

    var body: some View {
        // Each partition filters all @Query emails, so compute them ONCE
        // per render and derive
        // everything (filtered list, selection, visible mailboxes, the
        // empty-state gate) from these locals — reading the partitions
        // repeatedly used to re-run that work many times per `body` pass.
        let accounts = completeAccounts
        let accountScope = selectedAccountScope.normalized(availableAccounts: accounts)
        let accountLabeler = EmailAccountLabeler(accountScope: accountScope, accounts: accounts)
        let snapshot = EmailThreadScopeSnapshot(emails: emails, accountScope: accountScope)
        let sent = snapshot.sent
        let drafts = snapshot.drafts
        let junk = snapshot.junk
        let archive = snapshot.archive
        let trash = snapshot.trash

        let searched = snapshot.search(selectedMailbox, with: emailSearchText)
        let selected = searched.first { $0.id == selectedThreadID } ?? searched.first

        // Empty mailboxes stay hidden except Inbox + Flagged, which are the
        // primary navigation anchors.
        var visibleMailboxes: [EmailMailbox] = [.inbox, .flagged]
        if !sent.isEmpty { visibleMailboxes.append(.sent) }
        if !drafts.isEmpty { visibleMailboxes.append(.drafts) }
        if !junk.isEmpty { visibleMailboxes.append(.junk) }
        if !archive.isEmpty { visibleMailboxes.append(.archive) }
        if !trash.isEmpty { visibleMailboxes.append(.trash) }
        visibleMailboxes.append(contentsOf: snapshot.customFolderNames.map(EmailMailbox.custom))

        // True when the account has *any* mail anywhere (Inbox / Archive /
        // Trash). Gates the full-screen empty state — the per-mailbox "no
        // messages" placeholder lives inside `threadLayout` so the sidebar
        // stays reachable when the selected mailbox is empty (e.g. Flagged
        // with nothing flagged). Otherwise switching to an empty mailbox
        // replaces the whole pane with a centered placeholder and strands
        // the user with no way back to Inbox without leaving the Email tab.
        let hasAnyMail = !snapshot.allThreads.isEmpty
        return Group {
            if !isConfigured {
                unconfiguredState
            } else if !hasAnyMail {
                emptyState
            } else {
                if horizontalSizeClass == .compact {
                    compactThreadLayout(
                        snapshot: snapshot,
                        visibleMailboxes: visibleMailboxes,
                        accounts: accounts,
                        accountLabeler: accountLabeler
                    )
                } else {
                    threadLayout(
                        filtered: searched,
                        selected: selected,
                        visibleMailboxes: visibleMailboxes,
                        accounts: accounts,
                        accountLabeler: accountLabeler
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Sync Now", systemImage: "arrow.clockwise", action: startRefreshNow)
                .help("Sync mail now")
                .disabled(MailSyncMonitor.shared.isSyncing || manualSyncCoordinator.isRefreshing)

                Button(action: startReviewNow) {
                    Label {
                        Text("Review Now")
                    } icon: {
                        if MailSyncMonitor.shared.isReviewing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
                .help("Run an inbox review pass now")
                .disabled(MailSyncMonitor.shared.isReviewing || manualReviewCoordinator.isReviewing)

                // Open Settings → Email directly rather than via a sheet
                // containing only a "Open Settings" link (which forces a
                // second click to reach the real settings pane).
                AppSettingsButton(section: .email) {
                    Label("Email Settings", systemImage: "gear")
                }
                .help("Open Email settings")
            }
        }
        .sheet(item: $composingReplyFor) { email in
            if let account = EmailAccountStore.shared.account(for: email.accountID) {
                EmailReplyComposerView(email: email, account: account)
            } else {
                Text("The account for this email has been removed.")
                    .padding()
            }
        }
        .onChange(of: searched.first?.id) { _, _ in
            if selectedThreadID == nil {
                selectedThreadID = searched.first?.id
            }
        }
        .onAppear {
            normalizeAccountScope()
            handlePendingEmailSelection()
        }
        .onChange(of: accounts.map(\.id)) { _, _ in
            normalizeAccountScope()
        }
        .onChange(of: pendingEmailID) { _, emailID in
            handlePendingEmailSelection(emailID)
        }
        .onChange(of: emails.compactMap { $0.thread?.id }) { _, _ in
            handlePendingEmailSelection()
        }
    }

    private func threadLayout(
        filtered: [EmailThread],
        selected: EmailThread?,
        visibleMailboxes: [EmailMailbox],
        accounts: [StoredEmailAccount],
        accountLabeler: EmailAccountLabeler
    ) -> some View {
        HStack(spacing: 0) {
            EmailMailboxSidebar(
                selectedMailbox: $selectedMailbox,
                accountScope: $selectedAccountScope,
                accounts: accounts,
                syncStatusLabel: MailSyncMonitor.shared.statusLabel,
                isSyncing: MailSyncMonitor.shared.isSyncing,
                visibleMailboxes: visibleMailboxes,
                lastSyncDate: MailSyncMonitor.shared.lastSyncDate,
                lastNewMessageCount: MailSyncMonitor.shared.lastNewMessageCount,
                lastRemovedMessageCount: MailSyncMonitor.shared.lastRemovedMessageCount
            )
            .frame(width: 180)

            Divider()

            EmailThreadListView(
                threads: filtered,
                mailbox: selectedMailbox,
                quickAction: quickAction,
                selectedThreadID: Binding(
                    get: { selected?.id },
                    set: { selectedThreadID = $0 }
                ),
                searchText: $emailSearchText,
                isSearching: isSearchingEmails,
                accountLabeler: accountLabeler,
                onQuickAction: performQuickAction
            )
            .frame(width: 280)

            Divider()

            if let selected {
                EmailThreadDetailView(
                    thread: selected,
                    accountLabel: accountLabeler.label(for: selected),
                    onReply: { email in composingReplyFor = email }
                )
            } else {
                FeaturePlaceholderView(
                    systemImage: "envelope.open",
                    title: "No thread selected",
                    message: "Pick one from the list."
                )
            }
        }
    }

    private func compactThreadLayout(
        snapshot: EmailThreadScopeSnapshot,
        visibleMailboxes: [EmailMailbox],
        accounts: [StoredEmailAccount],
        accountLabeler: EmailAccountLabeler
    ) -> some View {
        let allThreads = snapshot.allThreads

        // No NavigationStack here: in compact widths this view is pushed onto
        // the Workspace stack, so mailboxes and threads push onto that stack.
        return List {
            if accounts.count > 1 {
                Section {
                    EmailAccountPicker(accountScope: $selectedAccountScope, accounts: accounts)
                }
            }
            Section {
                ForEach(visibleMailboxes) { mailbox in
                    NavigationLink(value: mailbox) {
                        Label(mailbox.title, systemImage: mailbox.systemImage)
                    }
                }
            } footer: {
                if let status = MailSyncMonitor.shared.statusLabel, !status.isEmpty {
                    Label(status, systemImage: MailSyncMonitor.shared.isSyncing ? "arrow.triangle.2.circlepath" : "info.circle")
                } else if let lastSyncDate = MailSyncMonitor.shared.lastSyncDate {
                    Label("Synced \(lastSyncDate.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                }
            }
        }
        .navigationDestination(for: EmailMailbox.self) { mailbox in
            EmailThreadNavigationList(
                mailbox: mailbox,
                threads: snapshot.search(mailbox, with: emailSearchText),
                quickAction: quickAction,
                searchText: $emailSearchText,
                isSearching: isSearchingEmails,
                accountLabeler: accountLabeler,
                onQuickAction: performQuickAction
            )
            .navigationTitle(mailbox.title)
        }
        .navigationDestination(for: UUID.self) { threadID in
            if let thread = allThreads.first(where: { $0.id == threadID }) {
                EmailThreadDetailView(
                    thread: thread,
                    accountLabel: accountLabeler.label(for: thread),
                    onReply: { email in composingReplyFor = email }
                )
                .navigationTitle(thread.latestMessage?.subject ?? "(no subject)")
                .toolbarTitleDisplayMode(.inline)
            } else {
                FeaturePlaceholderView(
                    systemImage: "envelope.open",
                    title: "No thread selected",
                    message: "Pick one from the list."
                )
            }
        }
    }

    private var isSearchingEmails: Bool {
        SearchQuery.isActive(emailSearchText)
    }

    private func handlePendingEmailSelection(_ emailID: UUID? = nil) {
        guard let emailID = emailID ?? pendingEmailID,
              let email = emails.first(where: { $0.id == emailID }),
              let thread = email.thread else { return }

        if !selectedAccountScope.includes(email) {
            selectedAccountScope = .all
        }
        selectedMailbox = mailbox(for: email)
        selectedThreadID = thread.id

        if horizontalSizeClass == .compact {
            openCompactThread?(mailbox(for: email), thread.id)
        }

        onPendingEmailHandled()
    }

    private func normalizeAccountScope() {
        let normalized = selectedAccountScope.normalized(availableAccounts: completeAccounts)
        if normalized != selectedAccountScope {
            selectedAccountScope = normalized
        }
    }

    private func mailbox(for email: Email) -> EmailMailbox {
        if email.isDeleted {
            return .trash
        }
        if email.isArchived {
            return .archive
        }
        if email.isFlagged {
            return .flagged
        }
        switch email.role {
        case .sent:
            return .sent
        case .drafts:
            return .drafts
        case .junk:
            return .junk
        case .custom:
            return .custom(email.mailbox)
        case .inbox, .trash, .archive:
            break
        }
        return .inbox
    }

    private func quickActionTarget(for thread: EmailThread, in mailbox: EmailMailbox) -> Email? {
        switch mailbox {
        case .inbox:
            thread.sortedMessages.last { !$0.isArchived && !$0.isDeleted && ($0.role == .inbox || $0.role == .sent) }
        case .flagged:
            thread.sortedMessages.last { !$0.isArchived && !$0.isDeleted && $0.isFlagged }
                ?? thread.sortedMessages.last { !$0.isArchived && !$0.isDeleted }
        case .sent:
            thread.sortedMessages.last { $0.role == .sent && !$0.isDeleted }
        case .drafts:
            thread.sortedMessages.last { $0.role == .drafts && !$0.isDeleted }
        case .junk:
            thread.sortedMessages.last { $0.role == .junk && !$0.isDeleted }
        case .archive:
            thread.sortedMessages.last { $0.isArchived && !$0.isDeleted }
        case .trash:
            thread.sortedMessages.last { $0.isDeleted }
        case .custom(let name):
            thread.sortedMessages.last {
                $0.role == .custom
                    && $0.mailbox.caseInsensitiveCompare(name) == .orderedSame
                    && !$0.isArchived
                    && !$0.isDeleted
            }
        }
    }

    private func performQuickAction(_ action: ReviewActionToken, thread: EmailThread, mailbox: EmailMailbox) {
        guard let email = quickActionTarget(for: thread, in: mailbox) else { return }

        if action == .reply {
            guard mailbox != .drafts else { return }
            composingReplyFor = email
            return
        }

        Task { @MainActor in
            let repository = EmailRepository(modelContext: modelContext)
            let mailClient = EmailMailClientResolver.mailClient(for: email)

            switch action {
            case .review:
                await EmailServerAction.setFlags(
                    email: email,
                    repository: repository,
                    mailClient: mailClient,
                    isRead: true,
                    isFlagged: nil
                )
            case .flag:
                await EmailServerAction.toggleFlag(
                    email: email,
                    repository: repository,
                    mailClient: mailClient
                )
            case .reply:
                break
            case .delete:
                await EmailServerAction.delete(
                    email: email,
                    repository: repository,
                    mailClient: mailClient
                )
            case .archive:
                await EmailServerAction.archive(
                    email: email,
                    repository: repository,
                    mailClient: mailClient
                )
            }
        }
    }

    private var unconfiguredState: some View {
        FeaturePlaceholderView(
            systemImage: "envelope",
            title: "Email isn't configured",
            message: "Add IMAP and SMTP credentials in Settings → Email."
        )
        .overlay(alignment: .bottom) {
            AppSettingsButton(section: .email) {
                Text("Open Email Settings")
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        FeaturePlaceholderView(
            systemImage: "envelope",
            title: "No messages",
            message: MailSyncMonitor.shared.isSyncing ? "Syncing mail…" : "Sync to fetch messages."
        )
    }

    private func startRefreshNow() {
        manualSyncCoordinator.startRefreshNow()
    }

    private func startReviewNow() {
        manualReviewCoordinator.startReviewNow()
    }
}

@MainActor
@Observable
private final class EmailManualReviewCoordinator {
    static let shared = EmailManualReviewCoordinator()

    private(set) var isReviewing = false

    @ObservationIgnored private var reviewTask: Task<Void, Never>?

    private init() {}

    func startReviewNow() {
        guard reviewTask == nil else { return }

        isReviewing = true
        reviewTask = Task { @MainActor [weak self] in
            guard !ProcessInfo.processInfo.isRunningInPreview else {
                self?.finishReview()
                return
            }
            await EmailWorkflowManager.shared.reviewNow()
            self?.finishReview()
        }
    }

    private func finishReview() {
        reviewTask = nil
        isReviewing = false
    }
}

@MainActor
@Observable
private final class EmailManualSyncCoordinator {
    static let shared = EmailManualSyncCoordinator()

    private(set) var isRefreshing = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init() {}

    func startRefreshNow() {
        guard refreshTask == nil else { return }

        isRefreshing = true
        refreshTask = Task { @MainActor [weak self] in
            guard !ProcessInfo.processInfo.isRunningInPreview else {
                self?.finishRefresh()
                return
            }
            // Route through `EmailWorkflowManager` (not a one-off
            // `MailSyncWorker`) so a manual sync also kicks an immediate review
            // pass — otherwise the user has to wait up to
            // `emailReviewIntervalSeconds` for triage after a sync.
            await EmailWorkflowManager.shared.refreshNow()
            self?.finishRefresh()
        }
    }

    private func finishRefresh() {
        refreshTask = nil
        isRefreshing = false
    }
}

// MARK: - Mailboxes

enum EmailMailbox: Hashable, Identifiable {
    case inbox
    case flagged
    case sent
    case drafts
    case junk
    case archive
    case trash
    case custom(String)

    var id: String {
        switch self {
        case .inbox: "inbox"
        case .flagged: "flagged"
        case .sent: "sent"
        case .drafts: "drafts"
        case .junk: "junk"
        case .archive: "archive"
        case .trash: "trash"
        case .custom(let name): "custom:\(name)"
        }
    }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .flagged: "Flagged"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .junk: "Junk"
        case .archive: "Archive"
        case .trash: "Trash"
        case .custom(let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .flagged: "flag"
        case .sent: "paperplane"
        case .drafts: "doc.text"
        case .junk: "xmark.bin"
        case .archive: "archivebox"
        case .trash: "trash"
        case .custom: "folder"
        }
    }

    var isCustom: Bool {
        if case .custom = self { true } else { false }
    }
}

private struct EmailMailboxSidebar: View {
    @Binding var selectedMailbox: EmailMailbox
    @Binding var accountScope: EmailAccountScope
    let accounts: [StoredEmailAccount]
    let syncStatusLabel: String?
    let isSyncing: Bool
    let visibleMailboxes: [EmailMailbox]

    /// Round-trips from the monitor so the footer can render "last synced
    /// 3m ago" alongside (or instead of) the transient status label. Passed
    /// in rather than read directly so SwiftUI's observation tracks the
    /// `@Observable MailSyncMonitor.shared` correctly across re-renders.
    let lastSyncDate: Date?
    let lastNewMessageCount: Int
    let lastRemovedMessageCount: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mailboxes")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if accounts.count > 1 {
                EmailAccountPicker(accountScope: $accountScope, accounts: accounts)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            #if os(macOS)
            List(selection: $selectedMailbox) {
                mailboxSections
            }
            .listStyle(.sidebar)
            #else
            List {
                mailboxSections
            }
            .listStyle(.sidebar)
            #endif

            footer
        }
    }

    /// Standard mailboxes first, then the dynamic "Folders" group for custom
    /// IMAP folders. Shared by both platform Lists; only the row chrome
    /// differs (macOS selection tags vs. iOS buttons).
    @ViewBuilder
    private var mailboxSections: some View {
        ForEach(visibleMailboxes.filter { !$0.isCustom }, content: mailboxRow)
        let customMailboxes = visibleMailboxes.filter(\.isCustom)
        if !customMailboxes.isEmpty {
            Section("Folders") {
                ForEach(customMailboxes, content: mailboxRow)
            }
        }
    }

    @ViewBuilder
    private func mailboxRow(_ mailbox: EmailMailbox) -> some View {
        #if os(macOS)
        Label(mailbox.title, systemImage: mailbox.systemImage)
            .tag(mailbox)
            .listItemTint(.accentColor)
        #else
        Button {
            selectedMailbox = mailbox
        } label: {
            Label(mailbox.title, systemImage: mailbox.systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedMailbox == mailbox ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        #endif
    }

    @ViewBuilder
    private var footer: some View {
        if let syncStatusLabel, !syncStatusLabel.isEmpty {
            Divider()
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView().controlSize(.mini)
                }
                Text(syncStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let lastSyncDate {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text("Synced \(lastSyncDate.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmailAccountPicker: View {
    @Binding var accountScope: EmailAccountScope
    let accounts: [StoredEmailAccount]

    var body: some View {
        Picker("Account", selection: $accountScope) {
            Text("All Accounts").tag(EmailAccountScope.all)
            ForEach(accounts) { account in
                Text(account.effectiveDisplayName)
                    .tag(EmailAccountScope.account(account.id))
            }
        }
        .pickerStyle(.menu)
    }
}

private struct EmailThreadListView: View {
    let threads: [EmailThread]
    let mailbox: EmailMailbox
    let quickAction: ReviewActionToken
    @Binding var selectedThreadID: UUID?
    @Binding var searchText: String
    let isSearching: Bool
    let accountLabeler: EmailAccountLabeler
    let onQuickAction: (ReviewActionToken, EmailThread, EmailMailbox) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Threads")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if threads.isEmpty {
                // Per-mailbox empty placeholder — keeps the sidebar live so
                // the user can switch back to Inbox without leaving the tab.
                EmptyMailboxView(isSearching: isSearching, mailboxImage: "tray")
            } else {
                #if os(macOS)
                List(selection: $selectedThreadID) {
                    ForEach(threads) { thread in
                        quickActionRow(for: thread) {
                            EmailThreadRow(
                                thread: thread,
                                isSelected: thread.id == selectedThreadID,
                                accountLabel: accountLabeler.label(for: thread)
                            )
                        }
                        .tag(thread.id)
                        .sidebarRowState(isEmphasized: thread.unreadCount > 0)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                #else
                List {
                    ForEach(threads) { thread in
                        quickActionRow(for: thread) {
                            Button {
                                selectedThreadID = thread.id
                            } label: {
                                EmailThreadRow(
                                    thread: thread,
                                    isSelected: thread.id == selectedThreadID,
                                    accountLabel: accountLabeler.label(for: thread)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .sidebarRowState(isEmphasized: thread.unreadCount > 0)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                #endif
            }
        }
        .searchable(text: $searchText, prompt: Text("Search \(mailbox.title)"))
    }

    private func quickActionRow<Content: View>(
        for thread: EmailThread,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        EmailQuickActionSwipe(
            action: quickAction,
            onPerform: { action in onQuickAction(action, thread, mailbox) },
            content: content
        )
        .accessibilityAction(named: Text(quickAction.displayName)) {
            onQuickAction(quickAction, thread, mailbox)
        }
    }
}

/// Empty state for a thread list: the system search placeholder while a
/// query is active, otherwise the app's per-mailbox placeholder.
private struct EmptyMailboxView: View {
    let isSearching: Bool
    let mailboxImage: String

    var body: some View {
        if isSearching {
            ContentUnavailableView.search
        } else {
            FeaturePlaceholderView(
                systemImage: mailboxImage,
                title: "Nothing here",
                message: "This mailbox is empty."
            )
        }
    }
}

private struct EmailThreadNavigationList: View {
    let mailbox: EmailMailbox
    let threads: [EmailThread]
    let quickAction: ReviewActionToken
    @Binding var searchText: String
    let isSearching: Bool
    let accountLabeler: EmailAccountLabeler
    let onQuickAction: (ReviewActionToken, EmailThread, EmailMailbox) -> Void

    var body: some View {
        Group {
            if threads.isEmpty {
                EmptyMailboxView(isSearching: isSearching, mailboxImage: mailbox.systemImage)
            } else {
                List {
                    ForEach(threads) { thread in
                        EmailQuickActionSwipe(
                            action: quickAction,
                            onPerform: { action in onQuickAction(action, thread, mailbox) }
                        ) {
                            NavigationLink(value: thread.id) {
                                EmailThreadRow(
                                    thread: thread,
                                    isSelected: false,
                                    accountLabel: accountLabeler.label(for: thread)
                                )
                            }
                        }
                        .accessibilityAction(named: Text(quickAction.displayName)) {
                            onQuickAction(quickAction, thread, mailbox)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("Search \(mailbox.title)"))
    }
}

private struct EmailThreadRow: View {
    let thread: EmailThread
    let isSelected: Bool
    let accountLabel: String?

    @State private var showingNotes = false

    private var hasNotes: Bool {
        thread.messages.contains { !$0.notes.isEmpty }
    }

    var body: some View {
        // Bind these once per row — `latestMessage` sorts the thread's
        // messages and `unreadCount` scans them, and both were read several
        // times across this body (header, subject, unread badge, background).
        let latest = thread.latestMessage
        let unread = thread.unreadCount
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if thread.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Text(latest?.displayFromAddress ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(unread > 0 ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                Text(EmailDisplayDateFormatter.label(for: thread.lastDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if hasNotes {
                    Button {
                        showingNotes.toggle()
                    } label: {
                        Image(systemName: "note.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show notes")
                    .emailNotesPresentation(
                        isPresented: $showingNotes,
                        emails: thread.sortedMessages
                    )
                }
            }
            Text(latest?.subject ?? "(no subject)")
                .font(.callout)
                .fontWeight(unread > 0 ? .semibold : .regular)
                .lineLimit(1)
            if let accountLabel {
                EmailAccountBadge(label: accountLabel)
                    .lineLimit(1)
            }
            Text(latest?.snippet ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if unread > 0 {
                Text("\(unread) unread")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Popover listing per-message notes. `internal` (not `private`) because
/// `EmailMessageCard` in `EmailThreadDetailView.swift` also uses it.
struct EmailNotesPopover: View {
    let emails: [Email]

    private var noteGroups: [EmailNoteGroup] {
        emails.compactMap { email in
            let notes = email.notes.sorted { $0.createdAt < $1.createdAt }
            return notes.isEmpty ? nil : EmailNoteGroup(email: email, notes: notes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes")
                .font(.headline)
            ForEach(noteGroups) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.email.subject.isEmpty ? "(no subject)" : item.email.subject)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(item.notes) { note in
                        Text(note.content)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct EmailNoteGroup: Identifiable {
    let email: Email
    let notes: [EmailNote]

    var id: UUID { email.id }
}

#Preview {
    EmailView()
        .modelContainer(for: [
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self
        ])
}
