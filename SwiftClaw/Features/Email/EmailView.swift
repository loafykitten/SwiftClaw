import Observation
import SwiftData
import SwiftUI

struct EmailView: View {
    /// Message-window sizing for the windowed fetch: only the newest
    /// `initialWindowLimit` messages are materialized per render, growing by
    /// `windowStep` via the "Show Older Messages" control (or automatically
    /// when a notification/review card targets mail older than the window).
    static let initialWindowLimit = 1000
    static let windowStep = 1000

    @State private var windowLimit = EmailView.initialWindowLimit

    var pendingEmailID: UUID?
    var openCompactThread: ((EmailMailbox, UUID) -> Void)?
    var onPendingEmailHandled: () -> Void = {}

    var body: some View {
        WindowedEmailContent(
            windowLimit: windowLimit,
            requestWindowLimit: { requested in
                windowLimit = max(windowLimit, requested)
            },
            pendingEmailID: pendingEmailID,
            openCompactThread: openCompactThread,
            onPendingEmailHandled: onPendingEmailHandled
        )
    }
}

/// The Email tab's content, split out of `EmailView` so the `@Query` can be
/// rebuilt when the window grows — a `@Query`'s descriptor is fixed at init,
/// so dynamic windowing needs the descriptor built in `init` from a value
/// the parent owns. Very large stores only materialize the newest
/// `windowLimit` messages instead of the whole table; thread detail still
/// shows complete threads via the `EmailThread.messages` relationship, and
/// only the thread lists/sidebar (and search) are window-scoped.
private struct WindowedEmailContent: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query private var emails: [Email]

    @State private var selectedThreadID: UUID?
    @State private var selectedMailbox: EmailMailbox = .inbox
    @State private var emailSearchText = ""
    @State private var debouncedEmailSearchText = ""
    @State private var composingReplyFor: Email?
    @State private var manualSyncCoordinator = EmailManualSyncCoordinator.shared
    @State private var manualReviewCoordinator = EmailManualReviewCoordinator.shared
    @State private var selectedAccountScope: EmailAccountScope = .all
    @AppStorage(SettingsKeys.emailReviewSlideAction)
    private var quickActionRaw = SettingsStorage.defaultEmailReviewSlideAction.rawValue
    let windowLimit: Int
    let requestWindowLimit: (Int) -> Void
    let pendingEmailID: UUID?
    let openCompactThread: ((EmailMailbox, UUID) -> Void)?
    let onPendingEmailHandled: () -> Void

    init(
        windowLimit: Int,
        requestWindowLimit: @escaping (Int) -> Void,
        pendingEmailID: UUID?,
        openCompactThread: ((EmailMailbox, UUID) -> Void)?,
        onPendingEmailHandled: @escaping () -> Void
    ) {
        self.windowLimit = windowLimit
        self.requestWindowLimit = requestWindowLimit
        self.pendingEmailID = pendingEmailID
        self.openCompactThread = openCompactThread
        self.onPendingEmailHandled = onPendingEmailHandled
        var descriptor = FetchDescriptor<Email>(
            sortBy: [SortDescriptor(\Email.date, order: .reverse)]
        )
        descriptor.fetchLimit = windowLimit
        _emails = Query(descriptor)
    }

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

        let searched = snapshot.search(selectedMailbox, with: debouncedEmailSearchText)
        let selected = searched.first { $0.id == selectedThreadID } ?? searched.first

        // Custom folders only show for a single account's view: in "All
        // Accounts" with several accounts they'd interleave into one long
        // list. Single-account setups keep them — the picker is hidden and
        // the scope stays `.all` there.
        let visibleMailboxes = snapshot.visibleMailboxes(
            showCustomFolders: !accountScope.isUnified || accounts.count == 1
        )

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
        .task(id: emailSearchText) {
            if SearchQuery.isActive(emailSearchText) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            debouncedEmailSearchText = emailSearchText
        }
        .onAppear {
            normalizeAccountScope()
            handlePendingEmailSelection()
        }
        .onChange(of: accounts.map(\.id)) { _, _ in
            normalizeAccountScope()
        }
        .onChange(of: selectedAccountScope) { _, newScope in
            // A custom folder can vanish from the sidebar on scope change
            // (hidden in the unified multi-account view, or absent from the
            // newly selected account); fall back to Inbox instead of
            // stranding the selection on an invisible mailbox.
            guard selectedMailbox.isCustom else { return }
            let scope = newScope.normalized(availableAccounts: accounts)
            let snapshot = EmailThreadScopeSnapshot(emails: emails, accountScope: scope)
            let visible = snapshot.visibleMailboxes(
                showCustomFolders: !scope.isUnified || accounts.count == 1
            )
            if !visible.contains(selectedMailbox) {
                selectedMailbox = .inbox
            }
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
                lastSyncSummary: MailSyncMonitor.shared.lastSyncSummary
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
                canLoadOlder: canLoadOlder,
                onLoadOlder: loadOlder,
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
                } else if let summary = MailSyncMonitor.shared.lastSyncSummary {
                    Label(summary, systemImage: "checkmark.circle")
                }
            }
        }
        .navigationDestination(for: EmailMailbox.self) { mailbox in
            EmailThreadNavigationList(
                mailbox: mailbox,
                threads: snapshot.search(mailbox, with: debouncedEmailSearchText),
                quickAction: quickAction,
                searchText: $emailSearchText,
                isSearching: isSearchingEmails,
                accountLabeler: accountLabeler,
                canLoadOlder: canLoadOlder,
                onLoadOlder: loadOlder,
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

    /// True when the window is full — there are (almost certainly) older
    /// messages beyond it. The one false positive (the store holds exactly
    /// `windowLimit` messages) costs a single no-op "Show Older Messages"
    /// tap, cheaper than a COUNT query on every render.
    private var canLoadOlder: Bool {
        emails.count >= windowLimit
    }

    private func loadOlder() {
        requestWindowLimit(windowLimit + EmailView.windowStep)
    }

    private func handlePendingEmailSelection(_ emailID: UUID? = nil) {
        guard let emailID = emailID ?? pendingEmailID,
              let email = fetchEmail(emailID),
              let thread = email.thread else { return }

        // The target may be older than the fetch window (a notification or
        // review card for mail beyond the newest `windowLimit` messages).
        // Grow the window to include it; the widened @Query re-fires this
        // handler via the thread-ids onChange above.
        if !emails.contains(where: { $0.id == emailID }) {
            requestWindowLimit(windowLimitIncluding(email))
            return
        }

        if !selectedAccountScope.includes(email) {
            selectedAccountScope = .all
        }
        let targetMailbox = mailbox(for: email)
        // Custom folders are hidden in the unified multi-account view, so
        // landing on one means scoping to the email's account first.
        if targetMailbox.isCustom, selectedAccountScope.isUnified, completeAccounts.count > 1 {
            selectedAccountScope = .account(email.accountID)
        }
        selectedMailbox = targetMailbox
        selectedThreadID = thread.id

        if horizontalSizeClass == .compact {
            openCompactThread?(targetMailbox, thread.id)
        }

        onPendingEmailHandled()
    }

    private func fetchEmail(_ id: UUID) -> Email? {
        var descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Window size that includes `email`: the count of messages at least as
    /// new as it (cheap COUNT, no rows materialized), plus slack for
    /// same-instant arrivals, floored at one full step past the current
    /// window.
    private func windowLimitIncluding(_ email: Email) -> Int {
        let date = email.date
        let newerCount = (try? modelContext.fetchCount(
            FetchDescriptor<Email>(predicate: #Predicate { $0.date >= date })
        )) ?? 0
        return max(windowLimit + EmailView.windowStep, newerCount + 50)
    }

    private func normalizeAccountScope() {
        let normalized = selectedAccountScope.normalized(availableAccounts: completeAccounts)
        if normalized != selectedAccountScope {
            selectedAccountScope = normalized
        }
    }

    private func mailbox(for email: Email) -> EmailMailbox {
        if email.isTrashed {
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
            thread.sortedMessages.last { !$0.isArchived && !$0.isTrashed && ($0.role == .inbox || $0.role == .sent) }
        case .flagged:
            thread.sortedMessages.last { !$0.isArchived && !$0.isTrashed && $0.isFlagged }
                ?? thread.sortedMessages.last { !$0.isArchived && !$0.isTrashed }
        case .sent:
            thread.sortedMessages.last { $0.role == .sent && !$0.isTrashed }
        case .drafts:
            thread.sortedMessages.last { $0.role == .drafts && !$0.isTrashed }
        case .junk:
            thread.sortedMessages.last { $0.role == .junk && !$0.isTrashed }
        case .archive:
            thread.sortedMessages.last { $0.isArchived && !$0.isTrashed }
        case .trash:
            thread.sortedMessages.last { $0.isTrashed }
        case .custom(let name):
            thread.sortedMessages.last {
                $0.role == .custom
                    && $0.mailbox.caseInsensitiveCompare(name) == .orderedSame
                    && !$0.isArchived
                    && !$0.isTrashed
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
            case .approve, .reject, .edit, .undo:
                // Proposal/memory-card tokens; never offered as an email quick action.
                break
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

    /// Round-trips from the monitor so the footer can render "Synced 3 min.
    /// ago · 2 new" alongside (or instead of) the transient status label.
    /// Passed in rather than read directly so SwiftUI's observation tracks
    /// the `@Observable MailSyncMonitor.shared` correctly across re-renders.
    let lastSyncSummary: String?

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
        } else if let lastSyncSummary {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text(lastSyncSummary)
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
